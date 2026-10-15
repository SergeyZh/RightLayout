import Foundation
import AppKit
import CoreGraphics
import Carbon
import ApplicationServices
import os.log
import _Concurrency

@MainActor
public final class EventMonitor {
    private struct InputSession {
        var sessionEpoch: UInt64 = 0
        var mutationSeq: UInt64 = 0
        var typedToken: String = ""
        var phraseContext: String = ""
        var startedAt: Date = .distantPast
        var lastMutationAt: Date = .distantPast
        var isDirty: Bool = false
        var sourceApp: String = ""
        var lastVerifiedSnapshot: FocusedTextSnapshot?
    }

    private struct ManualTriggerState {
        var isPressed = false
        var isStandaloneCandidate = false
        var lastStandaloneReleaseAt: Date?
    }

    private struct CommittedTokenContext {
        let token: String
        let separator: String
    }

    private struct PendingTransliterationHint {
        let suggestion: TransliterationSuggestion
        let separator: String
        let commitRevision: UInt64
        let createdAt: Date
    }

    private struct CommittedTransaction {
        let visibleText: String
        let timestamp: Date
    }

    private struct SelectionIntentState {
        var lastExplicitSelectionAt: Date?
        var source: String?

        mutating func mark(now: Date, source: String) {
            lastExplicitSelectionAt = now
            self.source = source
        }

        mutating func clear() {
            lastExplicitSelectionAt = nil
            source = nil
        }

        func isActive(at now: Date, timeout: TimeInterval = 3.0) -> Bool {
            guard let lastExplicitSelectionAt else { return false }
            return now.timeIntervalSince(lastExplicitSelectionAt) <= timeout
        }
    }

    private struct PendingLayoutSwitch {
        let transactionId: UUID?
        let expectedLayoutId: String?
        let expiresAt: Date

        func matches(currentLayoutId: String?, currentVariantId: String?, now: Date) -> Bool {
            guard now <= expiresAt else { return false }
            guard let expectedLayoutId else { return true }
            return currentLayoutId == expectedLayoutId || currentVariantId == expectedLayoutId
        }
    }

    private struct BoundaryVerification {
        let context: VerifiedEditContext
        let includesSeparator: Bool
        /// Text typed after the separator while the boundary was being processed,
        /// exactly as it appears in the document.
        let trailingText: String
    }

    private enum RuntimeState: String {
        case tracking
        case boundaryPending
        case replacing
        case dirtyNeedsResync
    }

    private static let axNotificationCallback: AXObserverCallback = { _, _, notification, refcon in
        guard let refcon else { return }
        let monitor = Unmanaged<EventMonitor>.fromOpaque(refcon).takeUnretainedValue()
        let name = notification as String
        Task { @MainActor in
            monitor.handleAXNotification(name)
        }
    }

    let engine: CorrectionEngine
    private let textContextService: FocusedTextContextService
    private let replacementService: SelectionReplacementService
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var mouseMonitor: Any?
    private var layoutChangeObserver: Any?
    private var appChangeObserver: Any?
    private let logger = Logger.events
    private let trace = RuntimeTraceLogger.shared
    private let settings = SettingsManager.shared
    private let timeProvider: TimeProvider
    private let charEncoder: CharacterEncoder

    package var skipPIDCheck = false
    package var skipSecureInputCheck = false
    package var skipEventPosting = false

    private var inputSession = InputSession()
    private var lastActiveApp: String = ""
    private var backspaceCount = 0
    private var lastCorrectionTrackingId: UUID?
    private var backspaceReportedForId: UUID?
    private var lastBackspaceTime: Date?
    private var lastCorrectionTime: Date = .distantPast
    private var keyTimings: [TimeInterval] = []
    private var lastKeyTime: Date?
    private var lastCommittedToken: CommittedTokenContext?
    private var pendingTransliterationHint: PendingTransliterationHint?
    private var manualTriggerState = ManualTriggerState()
    private var activeSyntheticTransactions = 0
    private var transliterationApplyObserver: Any?
    private var axObserver: AXObserver?
    private var observedAppPID: pid_t?
    private var lastCommittedTransaction: CommittedTransaction?
    private var selectionIntentState = SelectionIntentState()
    private var pendingLayoutSwitch: PendingLayoutSwitch?
    private var runtimeState: RuntimeState = .tracking
    /// Bumped whenever the text after the last committed boundary stops being a plain
    /// continuation of it (new boundary, backspace past it, session reset/reseed).
    private var boundaryGeneration: UInt64 = 0
    private var boundaryTasksInFlight = 0
    /// Mutation sequence right after the last external invalidation; lets bursts of
    /// invalidating events (key auto-repeat, mouse drags) skip redundant work.
    private var invalidatedAtMutationSeq: UInt64?
    private var deferredResyncTask: Task<Void, Never>?
    private var suppressLayoutFeedbackUntil: Date = .distantPast

    /// Delay before re-reading the focused text after cursor movement or other external
    /// changes. Reading it synchronously from the event tap stalls every keystroke.
    private static let deferredResyncDelay: UInt64 = 90_000_000
    private static let boundaryVerificationAttempts = 12
    private static let boundaryVerificationRetryDelay: UInt64 = 5_000_000

    package private(set) var lastReplacement: (deletedCount: Int, insertedText: String)?

    package convenience init(engine: CorrectionEngine) {
        self.init(
            engine: engine,
            timeProvider: RealTimeProvider(),
            charEncoder: DefaultCharacterEncoder(),
            textContextService: .shared,
            replacementService: .shared
        )
    }

    init(
        engine: CorrectionEngine,
        timeProvider: TimeProvider = RealTimeProvider(),
        charEncoder: CharacterEncoder = DefaultCharacterEncoder(),
        textContextService: FocusedTextContextService = .shared,
        replacementService: SelectionReplacementService = .shared
    ) {
        self.engine = engine
        self.timeProvider = timeProvider
        self.charEncoder = charEncoder
        self.textContextService = textContextService
        self.replacementService = replacementService
        setupAppChangeObserver()
        setupLayoutChangeObserver()
        setupTransliterationApplyObserver()
        updateObservedAXApp()
    }

    private func setupLayoutChangeObserver() {
        layoutChangeObserver = DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.handleLayoutChange()
            }
        }
    }

    private func handleLayoutChange() async {
        let now = timeProvider.now
        guard now > suppressLayoutFeedbackUntil else {
            pendingLayoutSwitch = nil
            return
        }
        let currentLayoutId = InputSourceManager.shared.currentLayoutId()
        let currentVariantId = InputSourceManager.shared.layoutVariantId(forInputSourceId: currentLayoutId)
        if let pendingLayoutSwitch,
           pendingLayoutSwitch.matches(currentLayoutId: currentLayoutId, currentVariantId: currentVariantId, now: now) {
            trace.log(
                .layoutSwitchObserved,
                fields: [
                    "result": "suppressed",
                    "layout_id": currentLayoutId,
                    "transaction_id": pendingLayoutSwitch.transactionId?.uuidString
                ]
            )
            self.pendingLayoutSwitch = nil
            return
        }
        pendingLayoutSwitch = nil

        let timeSinceCorrection = now.timeIntervalSince(lastCorrectionTime)
        guard timeSinceCorrection < 2.0 else { return }

        if let id = lastCorrectionTrackingId {
            if let transaction = await engine.transaction(for: id) {
                let currentBundleId = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
                guard transaction.bundleId == nil || transaction.bundleId == currentBundleId else {
                    return
                }
                if let transactionEpoch = transaction.sessionEpoch,
                   transactionEpoch != inputSession.sessionEpoch {
                    return
                }
                if currentLayoutId == transaction.inputSourceAfterExpected
                    || currentVariantId == transaction.inputSourceAfterExpected {
                    return
                }
            }
            trace.log(
                .layoutSwitchObserved,
                fields: [
                    "result": "negative_feedback",
                    "layout_id": currentLayoutId,
                    "transaction_id": id.uuidString
                ]
            )
            await engine.reportNegativeFeedback(id: id, reason: .manualSwitch)
            lastCorrectionTrackingId = nil
            return
        }

        guard let fallbackId = await engine.currentPendingFeedbackId() else { return }
        await engine.reportNegativeFeedback(id: fallbackId, reason: .manualSwitch)
    }

    private func setupAppChangeObserver() {
        appChangeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.resetOnAppChange()
            }
        }
    }

    private func resetOnAppChange() {
        textContextService.invalidateCachedCapabilities()
        let newApp = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""
        if newApp != lastActiveApp {
            Task { await engine.resetCycling() }
            clearPendingCorrectionTracking()
            selectionIntentState.clear()
            pendingLayoutSwitch = nil
            resetSession(reason: "App Change", clearPhraseContext: true)
            lastCommittedTransaction = nil
        }
        lastActiveApp = newApp
        updateObservedAXApp()
    }

    private func setupTransliterationApplyObserver() {
        transliterationApplyObserver = NotificationCenter.default.addObserver(
            forName: Notification.Name("ApplyTransliterationHint"),
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let idString = notification.userInfo?["id"] as? String,
                  let id = UUID(uuidString: idString) else { return }

            Task { @MainActor [weak self] in
                await self?.applyTransliterationHint(id: id)
            }
        }
    }

    /// Whether the keyboard event tap is installed. It can't be created until the
    /// Accessibility permission is granted.
    package var isRunning: Bool {
        eventTap != nil
    }

    package func start() async {
        guard eventTap == nil else { return }

        // Only keyboard events go through the active tap: every event it receives is held
        // until the callback returns. Mouse and scroll events are observed passively below
        // so the pointer and scrolling never wait on us.
        let types: [CGEventType] = [
            .keyDown,
            .flagsChanged
        ]
        let mask = types.reduce(CGEventMask(0)) { partial, type in
            partial | (1 << type.rawValue)
        }

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { proxy, type, event, refcon in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                let monitor = Unmanaged<EventMonitor>.fromOpaque(refcon).takeUnretainedValue()

                if type == .tapDisabledByTimeout {
                    monitor.logger.warning("Event tap disabled by timeout; re-enabling")
                    if let tap = monitor.eventTap {
                        CGEvent.tapEnable(tap: tap, enable: true)
                    }
                    monitor.resetSession(reason: "Tap Timeout", clearPhraseContext: false)
                    return nil
                }

                if type == .tapDisabledByUserInput {
                    monitor.logger.warning("Event tap disabled by user input; re-enabling")
                    if let tap = monitor.eventTap {
                        CGEvent.tapEnable(tap: tap, enable: true)
                    }
                    monitor.resetSession(reason: "Tap User Input", clearPhraseContext: false)
                    return nil
                }

                return monitor.handleEvent(proxy: proxy, type: type, event: event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            logger.error("Failed to create keyboard event tap (Accessibility permission missing?)")
            return
        }

        eventTap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        mouseMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged, .scrollWheel]
        ) { [weak self] event in
            let isDrag = event.type == .leftMouseDragged || event.type == .rightMouseDragged || event.type == .otherMouseDragged
            Task { @MainActor [weak self] in
                guard let self else { return }
                if isDrag {
                    self.selectionIntentState.mark(now: self.timeProvider.now, source: "mouseDrag")
                }
                self.handleExternalInvalidation(reason: "Mouse/Scroll", clearPhraseContext: false)
            }
        }
    }

    package func stop() {
        stopAXObserver()
        deferredResyncTask?.cancel()
        deferredResyncTask = nil

        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil

        if let monitor = mouseMonitor {
            NSEvent.removeMonitor(monitor)
            mouseMonitor = nil
        }

        if let observer = layoutChangeObserver {
            DistributedNotificationCenter.default().removeObserver(observer)
            layoutChangeObserver = nil
        }

        if let observer = appChangeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            appChangeObserver = nil
        }

        if let observer = transliterationApplyObserver {
            NotificationCenter.default.removeObserver(observer)
            transliterationApplyObserver = nil
        }
    }
    internal func handleEvent(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        expireStandaloneOptionTapIfNeeded()

        if !skipSecureInputCheck && IsSecureEventInputEnabled() {
            resetSession(reason: "Secure Input", clearPhraseContext: true)
            return Unmanaged.passUnretained(event)
        }

        if !skipPIDCheck && event.getIntegerValueField(.eventSourceUserData) == SyntheticEventMarker.value {
            return Unmanaged.passUnretained(event)
        }

        switch type {
        case .leftMouseDown, .rightMouseDown, .otherMouseDown, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged, .scrollWheel:
            if type == .leftMouseDragged || type == .rightMouseDragged || type == .otherMouseDragged {
                selectionIntentState.mark(now: timeProvider.now, source: "mouseDrag")
            }
            handleExternalInvalidation(reason: "Mouse/Scroll", clearPhraseContext: false)
            return Unmanaged.passUnretained(event)
        case .flagsChanged:
            return handleFlagsChanged(event)
        case .keyDown:
            return handleKeyDown(proxy: proxy, event: event)
        default:
            return Unmanaged.passUnretained(event)
        }
    }

    private func handleFlagsChanged(_ event: CGEvent) -> Unmanaged<CGEvent>? {
        let flags = event.flags
        let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))

        if settings.hotkeyEnabled,
           settings.manualTriggerMode == .doubleTapOption,
           keyCode == settings.manualTriggerOptionKeyCode {
            handleOptionFlagsChanged(flags: flags)
            return Unmanaged.passUnretained(event)
        }

        if manualTriggerState.isPressed {
            cancelStandaloneOptionTap()
        }

        if flags.contains(.maskCommand) || flags.contains(.maskControl) {
            handleExternalInvalidation(reason: "Modifier", clearPhraseContext: false)
        }

        return Unmanaged.passUnretained(event)
    }

    private func handleOptionFlagsChanged(flags: CGEventFlags) {
        let now = timeProvider.now

        if flags.contains(.maskAlternate) {
            manualTriggerState.isPressed = true
            manualTriggerState.isStandaloneCandidate = true
            return
        }

        guard manualTriggerState.isPressed else { return }
        manualTriggerState.isPressed = false

        guard manualTriggerState.isStandaloneCandidate else {
            manualTriggerState.lastStandaloneReleaseAt = nil
            return
        }

        if let lastRelease = manualTriggerState.lastStandaloneReleaseAt,
           now.timeIntervalSince(lastRelease) <= settings.manualTriggerDoubleTapWindow {
            manualTriggerState.lastStandaloneReleaseAt = nil
            manualTriggerState.isStandaloneCandidate = false
            Task { @MainActor in
                await handleHotkeyPress()
            }
            return
        }

        manualTriggerState.lastStandaloneReleaseAt = now
        manualTriggerState.isStandaloneCandidate = false
    }

    private func handleKeyDown(proxy: CGEventTapProxy, event: CGEvent) -> Unmanaged<CGEvent>? {
        let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
        let flags = event.flags
        let now = timeProvider.now

        if flags.contains(.maskCommand) {
            cancelStandaloneOptionTap()
            if keyCode == 6 {
                Task { await engine.handleUndo() }
            }
            clearTransliterationHint()
            handleExternalInvalidation(reason: "Command Shortcut", clearPhraseContext: false)
            return Unmanaged.passUnretained(event)
        }

        if flags.contains(.maskControl) {
            cancelStandaloneOptionTap()
            clearTransliterationHint()
            handleExternalInvalidation(reason: "Control Shortcut", clearPhraseContext: false)
            return Unmanaged.passUnretained(event)
        }

        if keyCode == 51 {
            cancelStandaloneOptionTap()
            handleBackspace()
            return Unmanaged.passUnretained(event)
        } else {
            backspaceCount = 0
            backspaceReportedForId = nil
        }

        if Self.navigationKeys.contains(keyCode) {
            if flags.contains(.maskShift) {
                selectionIntentState.mark(now: now, source: "shiftNavigation")
            }
            handleExternalInvalidation(reason: "Navigation", clearPhraseContext: false)
            return Unmanaged.passUnretained(event)
        }

        guard let chars = charEncoder.encode(event: event), !chars.isEmpty else {
            cancelStandaloneOptionTap()
            return Unmanaged.passUnretained(event)
        }

        cancelStandaloneOptionTap()

        if inputSession.typedToken.isEmpty, let first = chars.first, first.isLetter || first.isNumber {
            // Observers update UI; keep that work out of the event tap callback.
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: Notification.Name("ProactiveLayoutHint"), object: nil, userInfo: nil)
            }
            clearTransliterationHint()
        }

        if !inputSession.typedToken.isEmpty,
           let last = lastKeyTime,
           now.timeIntervalSince(last) > ThresholdsConfig.shared.timing.bufferTimeout {
            inputSession.typedToken = ""
            boundaryGeneration &+= 1
            keyTimings.removeAll()
        }

        if isWordBoundaryTrigger(chars) {
            let token = inputSession.typedToken
            inputSession.typedToken = ""
            boundaryGeneration &+= 1
            bumpSessionMutation(at: now)
            lastKeyTime = now

            if token.isEmpty {
                if let last = lastCommittedToken {
                    lastCommittedToken = CommittedTokenContext(token: last.token, separator: last.separator + chars)
                }
                return Unmanaged.passUnretained(event)
            }

            let expectedMutationSeq = inputSession.mutationSeq
            let generation = boundaryGeneration
            let latencies = keyTimings
            keyTimings.removeAll()
            Task { @MainActor in
                await processCommittedBoundary(
                    token: token,
                    separator: chars,
                    proxy: proxy,
                    expectedMutationSeq: expectedMutationSeq,
                    boundaryGeneration: generation,
                    latencies: latencies
                )
            }
            return Unmanaged.passUnretained(event)
        }

        inputSession.typedToken.append(chars)
        bumpSessionMutation(at: now)

        if let last = lastKeyTime {
            keyTimings.append(now.timeIntervalSince(last))
        } else {
            keyTimings.append(0)
        }
        lastKeyTime = now

        Task { await engine.resetCycling() }

        return Unmanaged.passUnretained(event)
    }

    private func handleBackspace() {
        clearTransliterationHint()

        if !inputSession.typedToken.isEmpty {
            inputSession.typedToken.removeLast()
            bumpSessionMutation(at: timeProvider.now)
        } else {
            inputSession.isDirty = true
            inputSession.lastVerifiedSnapshot = nil
            inputSession.mutationSeq &+= 1
            boundaryGeneration &+= 1
            lastCommittedToken = nil
        }

        lastKeyTime = timeProvider.now
        Task { await engine.resetCycling() }

        let now = timeProvider.now
        let timeSinceLastBackspace = now.timeIntervalSince(lastBackspaceTime ?? .distantPast)
        lastBackspaceTime = now

        if timeSinceLastBackspace < 0.5 {
            backspaceCount += 1
        } else {
            backspaceCount = 1
        }

        if backspaceCount >= 3 {
            if let id = lastCorrectionTrackingId, backspaceReportedForId != id {
                Task {
                    if let transaction = await engine.transaction(for: id),
                       let transactionEpoch = transaction.sessionEpoch,
                       transactionEpoch != self.inputSession.sessionEpoch {
                        return
                    }
                    await engine.reportNegativeFeedback(id: id, reason: .backspaceBurst)
                }
                backspaceReportedForId = id
                return
            }

            Task { @MainActor in
                let engineFallbackId = await engine.currentPendingFeedbackId()
                let fallbackId = lastCorrectionTrackingId ?? engineFallbackId
                guard let id = fallbackId, backspaceReportedForId != id else { return }
                await engine.reportNegativeFeedback(id: id, reason: .backspaceBurst)
                backspaceReportedForId = id
            }
        }
    }

    private func processCommittedBoundary(
        token: String,
        separator: String,
        proxy: CGEventTapProxy,
        expectedMutationSeq: UInt64,
        boundaryGeneration generation: UInt64,
        latencies: [TimeInterval]
    ) async {
        boundaryTasksInFlight += 1
        defer { boundaryTasksInFlight -= 1 }

        runtimeState = .boundaryPending
        guard generation == boundaryGeneration else {
            preserveCommittedBoundaryIfNeeded(token: token, separator: separator)
            return
        }

        let isSyntheticHost = skipEventPosting || skipPIDCheck
        let focusedCapabilities = textContextService.resolveFocusedElementCapabilities()
        let bundleId = focusedCapabilities?.bundleId ?? lastActiveApp
        let hostProfile = currentHostRuntimeProfile(bundleId: bundleId, capabilities: focusedCapabilities?.capabilities)
        let canVerifyText = isSyntheticHost || focusedCapabilities?.capabilities.supportsFullTextRead == true
        trace.log(
            .boundaryDetected,
            fields: [
                "bundle_id": bundleId,
                "host_profile": hostProfile.rawValue,
                "session_epoch": String(inputSession.sessionEpoch),
                "mutation_seq": String(inputSession.mutationSeq),
                "token": token,
                "separator": separator
            ]
        )
        let editingEnvironment = hostProfile.editingEnvironment

        if await engine.checkForRetype(text: token, bundleId: isSyntheticHost ? lastActiveApp : bundleId) {
            updatePhraseBuffer(with: splitBufferContent(token).token)
            lastCommittedToken = CommittedTokenContext(token: token, separator: separator)
            clearTransliterationHint()
            lastCorrectionTrackingId = nil
            lastCorrectionTime = .distantPast
            Task { await engine.resetCycling() }
            return
        }

        if let acceptedId = lastCorrectionTrackingId {
            await engine.acceptTransactionIfTracked(acceptedId)
            lastCorrectionTrackingId = nil
            backspaceReportedForId = nil
        }

        let currentLayoutId = InputSourceManager.shared.currentLayoutId()
        let currentLanguage = mapLayoutToLanguage(currentLayoutId)

        // Decide first; the focused text is only read back when there is something to
        // replace. Most words need no correction and never touch Accessibility here.
        var planned = await engine.planCorrection(
            token,
            phraseBuffer: inputSession.phraseContext,
            expectedLayout: currentLanguage,
            latencies: latencies,
            editingEnvironment: editingEnvironment
        )
        trace.log(
            .planReady,
            fields: [
                "bundle_id": bundleId,
                "host_profile": hostProfile.rawValue,
                "confidence": planned.result.confidence.map { String(format: "%.3f", $0) },
                "action": planned.plan.traceValue,
                "target_language": planned.result.targetLanguage?.rawValue,
                "token": token
            ]
        )

        if skipEventPosting,
           case .hint = planned.plan,
           let forced = await engine.applyPendingSuggestion(),
           let corrected = forced.corrected {
            planned = PlannedCorrection(
                result: forced,
                plan: .autoReplace(
                    CorrectionCandidate(
                        original: token,
                        replacement: corrected,
                        pendingOriginal: forced.pendingOriginal,
                        pendingReplacement: forced.pendingCorrection,
                        trackingId: forced.transaction?.id,
                        transaction: forced.transaction,
                        transliterationSuggestion: forced.transliterationSuggestion
                    )
                )
            )
        }

        await engine.updateCyclingTrailingSeparator(separator)

        // The user may already be typing the next word. That is fine for a plain
        // auto-replacement (the new characters are carried over), anything else keeps
        // the old conservative behavior.
        let typedSinceBoundary = !inputSession.typedToken.isEmpty
        guard generation == boundaryGeneration,
              !typedSinceBoundary || (matchesAutoReplace(planned.plan) && planned.result.pendingCorrection == nil) else {
            preserveCommittedBoundaryIfNeeded(token: token, separator: separator)
            await engine.resetCycling()
            return
        }

        let outputToken = planned.result.corrected ?? token

        let previousCommitted = recentCommittedTokenContext()
        let fallbackCascade: (original: String, replacement: String)?
        if !typedSinceBoundary,
           planned.result.pendingCorrection == nil,
           case .autoReplace = planned.plan,
           editingEnvironment == .accessibility,
           let last = previousCommitted,
           last.token.filter(\.isLetter).count <= 2,
           let targetLanguage = planned.result.targetLanguage {
            let contextual = await engine.contextualCascadeCorrection(for: last.token, targetLanguage: targetLanguage)
            if let contextual {
                fallbackCascade = (last.token, contextual)
            } else {
                fallbackCascade = nil
            }
        } else {
            fallbackCascade = nil
        }

        if let pendingCorrection = planned.result.pendingCorrection ?? fallbackCascade?.replacement,
           let pendingOriginal = planned.result.pendingOriginal ?? fallbackCascade?.original,
           let last = previousCommitted,
           last.token == pendingOriginal {
            let combinedStem = pendingOriginal + last.separator + token
            guard let combinedVerification = await verifyCommittedBoundary(
                token: combinedStem,
                separator: separator,
                generation: generation,
                allowTrailingText: false,
                canVerifyText: canVerifyText
            ) else {
                if generation != boundaryGeneration || !inputSession.typedToken.isEmpty {
                    preserveCommittedBoundaryIfNeeded(token: token, separator: separator)
                    await engine.resetCycling()
                }
                return
            }
            let combinedContext = combinedVerification.context

            let combinedOriginal = combinedContext.verifiedText
            let inserted = pendingCorrection + last.separator + outputToken + (combinedVerification.includesSeparator ? separator : "")
            let applied = await performReplacement(
                intent: .autoCorrection,
                expectedOriginal: combinedOriginal,
                replacement: inserted,
                verifiedContext: combinedContext,
                allowClipboardFallback: false,
                allowEventReplayFallback: false,
                currentVisibleText: combinedOriginal,
                hostRuntimeProfile: hostProfile,
                proxy: proxy
            )
            guard let applied else { return }

            replaceLastPhraseBufferWord(from: pendingOriginal, to: pendingCorrection)
            updatePhraseBuffer(with: splitBufferContent(outputToken).token)
            lastCommittedToken = CommittedTokenContext(token: outputToken, separator: separator)
            setTransliterationHint(planned.result.transliterationSuggestion, separator: separator, commitRevision: expectedMutationSeq)
            await commitReplacementTransaction(
                planned.result.transaction,
                editResult: applied,
                verifiedContext: combinedContext
            )
            if let transactionId = planned.result.transaction?.id {
                lastCorrectionTrackingId = transactionId
                lastCorrectionTime = timeProvider.now
                backspaceReportedForId = nil
            }
            if shouldSwitchLayout(after: applied, hostRuntimeProfile: hostProfile) {
                switchInputSourceIfNeeded(to: planned.result.targetLanguage, transactionId: planned.result.transaction?.id)
            }
            return
        }

        switch planned.plan {
        case .autoReplace(let candidate):
            let transaction = candidate.transaction ?? planned.result.transaction
            let targetLanguage = planned.result.targetLanguage
            let allowEventReplayFallback =
                inputSession.typedToken.isEmpty &&
                hostProfile.allowsAutomaticBlindReplay &&
                shouldAllowAutomaticReplayFallback(
                    for: token + separator,
                    confidence: planned.result.confidence,
                    hostRuntimeProfile: hostProfile
                )

            // Switch the layout right away, before the text is read back and replaced, so
            // that whatever the user types next already lands in the right layout. If the
            // replacement doesn't happen after all, the switch is undone below.
            let layoutBeforeSwitch = InputSourceManager.shared.currentLayoutId()
            let canSwitchEarly =
                (editingEnvironment == .accessibility && canVerifyText) ||
                (allowEventReplayFallback && hostProfile.switchSafeAfterBlindReplay)
            var switchedEarly = false
            if canSwitchEarly {
                switchedEarly = switchInputSourceIfNeeded(to: targetLanguage, transactionId: transaction?.id)
            }
            let charactersTypedBeforeSwitch = inputSession.typedToken.count

            let verification = await verifyCommittedBoundary(
                token: token,
                separator: separator,
                generation: generation,
                allowTrailingText: true,
                canVerifyText: canVerifyText
            )

            guard generation == boundaryGeneration else {
                if switchedEarly {
                    revertInputSource(to: layoutBeforeSwitch)
                }
                preserveCommittedBoundaryIfNeeded(token: token, separator: separator)
                await engine.resetCycling()
                return
            }

            guard verification != nil || allowEventReplayFallback else {
                if switchedEarly {
                    revertInputSource(to: layoutBeforeSwitch)
                }
                updatePhraseBuffer(with: splitBufferContent(token).token)
                lastCommittedToken = CommittedTokenContext(token: token, separator: separator)
                setTransliterationHint(nil, separator: separator, commitRevision: expectedMutationSeq)
                return
            }

            let expectedOriginal: String
            let replacement: String
            if let verification {
                let trailingText = switchedEarly
                    ? convertTypedTail(
                        verification.trailingText,
                        charactersTypedBeforeSwitch: charactersTypedBeforeSwitch,
                        from: Self.sourceLanguage(of: transaction?.hypothesis) ?? currentLanguage,
                        to: targetLanguage
                    )
                    : verification.trailingText
                expectedOriginal = verification.context.verifiedText
                replacement = candidate.replacement
                    + (verification.includesSeparator ? separator : "")
                    + trailingText
            } else {
                expectedOriginal = token + separator
                replacement = candidate.replacement + separator
            }

            let applied = await performReplacement(
                intent: .autoCorrection,
                expectedOriginal: expectedOriginal,
                replacement: replacement,
                verifiedContext: verification?.context,
                allowClipboardFallback: false,
                allowEventReplayFallback: allowEventReplayFallback,
                currentVisibleText: expectedOriginal,
                hostRuntimeProfile: hostProfile,
                proxy: proxy
            )
            guard let applied else {
                if switchedEarly {
                    revertInputSource(to: layoutBeforeSwitch)
                }
                return
            }

            lastCommittedToken = CommittedTokenContext(token: candidate.replacement, separator: separator)
            updatePhraseBuffer(with: splitBufferContent(candidate.replacement).token)
            setTransliterationHint(nil, separator: separator, commitRevision: expectedMutationSeq)
            await commitReplacementTransaction(
                transaction,
                editResult: applied,
                verifiedContext: verification?.context
            )
            if let transactionId = transaction?.id {
                lastCorrectionTrackingId = transactionId
                lastCorrectionTime = timeProvider.now
                backspaceReportedForId = nil
            }
            let switchAllowed = shouldSwitchLayout(after: applied, hostRuntimeProfile: hostProfile)
            if switchedEarly {
                if !switchAllowed {
                    revertInputSource(to: layoutBeforeSwitch)
                }
            } else if switchAllowed {
                switchInputSourceIfNeeded(to: targetLanguage, transactionId: transaction?.id)
            }
        case .hint, .none:
            updatePhraseBuffer(with: splitBufferContent(outputToken).token)
            lastCommittedToken = CommittedTokenContext(token: outputToken, separator: separator)
            setTransliterationHint(planned.result.transliterationSuggestion, separator: separator, commitRevision: expectedMutationSeq)
        case .manualCycle:
            break
        }
        runtimeState = .tracking
    }

    /// Converts characters typed after a boundary whose word is being auto-corrected.
    ///
    /// The first `charactersTypedBeforeSwitch` characters were typed before the layout
    /// switch and are converted as a whole. Later ones may already be in the target
    /// layout, so only letters that still belong to the source layout are converted.
    private func convertTypedTail(
        _ tail: String,
        charactersTypedBeforeSwitch: Int,
        from source: Language?,
        to target: Language?
    ) -> String {
        guard !tail.isEmpty, let source, let target, source != target else { return tail }

        let mapper = LayoutMapper.shared
        let activeLayouts = settings.activeLayouts
        let characters = Array(tail)
        let headCount = min(max(charactersTypedBeforeSwitch, 0), characters.count)

        var result = ""
        if headCount > 0 {
            let head = String(characters[..<headCount])
            result = mapper.convert(head, from: source, to: target, activeLayouts: activeLayouts) ?? head
        }
        for character in characters[headCount...] {
            let original = String(character)
            if character.isLetter,
               let converted = mapper.convert(original, from: source, to: target, activeLayouts: activeLayouts),
               converted != original,
               converted.allSatisfy({ $0.isLetter }) {
                result += converted
            } else {
                result += original
            }
        }
        return result
    }

    private static func sourceLanguage(of hypothesis: LanguageHypothesis?) -> Language? {
        guard let hypothesis else { return nil }
        switch hypothesis {
        case .ruFromEnLayout, .heFromEnLayout:
            return .english
        case .enFromRuLayout, .heFromRuLayout:
            return .russian
        case .enFromHeLayout, .ruFromHeLayout:
            return .hebrew
        case .ru, .en, .he:
            return nil
        }
    }

    @discardableResult
    private func switchInputSourceIfNeeded(to language: Language?, transactionId: UUID? = nil) -> Bool {
        guard let language else { return false }
        guard settings.autoSwitchLayout else { return false }
        trace.log(
            .layoutSwitchRequested,
            fields: [
                "transaction_id": transactionId?.uuidString,
                "language": language.rawValue
            ]
        )

        let activeLayouts = settings.activeLayouts
        if let preferredLayout = activeLayouts[language.rawValue] {
            pendingLayoutSwitch = PendingLayoutSwitch(
                transactionId: transactionId,
                expectedLayoutId: preferredLayout,
                expiresAt: timeProvider.now.addingTimeInterval(1.0)
            )
            if InputSourceManager.shared.switchToLayoutVariant(preferredLayout) {
                return true
            }
        }
        pendingLayoutSwitch = PendingLayoutSwitch(
            transactionId: transactionId,
            expectedLayoutId: nil,
            expiresAt: timeProvider.now.addingTimeInterval(1.0)
        )
        InputSourceManager.shared.switchTo(language: language)
        return true
    }

    /// Undoes an early layout switch when the replacement it anticipated didn't happen.
    private func revertInputSource(to layoutId: String?) {
        guard let layoutId, layoutId != InputSourceManager.shared.currentLayoutId() else { return }
        // Both the original switch and this one will be observed; neither is user feedback.
        pendingLayoutSwitch = nil
        suppressLayoutFeedbackUntil = timeProvider.now.addingTimeInterval(1.0)
        InputSourceManager.shared.switchToLayoutId(layoutId)
    }

    private func shouldSwitchLayout(after result: TextEditResult, hostRuntimeProfile: HostRuntimeProfile) -> Bool {
        switch result.commitKind {
        case .verifiedCommit:
            return true
        case .blindCommit:
            return hostRuntimeProfile.switchSafeAfterBlindReplay
        case .aborted, .rollbackAttempted:
            return false
        }
    }

    private func currentHostRuntimeProfile(
        bundleId: String?,
        capabilities: AppEditCapabilities?
    ) -> HostRuntimeProfile {
        HostRuntimeProfile.resolve(
            bundleId: bundleId,
            capabilities: capabilities,
            forceAccessibility: skipEventPosting || skipPIDCheck,
            forceSecure: !skipSecureInputCheck && IsSecureEventInputEnabled()
        )
    }

    private func handleHotkeyPress() async {
        let bundleId = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let focusedCapabilities = textContextService.resolveFocusedElementCapabilities()
        let hostProfile = currentHostRuntimeProfile(bundleId: bundleId, capabilities: focusedCapabilities?.capabilities)

        if await engine.hasCyclingState(),
           let currentVisible = await engine.getCurrentCyclingText() {
            let trailingSeparator = await engine.cyclingTrailingSeparator()
            let expectedOriginal = currentVisible + trailingSeparator
            guard let newText = await engine.cycleCorrection(bundleId: bundleId) else { return }
            let replacement = newText + trailingSeparator
            let verified = await verificationContext(
                forExpectedSuffix: expectedOriginal,
                preserveSessionOnUnavailable: true
            )
            guard verified != nil || canUseManualReplayFallback(for: expectedOriginal, hostRuntimeProfile: hostProfile) else { return }

            let cyclingOriginal = await engine.getCyclingOriginalText()
            let intent: TextEditIntent = newText == cyclingOriginal ? .manualUndo : .manualCycle
            let applied = await performReplacement(
                intent: intent,
                expectedOriginal: expectedOriginal,
                replacement: replacement,
                verifiedContext: verified,
                allowClipboardFallback: false,
                allowEventReplayFallback: false,
                currentVisibleText: expectedOriginal,
                hostRuntimeProfile: hostProfile,
                proxy: nil
            )
            if let applied {
                let manualTransaction = await buildManualTransaction(
                    original: currentVisible,
                    replacement: newText,
                    intent: intent,
                    bundleId: bundleId
                )
                await commitReplacementTransaction(manualTransaction, editResult: applied, verifiedContext: verified)
                if shouldSwitchLayout(after: applied, hostRuntimeProfile: hostProfile) {
                    switchInputSourceIfNeeded(to: await engine.currentCyclingTargetLanguage(), transactionId: manualTransaction?.id)
                }
            }
            return
        }

        if let result = await engine.applyPendingSuggestion(),
           let corrected = result.corrected {
            let trailingSeparator = await engine.cyclingTrailingSeparator()
            let original = await engine.getCyclingOriginalText() ?? corrected
            let expectedOriginal = original + trailingSeparator
            let verified = await verificationContext(
                forExpectedSuffix: expectedOriginal,
                preserveSessionOnUnavailable: true
            )
            guard verified != nil || canUseManualReplayFallback(for: expectedOriginal, hostRuntimeProfile: hostProfile) else { return }
            let replacement = corrected + trailingSeparator

            let applied = await performReplacement(
                intent: .manualCycle,
                expectedOriginal: expectedOriginal,
                replacement: replacement,
                verifiedContext: verified,
                allowClipboardFallback: false,
                allowEventReplayFallback: false,
                currentVisibleText: expectedOriginal,
                hostRuntimeProfile: hostProfile,
                proxy: nil
            )
            if let applied {
                await commitReplacementTransaction(result.transaction, editResult: applied, verifiedContext: verified)
                if shouldSwitchLayout(after: applied, hostRuntimeProfile: hostProfile) {
                    switchInputSourceIfNeeded(to: result.targetLanguage, transactionId: result.transaction?.id)
                }
            }
            return
        }

        if let selectionSnapshot = textContextService.snapshotSelectionForManualAction(),
           !selectionSnapshot.selectedText.isEmpty,
           let replacement = await engine.correctLastWord(selectionSnapshot.selectedText, bundleId: bundleId) {
            let verified = VerifiedEditContext(
                snapshot: selectionSnapshot,
                verifiedRange: selectionSnapshot.selectedRange,
                verifiedText: selectionSnapshot.selectedText
            )
            let applied = await performReplacement(
                intent: .manualSelection,
                expectedOriginal: selectionSnapshot.selectedText,
                replacement: replacement,
                verifiedContext: verified,
                allowClipboardFallback: true,
                allowEventReplayFallback: false,
                currentVisibleText: selectionSnapshot.selectedText,
                hostRuntimeProfile: hostProfile,
                proxy: nil
            )
            if let applied {
                let transaction = await buildManualTransaction(
                    original: selectionSnapshot.selectedText,
                    replacement: replacement,
                    intent: .manualSelection,
                    bundleId: bundleId
                )
                await commitReplacementTransaction(transaction, editResult: applied, verifiedContext: verified)
                if shouldSwitchLayout(after: applied, hostRuntimeProfile: hostProfile) {
                    switchInputSourceIfNeeded(to: await engine.currentCyclingTargetLanguage(), transactionId: transaction?.id)
                }
            }
            return
        }

        if !inputSession.typedToken.isEmpty,
           let replacement = await engine.correctLastWord(inputSession.typedToken, bundleId: bundleId) {
            let verified = await verificationContext(
                forExpectedSuffix: inputSession.typedToken,
                preserveSessionOnUnavailable: true
            )
            guard verified != nil || canUseManualReplayFallback(for: inputSession.typedToken, hostRuntimeProfile: hostProfile) else { return }
            let applied = await performReplacement(
                intent: .manualCycle,
                expectedOriginal: inputSession.typedToken,
                replacement: replacement,
                verifiedContext: verified,
                allowClipboardFallback: false,
                allowEventReplayFallback: false,
                currentVisibleText: inputSession.typedToken,
                hostRuntimeProfile: hostProfile,
                proxy: nil
            )
            if let applied {
                let transaction = await buildManualTransaction(
                    original: inputSession.typedToken,
                    replacement: replacement,
                    intent: .manualCycle,
                    bundleId: bundleId
                )
                await commitReplacementTransaction(transaction, editResult: applied, verifiedContext: verified)
                if shouldSwitchLayout(after: applied, hostRuntimeProfile: hostProfile) {
                    switchInputSourceIfNeeded(to: await engine.currentCyclingTargetLanguage(), transactionId: transaction?.id)
                }
            }
            return
        }

        if let last = lastCommittedToken,
           let replacement = await engine.correctLastWord(last.token, bundleId: bundleId) {
            let expectedOriginal = last.token + last.separator
            let verified = await verificationContext(
                forExpectedSuffix: expectedOriginal,
                preserveSessionOnUnavailable: true
            )
            guard verified != nil || canUseManualReplayFallback(for: expectedOriginal, hostRuntimeProfile: hostProfile) else { return }
            let applied = await performReplacement(
                intent: .manualCycle,
                expectedOriginal: expectedOriginal,
                replacement: replacement + last.separator,
                verifiedContext: verified,
                allowClipboardFallback: false,
                allowEventReplayFallback: false,
                currentVisibleText: expectedOriginal,
                hostRuntimeProfile: hostProfile,
                proxy: nil
            )
            if let applied {
                let transaction = await buildManualTransaction(
                    original: last.token,
                    replacement: replacement,
                    intent: .manualCycle,
                    bundleId: bundleId
                )
                await commitReplacementTransaction(transaction, editResult: applied, verifiedContext: verified)
                if shouldSwitchLayout(after: applied, hostRuntimeProfile: hostProfile) {
                    switchInputSourceIfNeeded(to: await engine.currentCyclingTargetLanguage(), transactionId: transaction?.id)
                }
            }
            return
        }

        guard hostProfile.allowsManualSelectionClipboardFallback,
              selectionIntentState.isActive(at: timeProvider.now) else { return }

        if let clipboardSelection = await replacementService.getSelectedTextViaClipboard(proxy: nil),
           !clipboardSelection.isEmpty,
           let replacement = await engine.correctLastWord(clipboardSelection, bundleId: bundleId) {
            let request = TextEditRequest(
                intent: .manualSelection,
                expectedOriginal: clipboardSelection,
                replacement: replacement,
                verifiedRange: nil,
                snapshot: nil,
                hostRuntimeProfile: hostProfile,
                sessionRevision: inputSession.mutationSeq,
                allowClipboardFallback: true,
                allowEventReplayFallback: false,
                sessionIsDirty: false,
                currentTypedToken: clipboardSelection
            )
            let result = await applyRequest(request, proxy: nil)
            if let result, !result.needsResync {
                let transaction = await buildManualTransaction(
                    original: clipboardSelection,
                    replacement: replacement,
                    intent: .manualSelection,
                    bundleId: bundleId
                )
                await commitReplacementTransaction(transaction, editResult: result, verifiedContext: nil)
                if shouldSwitchLayout(after: result, hostRuntimeProfile: hostProfile) {
                    switchInputSourceIfNeeded(to: await engine.currentCyclingTargetLanguage(), transactionId: transaction?.id)
                }
            }
        }
    }

    private func performReplacement(
        intent: TextEditIntent,
        expectedOriginal: String,
        replacement: String,
        verifiedContext: VerifiedEditContext?,
        allowClipboardFallback: Bool,
        allowEventReplayFallback: Bool,
        currentVisibleText: String,
        hostRuntimeProfile: HostRuntimeProfile,
        proxy: CGEventTapProxy?
    ) async -> TextEditResult? {
        replacementService.setSkipEventPosting(skipEventPosting)
        runtimeState = .replacing

        if skipEventPosting {
            lastReplacement = (expectedOriginal.count, replacement)
        }

        let request = TextEditRequest(
            intent: intent,
            expectedOriginal: expectedOriginal,
            replacement: replacement,
            verifiedRange: verifiedContext?.verifiedRange,
            snapshot: verifiedContext?.snapshot,
            hostRuntimeProfile: hostRuntimeProfile,
            sessionRevision: inputSession.mutationSeq,
            allowClipboardFallback: allowClipboardFallback,
            allowEventReplayFallback: allowEventReplayFallback,
            sessionIsDirty: inputSession.isDirty,
            currentTypedToken: currentVisibleText
        )

        let result = await applyRequest(request, proxy: proxy)
        guard let result, !result.needsResync else {
            runtimeState = .dirtyNeedsResync
            return nil
        }

        if let snapshot = textContextService.snapshotFocusedText() {
            applySeed(textContextService.seedSession(from: snapshot), snapshot: snapshot)
        } else {
            inputSession.typedToken = ""
            inputSession.lastVerifiedSnapshot = nil
        }
        inputSession.isDirty = false
        lastCommittedTransaction = CommittedTransaction(visibleText: replacement, timestamp: timeProvider.now)
        runtimeState = .tracking
        return result
    }

    private func commitReplacementTransaction(
        _ transaction: CorrectionTransaction?,
        editResult: TextEditResult,
        verifiedContext: VerifiedEditContext?
    ) async {
        guard let transaction else { return }
        let committed = transaction.committed(
            sessionEpoch: inputSession.sessionEpoch,
            mutationSequence: inputSession.mutationSeq,
            strategy: editResult.strategy,
            verifiedContext: verifiedContext
        )
        await engine.commitTransaction(committed)
        if committed.wasAutoApplied {
            lastCorrectionTrackingId = committed.id
            lastCorrectionTime = timeProvider.now
        }
    }

    private func buildManualTransaction(
        original: String,
        replacement: String,
        intent: TextEditIntent,
        bundleId: String?
    ) async -> CorrectionTransaction? {
        guard let targetLanguage = await engine.currentCyclingTargetLanguage() else { return nil }
        let hypothesis = await engine.currentCyclingHypothesis()
        let focusedCapabilities = textContextService.resolveFocusedElementCapabilities()
        return CorrectionTransaction(
            sessionEpoch: inputSession.sessionEpoch,
            mutationSequence: inputSession.mutationSeq,
            token: original,
            replacement: replacement,
            bundleId: bundleId,
            elementFingerprint: focusedCapabilities?.capabilities.elementFingerprint,
            capabilityClass: focusedCapabilities?.capabilities.capabilityClass,
            intent: intent,
            targetLanguage: targetLanguage,
            hypothesis: hypothesis,
            features: nil,
            wasAutoApplied: false,
            inputSourceBefore: InputSourceManager.shared.currentLayoutId(),
            inputSourceAfterExpected: settings.activeLayouts[targetLanguage.rawValue]
        )
    }

    private func applyRequest(_ request: TextEditRequest, proxy: CGEventTapProxy?) async -> TextEditResult? {
        activeSyntheticTransactions += 1
        defer { activeSyntheticTransactions = max(0, activeSyntheticTransactions - 1) }

        do {
            let result = try await replacementService.replace(request, proxy: proxy)
            trace.log(
                .replacementFinished,
                fields: [
                    "strategy": result.strategy.rawValue,
                    "commit_kind": result.commitKind.rawValue,
                    "needs_resync": result.needsResync ? "true" : "false",
                    "host_profile": request.hostRuntimeProfile.rawValue,
                    "intent": request.intent.rawValue
                ]
            )
            if result.needsResync {
                if let snapshot = textContextService.snapshotFocusedText() {
                    applySeed(textContextService.seedSession(from: snapshot), snapshot: snapshot)
                } else {
                    resetSession(reason: "Replacement Resync", clearPhraseContext: false)
                }
            }
            return result
        } catch {
            logger.error("Failed to replace text: \(error.localizedDescription, privacy: .public)")
            resetSession(reason: "Replacement Error", clearPhraseContext: false)
            return nil
        }
    }

    private func verificationContext(
        forExpectedSuffix expectedText: String,
        preserveSessionOnUnavailable: Bool = false
    ) async -> VerifiedEditContext? {
        guard !expectedText.isEmpty else { return nil }

        if skipEventPosting || skipPIDCheck {
            return syntheticVerifiedContext(for: expectedText)
        }

        switch textContextService.verifyExpectedSuffix(expectedText, revision: inputSession.mutationSeq) {
        case .verified(let context):
            trace.log(
                .verificationResult,
                fields: [
                    "mode": "suffix",
                    "result": "verified",
                    "verified_text": context.verifiedText
                ]
            )
            inputSession.lastVerifiedSnapshot = context.snapshot
            inputSession.isDirty = false
            return context
        case .mismatch(let snapshot, let seed):
            trace.log(
                .verificationResult,
                fields: [
                    "mode": "suffix",
                    "result": "mismatch",
                    "expected_text": expectedText
                ]
            )
            if let snapshot, let seed {
                applySeed(seed, snapshot: snapshot, bumpSessionEpoch: true)
            } else {
                resetSession(reason: "Verification Mismatch", clearPhraseContext: false)
            }
            lastCommittedToken = nil
            clearTransliterationHint()
            Task { await engine.resetCycling() }
            return nil
        case .unavailable:
            trace.log(
                .verificationResult,
                fields: [
                    "mode": "suffix",
                    "result": "unavailable",
                    "expected_text": expectedText
                ]
            )
            if preserveSessionOnUnavailable {
                return nil
            }
            if let snapshot = textContextService.snapshotFocusedText() {
                applySeed(textContextService.seedSession(from: snapshot), snapshot: snapshot, bumpSessionEpoch: true)
            } else {
                resetSession(reason: "Verification Unavailable", clearPhraseContext: false)
            }
            lastCommittedToken = nil
            clearTransliterationHint()
            Task { await engine.resetCycling() }
            return nil
        }
    }

    /// Reads the focused text back and checks that it ends with `token` + `separator`
    /// (plus, if allowed, whatever the user has typed since).
    ///
    /// Retries briefly while the host app catches up with the keystrokes, and gives up
    /// as soon as the session moves on (`generation` changes).
    private func verifyCommittedBoundary(
        token: String,
        separator: String,
        generation: UInt64,
        allowTrailingText: Bool,
        canVerifyText: Bool
    ) async -> BoundaryVerification? {
        let committedText = token + separator

        if skipEventPosting || skipPIDCheck {
            let trailingText = inputSession.typedToken
            guard allowTrailingText || trailingText.isEmpty else { return nil }
            return BoundaryVerification(
                context: syntheticVerifiedContext(for: committedText + trailingText),
                includesSeparator: true,
                trailingText: trailingText
            )
        }

        // A host that doesn't expose its text won't start doing so within milliseconds;
        // don't hold the correction back polling it.
        guard canVerifyText else {
            trace.log(
                .verificationResult,
                fields: [
                    "mode": "boundary",
                    "result": "unavailable",
                    "attempt": "0",
                    "token": token,
                    "separator": separator
                ]
            )
            return nil
        }

        var latestSnapshot: FocusedTextSnapshot?
        var latestSeed: InputSessionSeed?
        var lastAttemptMismatched = false

        for attempt in 0..<Self.boundaryVerificationAttempts {
            if attempt > 0 {
                try? await Task.sleep(nanoseconds: Self.boundaryVerificationRetryDelay)
            }
            guard generation == boundaryGeneration else { return nil }

            let trailingCount = inputSession.typedToken.count
            guard allowTrailingText || trailingCount == 0 else { return nil }

            let result = trailingCount == 0
                ? textContextService.verifyCommittedBoundary(
                    token: token,
                    separator: separator,
                    revision: inputSession.mutationSeq
                )
                : textContextService.verifyCommittedBoundary(
                    token: token,
                    separator: separator,
                    trailingCharacterCount: trailingCount,
                    revision: inputSession.mutationSeq
                )

            switch result {
            case .verified(let context):
                trace.log(
                    .verificationResult,
                    fields: [
                        "mode": "boundary",
                        "result": "verified",
                        "verified_text": context.verifiedText,
                        "attempt": String(attempt)
                    ]
                )
                inputSession.lastVerifiedSnapshot = context.snapshot
                inputSession.isDirty = false

                let committedLength = committedText.utf16.count
                let verifiedLength = context.verifiedText.utf16.count
                let trailingText = verifiedLength > committedLength
                    ? (context.verifiedText as NSString).substring(from: committedLength)
                    : ""
                return BoundaryVerification(
                    context: context,
                    includesSeparator: verifiedLength >= committedLength,
                    trailingText: trailingText
                )
            case .unavailable:
                trace.log(
                    .verificationResult,
                    fields: [
                        "mode": "boundary",
                        "result": "unavailable",
                        "attempt": String(attempt),
                        "token": token,
                        "separator": separator
                    ]
                )
                lastAttemptMismatched = false
            case .mismatch(let snapshot, let seed):
                trace.log(
                    .verificationResult,
                    fields: [
                        "mode": "boundary",
                        "result": "mismatch",
                        "attempt": String(attempt),
                        "token": token,
                        "separator": separator
                    ]
                )
                latestSnapshot = snapshot
                latestSeed = seed
                lastAttemptMismatched = true
            }
        }

        guard lastAttemptMismatched, generation == boundaryGeneration else { return nil }

        if let latestSnapshot, let latestSeed {
            applySeed(latestSeed, snapshot: latestSnapshot, bumpSessionEpoch: true)
        } else {
            resetSession(reason: "Boundary Verification Mismatch", clearPhraseContext: false)
        }
        lastCommittedToken = nil
        clearTransliterationHint()
        Task { await engine.resetCycling() }
        return nil
    }

    private func canUseManualReplayFallback(
        for expectedText: String,
        hostRuntimeProfile: HostRuntimeProfile
    ) -> Bool {
        guard !expectedText.isEmpty else { return false }
        guard hostRuntimeProfile.allowsManualLastWordReplay else { return false }
        guard !inputSession.isDirty, activeSyntheticTransactions == 0 else { return false }

        let now = timeProvider.now
        if inputSession.typedToken == expectedText {
            return now.timeIntervalSince(lastKeyTime ?? .distantPast) <= 4.0
        }

        if let transaction = lastCommittedTransaction, transaction.visibleText == expectedText {
            return now.timeIntervalSince(transaction.timestamp) <= 10.0
        }

        if let last = lastCommittedToken, (last.token + last.separator) == expectedText {
            return now.timeIntervalSince(lastKeyTime ?? .distantPast) <= 10.0
        }

        return false
    }

    private func shouldAllowAutomaticReplayFallback(
        for expectedText: String,
        confidence: Double?,
        hostRuntimeProfile: HostRuntimeProfile
    ) -> Bool {
        guard !expectedText.isEmpty else { return false }
        guard hostRuntimeProfile.allowsAutomaticBlindReplay else { return false }
        guard !inputSession.isDirty, activeSyntheticTransactions == 0 else { return false }
        guard timeProvider.now.timeIntervalSince(inputSession.lastMutationAt) <= settings.blindReplayMaxDelay else {
            return false
        }

        let trimmed = expectedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= max(1, settings.minAutoCorrectWordLength),
              trimmed.count <= 18,
              trimmed.allSatisfy({ $0.isLetter }) else {
            return false
        }

        let threshold = CorrectionDecisionPolicy.blindAutoApplyThreshold(
            preset: settings.behaviorPreset,
            limits: settings.autoCorrectionLimits
        )
        guard let confidence, confidence >= threshold else {
            return false
        }

        return true
    }

    private func syntheticVerifiedContext(for expectedText: String) -> VerifiedEditContext {
        let snapshot = FocusedTextSnapshot(
            element: AXUIElementCreateSystemWide(),
            bundleId: lastActiveApp,
            pid: ProcessInfo.processInfo.processIdentifier,
            fullText: expectedText,
            selectedRange: NSRange(location: expectedText.utf16.count, length: 0),
            selectedText: "",
            caretLocation: expectedText.utf16.count,
            supportsAXSelectedTextWrite: false,
            supportsAXValueWrite: false,
            supportsAXRangeWrite: false,
            capabilities: AppEditCapabilities(
                supportsSelectedTextWrite: false,
                supportsSelectedRangeWrite: false,
                supportsValueWrite: false,
                supportsSelectionRead: false,
                supportsFullTextRead: true,
                isSecureOrReadBlind: true,
                capabilityClass: .secure,
                elementFingerprint: nil
            ),
            source: .synthetic,
            revision: inputSession.mutationSeq
        )
        return VerifiedEditContext(
            snapshot: snapshot,
            verifiedRange: NSRange(location: 0, length: expectedText.utf16.count),
            verifiedText: expectedText
        )
    }

    /// Called from the event tap for navigation keys, shortcuts, clicks etc.
    ///
    /// Must stay cheap: the event being handled (and everything queued behind it) is held
    /// until we return. The session is invalidated locally right away; re-reading the
    /// focused text over Accessibility is deferred until the burst of events settles.
    private func handleExternalInvalidation(reason: String, clearPhraseContext: Bool) {
        clearTransliterationHint()
        cancelStandaloneOptionTap()
        clearPendingCorrectionTracking()

        if !clearPhraseContext,
           let invalidatedAtMutationSeq,
           invalidatedAtMutationSeq == inputSession.mutationSeq {
            // Already invalidated by an earlier event of this burst (key auto-repeat,
            // mouse drag, scrolling) and nothing was typed since.
            scheduleDeferredResync()
            return
        }

        runtimeState = .dirtyNeedsResync
        trace.log(
            .sessionInvalidated,
            fields: [
                "reason": reason,
                "clear_phrase_context": clearPhraseContext ? "true" : "false",
                "session_epoch": String(inputSession.sessionEpoch),
                "mutation_seq": String(inputSession.mutationSeq)
            ]
        )

        if skipEventPosting {
            resetSession(reason: reason, clearPhraseContext: clearPhraseContext)
        } else {
            invalidateSessionLocally(clearPhraseContext: clearPhraseContext)
            scheduleDeferredResync()
        }

        lastCommittedToken = nil
        invalidatedAtMutationSeq = inputSession.mutationSeq
        Task { await engine.resetCycling() }
    }

    private func invalidateSessionLocally(clearPhraseContext: Bool) {
        inputSession.sessionEpoch &+= 1
        inputSession.mutationSeq &+= 1
        boundaryGeneration &+= 1
        inputSession.typedToken = ""
        if clearPhraseContext {
            inputSession.phraseContext = ""
        }
        inputSession.isDirty = true
        inputSession.lastVerifiedSnapshot = nil
        inputSession.lastMutationAt = timeProvider.now
        keyTimings.removeAll()
        lastKeyTime = nil
    }

    /// Re-reads the focused text once events have settled, unless the user has started
    /// typing in the meantime (then the locally tracked session is already correct).
    private func scheduleDeferredResync() {
        guard !skipEventPosting else { return }
        deferredResyncTask?.cancel()
        let expectedMutationSeq = inputSession.mutationSeq
        deferredResyncTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: Self.deferredResyncDelay)
            guard !Task.isCancelled, let self else { return }
            self.deferredResyncTask = nil
            self.performDeferredResync(expectedMutationSeq: expectedMutationSeq)
        }
    }

    private func performDeferredResync(expectedMutationSeq: UInt64) {
        guard expectedMutationSeq == inputSession.mutationSeq,
              activeSyntheticTransactions == 0,
              boundaryTasksInFlight == 0,
              let snapshot = textContextService.snapshotFocusedText() else {
            return
        }
        // Seeding bumps the mutation sequence, so the next invalidating event takes the
        // full path again and drops the seeded state.
        applySeed(textContextService.seedSession(from: snapshot), snapshot: snapshot)
    }

    private func matchesAutoReplace(_ plan: CorrectionPlan) -> Bool {
        if case .autoReplace = plan {
            return true
        }
        return false
    }

    private func resetSession(reason: String, clearPhraseContext: Bool) {
        logger.debug("Reset session: \(reason, privacy: .public)")
        runtimeState = .dirtyNeedsResync
        trace.log(
            .sessionInvalidated,
            fields: [
                "reason": reason,
                "clear_phrase_context": clearPhraseContext ? "true" : "false",
                "session_epoch": String(inputSession.sessionEpoch),
                "mutation_seq": String(inputSession.mutationSeq)
            ]
        )
        inputSession.sessionEpoch &+= 1
        inputSession.mutationSeq &+= 1
        boundaryGeneration &+= 1
        inputSession.typedToken = ""
        if clearPhraseContext {
            inputSession.phraseContext = ""
        }
        inputSession.isDirty = true
        inputSession.lastVerifiedSnapshot = nil
        inputSession.lastMutationAt = timeProvider.now
        inputSession.startedAt = .distantPast
        keyTimings.removeAll()
        lastKeyTime = nil
        lastCommittedToken = nil
        pendingLayoutSwitch = nil
    }

    private func recentCommittedTokenContext() -> CommittedTokenContext? {
        if let lastCommittedToken {
            return lastCommittedToken
        }

        let words = inputSession.phraseContext
            .split(whereSeparator: { $0.isWhitespace || $0.isNewline })
            .map(String.init)

        guard let token = words.last, !token.isEmpty else {
            return nil
        }

        return CommittedTokenContext(token: token, separator: "")
    }

    private func preserveCommittedBoundaryIfNeeded(token: String, separator: String) {
        guard !inputSession.isDirty else { return }

        let normalized = splitBufferContent(token).token
        guard !normalized.isEmpty else { return }

        if lastCommittedToken?.token != normalized {
            updatePhraseBuffer(with: normalized)
        }

        lastCommittedToken = CommittedTokenContext(token: normalized, separator: separator)
        lastCommittedTransaction = CommittedTransaction(
            visibleText: normalized + separator,
            timestamp: timeProvider.now
        )
    }

    private func applySeed(
        _ seed: InputSessionSeed,
        snapshot: FocusedTextSnapshot,
        clearPhraseContext: Bool = false,
        bumpSessionEpoch: Bool = false
    ) {
        if bumpSessionEpoch {
            inputSession.sessionEpoch &+= 1
        }
        inputSession.mutationSeq &+= 1
        boundaryGeneration &+= 1
        inputSession.typedToken = seed.typedToken
        inputSession.phraseContext = clearPhraseContext ? "" : seed.phraseContext
        inputSession.sourceApp = seed.sourceApp ?? ""
        inputSession.lastVerifiedSnapshot = snapshot
        inputSession.isDirty = false
        inputSession.lastMutationAt = timeProvider.now
        inputSession.startedAt = timeProvider.now
        keyTimings.removeAll()
        lastKeyTime = nil
    }

    private func bumpSessionMutation(at date: Date) {
        inputSession.mutationSeq &+= 1
        inputSession.lastMutationAt = date
        if inputSession.startedAt == .distantPast {
            inputSession.startedAt = date
        }
        inputSession.isDirty = false
    }

    private func expireStandaloneOptionTapIfNeeded() {
        guard let lastRelease = manualTriggerState.lastStandaloneReleaseAt else { return }
        if timeProvider.now.timeIntervalSince(lastRelease) > settings.manualTriggerDoubleTapWindow {
            manualTriggerState.lastStandaloneReleaseAt = nil
        }
    }

    private func cancelStandaloneOptionTap() {
        manualTriggerState.isPressed = false
        manualTriggerState.isStandaloneCandidate = false
        manualTriggerState.lastStandaloneReleaseAt = nil
    }

    package func splitBufferContent(_ content: String) -> (leading: String, token: String, trailing: String) {
        let chars = Array(content)
        var start = 0
        var end = chars.count

        while start < end {
            let char = chars[start]
            if isDelimiterLikeCharacter(char) {
                start += 1
            } else {
                break
            }
        }

        while end > start {
            let char = chars[end - 1]
            if isDelimiterLikeCharacter(char) {
                if LayoutMapper.shared.isAmbiguousBoundaryChar(char) {
                    break
                }
                end -= 1
            } else {
                break
            }
        }

        return (
            String(chars[0..<start]),
            String(chars[start..<end]),
            String(chars[end..<chars.count])
        )
    }

    private func isDelimiterLikeCharacter(_ ch: Character) -> Bool {
        ch.isWhitespace
            || ch.isNewline
            || ch == ","
            || ch == "."
            || ch == "!"
            || ch == "?"
            || ch == ";"
            || ch == ":"
            || ch == "\""
            || ch == "'"
            || ch == "("
            || ch == ")"
            || ch == "["
            || ch == "]"
            || ch == "{"
            || ch == "}"
            || ch == "-"
            || ch == "—"
    }

    private static let navigationKeys: Set<CGKeyCode> = [123, 124, 125, 126, 115, 119, 116, 121, 117]

    private func isWordBoundaryTrigger(_ text: String) -> Bool {
        guard let char = text.first else { return false }
        return char.isWhitespace || char.isNewline
    }

    private func mapLayoutToLanguage(_ layoutId: String?) -> Language? {
        guard let id = layoutId?.lowercased() else { return nil }
        if id.contains("russian") || id.contains("ru") { return .russian }
        if id.contains("hebrew") || id.contains("he") { return .hebrew }
        if id.contains("us") || id.contains("en") || id.contains("abc") || id.contains("british") { return .english }
        return nil
    }

    private func setTransliterationHint(_ suggestion: TransliterationSuggestion?, separator: String, commitRevision: UInt64) {
        if let suggestion {
            pendingTransliterationHint = PendingTransliterationHint(
                suggestion: suggestion,
                separator: separator,
                commitRevision: commitRevision,
                createdAt: timeProvider.now
            )
        } else {
            pendingTransliterationHint = nil
        }
        postTransliterationHint(suggestion)
    }

    private func clearTransliterationHint() {
        guard pendingTransliterationHint != nil else { return }
        pendingTransliterationHint = nil
        postTransliterationHint(nil)
    }

    private func postTransliterationHint(_ suggestion: TransliterationSuggestion?) {
        let userInfo: [AnyHashable: Any]? = suggestion.map {
            let token = splitBufferContent($0.replacement).token
            return [
                "id": $0.id.uuidString,
                "text": token,
                "language": $0.targetLanguage.rawValue
            ]
        }
        NotificationCenter.default.post(name: Notification.Name("TransliterationHint"), object: nil, userInfo: userInfo)
    }

    private func applyTransliterationHint(id: UUID) async {
        if !skipSecureInputCheck && IsSecureEventInputEnabled() {
            clearTransliterationHint()
            return
        }

        guard let pending = pendingTransliterationHint,
              pending.suggestion.id == id,
              pending.commitRevision == inputSession.mutationSeq,
              timeProvider.now.timeIntervalSince(pending.createdAt) < 8.0 else {
            clearTransliterationHint()
            return
        }

        let expectedOriginal = pending.suggestion.original + pending.separator
        let focusedCapabilities = textContextService.resolveFocusedElementCapabilities()
        let hostProfile = currentHostRuntimeProfile(
            bundleId: focusedCapabilities?.bundleId ?? NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
            capabilities: focusedCapabilities?.capabilities
        )
        let verified = await verificationContext(
            forExpectedSuffix: expectedOriginal,
            preserveSessionOnUnavailable: true
        )
        guard verified != nil || canUseManualReplayFallback(for: expectedOriginal, hostRuntimeProfile: hostProfile) else {
            clearTransliterationHint()
            return
        }

        let replacement = pending.suggestion.replacement + pending.separator
        let applied = await performReplacement(
            intent: .transliterationHint,
            expectedOriginal: expectedOriginal,
            replacement: replacement,
            verifiedContext: verified,
            allowClipboardFallback: false,
            allowEventReplayFallback: false,
            currentVisibleText: expectedOriginal,
            hostRuntimeProfile: hostProfile,
            proxy: nil
        )
        guard let applied else {
            clearTransliterationHint()
            return
        }

        let oldWord = splitBufferContent(pending.suggestion.original).token
        let newWord = splitBufferContent(pending.suggestion.replacement).token
        if !oldWord.isEmpty, !newWord.isEmpty {
            replaceLastPhraseBufferWord(from: oldWord, to: newWord)
        }

        lastCommittedToken = CommittedTokenContext(token: pending.suggestion.replacement, separator: pending.separator)
        if let transaction = await buildManualTransaction(
            original: pending.suggestion.original,
            replacement: pending.suggestion.replacement,
            intent: .transliterationHint,
            bundleId: NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        ) {
            await commitReplacementTransaction(transaction, editResult: applied, verifiedContext: verified)
        }
        clearTransliterationHint()
    }

    private func replaceLastPhraseBufferWord(from old: String, to new: String) {
        let words = inputSession.phraseContext.split(separator: " ").map(String.init)
        guard let last = words.last, last == old else { return }
        let updated = words.dropLast() + [new]
        inputSession.phraseContext = updated.joined(separator: " ")
    }

    private func updatePhraseBuffer(with word: String) {
        guard !word.isEmpty else { return }

        if inputSession.phraseContext.isEmpty {
            inputSession.phraseContext = word
        } else {
            inputSession.phraseContext += " " + word
        }

        if inputSession.phraseContext.count > 100 {
            inputSession.phraseContext = String(inputSession.phraseContext.suffix(100))
            if let firstSpace = inputSession.phraseContext.firstIndex(of: " ") {
                inputSession.phraseContext = String(inputSession.phraseContext[inputSession.phraseContext.index(after: firstSpace)...])
            }
        }
    }

    private func updateObservedAXApp() {
        stopAXObserver()

        guard !skipEventPosting,
              let app = NSWorkspace.shared.frontmostApplication else { return }

        observedAppPID = app.processIdentifier

        var observer: AXObserver?
        let result = AXObserverCreate(app.processIdentifier, Self.axNotificationCallback, &observer)
        guard result == .success, let observer else { return }

        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        let notifications = [
            kAXFocusedUIElementChangedNotification,
            kAXSelectedTextChangedNotification,
            kAXValueChangedNotification
        ]

        for notification in notifications {
            AXObserverAddNotification(
                observer,
                appElement,
                notification as CFString,
                Unmanaged.passUnretained(self).toOpaque()
            )
        }

        axObserver = observer
        let source = AXObserverGetRunLoopSource(observer)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
    }

    private func stopAXObserver() {
        if let observer = axObserver {
            let source = AXObserverGetRunLoopSource(observer)
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        axObserver = nil
        observedAppPID = nil
    }

    private func clearPendingCorrectionTracking() {
        lastCorrectionTrackingId = nil
        backspaceReportedForId = nil
        lastCorrectionTime = .distantPast
    }

    private func handleAXNotification(_ notification: String) {
        guard activeSyntheticTransactions == 0 else { return }

        switch notification {
        case String(kAXFocusedUIElementChangedNotification):
            textContextService.invalidateCachedCapabilities()
            handleExternalInvalidation(reason: "AX Focused UI Element Changed", clearPhraseContext: false)
        case String(kAXSelectedTextChangedNotification), String(kAXValueChangedNotification):
            // These fire for every keystroke (and for unrelated elements of the app); only
            // resync once things are quiet and we are not in the middle of a word.
            guard inputSession.typedToken.isEmpty else { return }
            scheduleDeferredResync()
        default:
            handleExternalInvalidation(reason: "AX \(notification)", clearPhraseContext: false)
        }
    }
}

private extension CorrectionPlan {
    var traceValue: String {
        switch self {
        case .none:
            return "none"
        case .hint:
            return "hint"
        case .manualCycle:
            return "manual_cycle"
        case .autoReplace:
            return "auto_replace"
        }
    }
}

extension CGEvent {
    var keyboardEventCharacters: String? {
        guard let nsEvent = NSEvent(cgEvent: self) else { return nil }
        return nsEvent.characters
    }
}
