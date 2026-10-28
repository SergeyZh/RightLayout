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
        /// Characters in the field between the last word of `phraseContext` and the word
        /// being typed (its separator, what is left of a word being erased), or nil when
        /// the session doesn't know what lies before the caret.
        var charactersAfterPhrase: Int?
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
        /// Trigger key of the current/last tap; both taps must use the same key.
        var keyCode: CGKeyCode?
    }

    /// An Enter held back while deciding whether the word it ends needs correcting.
    private struct HeldEnter {
        let id: UInt64
        let keyCode: CGKeyCode
        let flags: CGEventFlags
        /// The word is being replaced; this Enter is swallowed no matter what.
        var consumed = false
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
    private var lastCorrectionTrackingId: UUID?
    /// How many characters before the caret reach back to the start of the word last
    /// corrected automatically; Backspace undoes the correction once it erased them all.
    private var correctionErase: (id: UUID, remaining: Int)?
    private var backspaceReportedForId: UUID?
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
    private var heldEnter: HeldEnter?
    private var heldEnterSeq: UInt64 = 0
    /// After a correction made on Enter, the next Enter goes straight through.
    private var passNextEnter = false
    private let keyEventPoster = CGEventPoster()
    /// Keystrokes typed while a correction is applied, let through once it is done.
    private var heldUserKeys: [(event: CGEvent, proxy: CGEventTapProxy)] = []
    private var userKeyHoldDepth = 0
    /// When the current hold started; nil once it ran too long and keys go through again.
    private var userKeyHoldStartedAt: Date?
    private var userKeyHoldGeneration: UInt64 = 0

    private static let returnKeyCodes: Set<CGKeyCode> = [36, 76]
    /// Upper bound for holding Enter while the correction is being decided.
    private static let heldEnterTimeout: UInt64 = 500_000_000

    /// Delay before re-reading the focused text after cursor movement or other external
    /// changes. Reading it synchronously from the event tap stalls every keystroke.
    private static let deferredResyncDelay: UInt64 = 90_000_000
    /// Re-reads of a field that is still catching up with the keystrokes.
    private static let deferredResyncLagRetries = 3
    private static let boundaryVerificationAttempts = 12
    private static let boundaryVerificationRetryDelay: UInt64 = 5_000_000
    /// A host that visibly lags behind the keystrokes (Slack, in a long message) is
    /// waited for longer, up to about a quarter of a second more.
    private static let laggingHostRetries = 10
    private static let laggingHostRetryDelay: UInt64 = 25_000_000
    /// Upper bound for holding the user's keystrokes while a correction is applied.
    private static let maxUserKeyHold: TimeInterval = 1.0
    private static let maxHeldUserKeys = 32

    package private(set) var lastReplacement: (deletedCount: Int, insertedText: String)?
    /// The last hotkey conversion of selected text, so converting it again toggles back.
    private var lastSelectionConversion: SelectionConversion?
    /// Held Enters that were let through (for tests; nothing is posted with `skipEventPosting`).
    package private(set) var releasedEnterCount = 0
    /// The word being typed (for tests).
    package var typedTokenForTesting: String { inputSession.typedToken }
    /// The words before it (for tests).
    package var phraseContextForTesting: String { inputSession.phraseContext }
    /// The app being typed in, as if it had just been activated (for tests).
    package var activeAppForTesting: String {
        get { lastActiveApp }
        set { lastActiveApp = newValue }
    }

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

        // Excluded apps are never monitored: the manual trigger does nothing there either.
        if isActiveAppExcluded {
            cancelStandaloneOptionTap()
            return Unmanaged.passUnretained(event)
        }

        if settings.hotkeyEnabled, let triggerMask = manualTriggerModifierMask(forKeyCode: keyCode) {
            handleManualTriggerFlagsChanged(keyCode: keyCode, flags: flags, modifierMask: triggerMask)
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

    /// Modifier flag of the configured manual trigger key, if `keyCode` is one.
    private func manualTriggerModifierMask(forKeyCode keyCode: CGKeyCode) -> CGEventFlags? {
        let mode = settings.manualTriggerMode
        if mode.usesOption, keyCode == settings.manualTriggerOptionKeyCode {
            return .maskAlternate
        }
        if mode.usesShift, keyCode == settings.manualTriggerShiftKeyCode {
            return .maskShift
        }
        return nil
    }

    /// Whether the modifier key `keyCode` itself is down, telling the left and right
    /// keys apart (holding the other Shift must not look like a press of this one).
    private static func isModifierKeyDown(keyCode: CGKeyCode, flags: CGEventFlags, modifierMask: CGEventFlags) -> Bool {
        // NX_DEVICE{L,R}{SHIFT,ALT}KEYMASK
        let deviceBits: [CGKeyCode: UInt64] = [56: 0x02, 60: 0x04, 58: 0x20, 61: 0x40]
        let pairBits: UInt64 = modifierMask == .maskShift ? 0x06 : 0x60
        guard let bit = deviceBits[keyCode], flags.rawValue & pairBits != 0 || !flags.contains(modifierMask) else {
            // Synthetic events may carry only the generic flag.
            return flags.contains(modifierMask)
        }
        return flags.rawValue & bit != 0
    }

    private func handleManualTriggerFlagsChanged(keyCode: CGKeyCode, flags: CGEventFlags, modifierMask: CGEventFlags) {
        let now = timeProvider.now

        if Self.isModifierKeyDown(keyCode: keyCode, flags: flags, modifierMask: modifierMask) {
            if manualTriggerState.keyCode != keyCode {
                // A tap of a different trigger key doesn't pair with the previous one.
                manualTriggerState.lastStandaloneReleaseAt = nil
            }
            manualTriggerState.keyCode = keyCode
            manualTriggerState.isPressed = true
            manualTriggerState.isStandaloneCandidate = true
            return
        }

        guard manualTriggerState.isPressed, manualTriggerState.keyCode == keyCode else { return }
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

        if shouldHoldUserKey(now: now), let copy = event.copy() {
            heldUserKeys.append((copy, proxy))
            return nil
        }

        // The user kept typing while an Enter was held: let it through first.
        if heldEnter != nil {
            releaseHeldEnterEarly(proxy: proxy)
        }

        // Excluded apps are never monitored: nothing typed there is tracked or corrected.
        if isActiveAppExcluded {
            forgetSessionInExcludedApp()
            return Unmanaged.passUnretained(event)
        }

        let isReturnKey = Self.returnKeyCodes.contains(keyCode)
        if !isReturnKey {
            passNextEnter = false
        }

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
        }

        if Self.navigationKeys.contains(keyCode) {
            if flags.contains(.maskShift) {
                selectionIntentState.mark(now: now, source: "shiftNavigation")
            }
            handleExternalInvalidation(reason: "Navigation", clearPhraseContext: false)
            return Unmanaged.passUnretained(event)
        }

        if isReturnKey, shouldHoldEnter(now: now) {
            return holdEnter(keyCode: keyCode, flags: flags, proxy: proxy, now: now)
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

        // A pause while typing a word keeps it: cutting off its start left the rest to be
        // judged alone ("ameeting" was never checked), and a word ended after a pause
        // ("часа." before sending) was never checked at all. Clicks, focus changes and
        // shortcuts, which can move the caret, reset the session on their own.
        if !inputSession.typedToken.isEmpty,
           let last = lastKeyTime,
           now.timeIntervalSince(last) > ThresholdsConfig.shared.timing.bufferTimeout {
            trace.log(.bufferTimeout, fields: ["kept": inputSession.typedToken])
            keyTimings.removeAll()
        }

        if let erase = correctionErase {
            correctionErase = (erase.id, erase.remaining + chars.count)
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
                if let gap = inputSession.charactersAfterPhrase {
                    inputSession.charactersAfterPhrase = gap + chars.count
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
        if trace.isEnabled {
            trace.log(
                .keyTyped,
                fields: [
                    "chars": chars,
                    "key_code": String(keyCode),
                    "buffer": inputSession.typedToken,
                    "layout": InputSourceManager.shared.currentLayoutId()
                ]
            )
        }

        if let last = lastKeyTime {
            keyTimings.append(now.timeIntervalSince(last))
        } else {
            keyTimings.append(0)
        }
        lastKeyTime = now

        Task { await engine.resetCycling() }

        return Unmanaged.passUnretained(event)
    }

    // MARK: Keystrokes typed during a correction

    /// Holds the user's keystrokes until `endHoldingUserKeys`. Typed while a word was
    /// retyped, they landed between its characters, or right after it before it was read
    /// back, which then failed and switched the layout back ("Привет, Са" + "if!").
    func beginHoldingUserKeys() {
        if userKeyHoldDepth == 0 {
            userKeyHoldStartedAt = timeProvider.now
            userKeyHoldGeneration &+= 1
            let generation = userKeyHoldGeneration
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(Self.maxUserKeyHold * 1_000_000_000))
                guard let self, self.userKeyHoldGeneration == generation, self.userKeyHoldDepth > 0 else { return }
                self.stopHoldingUserKeys()
            }
        }
        userKeyHoldDepth += 1
    }

    func endHoldingUserKeys() {
        userKeyHoldDepth = max(0, userKeyHoldDepth - 1)
        if userKeyHoldDepth == 0 {
            stopHoldingUserKeys()
        }
    }

    private func shouldHoldUserKey(now: Date) -> Bool {
        guard userKeyHoldDepth > 0, let startedAt = userKeyHoldStartedAt else { return false }
        guard now.timeIntervalSince(startedAt) <= Self.maxUserKeyHold,
              heldUserKeys.count < Self.maxHeldUserKeys else {
            stopHoldingUserKeys()
            return false
        }
        return true
    }

    /// Lets the held keystrokes through, in order, as if they were typed now: they are
    /// tracked like any others, and land in the layout the correction switched to.
    private func stopHoldingUserKeys() {
        userKeyHoldStartedAt = nil
        let held = heldUserKeys
        heldUserKeys.removeAll()
        for key in held {
            guard let passed = handleEvent(proxy: key.proxy, type: .keyDown, event: key.event),
                  !skipEventPosting else { continue }
            passed.takeUnretainedValue().tapPostEvent(key.proxy)
        }
    }

    /// The app being typed in. Until another app is activated, the one frontmost at launch.
    private var activeAppBundleId: String {
        if !lastActiveApp.isEmpty { return lastActiveApp }
        return NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""
    }

    private var isActiveAppExcluded: Bool {
        !settings.excludedApps.isEmpty && settings.isExcluded(bundleId: activeAppBundleId)
    }

    /// Drops what was tracked before the app became excluded (it was added to the list
    /// while in use), so the manual trigger can't convert it later.
    private func forgetSessionInExcludedApp() {
        cancelStandaloneOptionTap()
        clearTransliterationHint()
        guard !inputSession.typedToken.isEmpty
                || !inputSession.phraseContext.isEmpty
                || lastCommittedToken != nil else { return }
        clearPendingCorrectionTracking()
        Task { await engine.resetCycling() }
        resetSession(reason: "Excluded App", clearPhraseContext: true)
    }

    private func shouldHoldEnter(now: Date) -> Bool {
        if passNextEnter {
            passNextEnter = false
            return false
        }
        guard settings.holdEnterForCorrection,
              settings.isEnabled,
              !isActiveAppExcluded,
              inputSession.typedToken.contains(where: \.isLetter) else {
            return false
        }
        // Also after a pause: the word is kept across it, and is worth checking before
        // the message goes out.
        return true
    }

    /// Swallows the Enter and decides whether the word before it needs correcting.
    /// If it does, the word is fixed and the Enter stays swallowed, so a chat message
    /// isn't sent garbled (or wrongly "fixed") without the user seeing it first.
    /// Otherwise the Enter is posted again right away.
    private func holdEnter(
        keyCode: CGKeyCode,
        flags: CGEventFlags,
        proxy: CGEventTapProxy,
        now: Date
    ) -> Unmanaged<CGEvent>? {
        cancelStandaloneOptionTap()
        clearTransliterationHint()

        let token = inputSession.typedToken
        inputSession.typedToken = ""
        boundaryGeneration &+= 1
        bumpSessionMutation(at: now)
        lastKeyTime = now
        let expectedMutationSeq = inputSession.mutationSeq
        let generation = boundaryGeneration
        let latencies = keyTimings
        keyTimings.removeAll()

        heldEnterSeq &+= 1
        let id = heldEnterSeq
        heldEnter = HeldEnter(id: id, keyCode: keyCode, flags: flags)

        Task { @MainActor in
            let replaced = await processCommittedBoundary(
                token: token,
                separator: "",
                proxy: proxy,
                expectedMutationSeq: expectedMutationSeq,
                boundaryGeneration: generation,
                latencies: latencies,
                heldEnterId: id
            )
            finishHeldEnter(id: id, replaced: replaced)
        }
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: Self.heldEnterTimeout)
            self?.heldEnterTimedOut(id: id)
        }
        return nil
    }

    private func markHeldEnterConsumed(_ id: UInt64?) {
        guard let id, heldEnter?.id == id else { return }
        heldEnter?.consumed = true
    }

    private func finishHeldEnter(id: UInt64, replaced: Bool) {
        guard let held = heldEnter, held.id == id else { return }
        heldEnter = nil
        if replaced || held.consumed {
            // The word was changed (or a change was attempted): let the user look at it.
            // Their next Enter goes straight through.
            passNextEnter = true
        } else {
            postHeldEnter(held, proxy: nil)
        }
    }

    private func heldEnterTimedOut(id: UInt64) {
        guard let held = heldEnter, held.id == id, !held.consumed else { return }
        heldEnter = nil
        // Too late to correct before sending; drop the pending correction.
        boundaryGeneration &+= 1
        postHeldEnter(held, proxy: nil)
    }

    private func releaseHeldEnterEarly(proxy: CGEventTapProxy) {
        guard let held = heldEnter else { return }
        heldEnter = nil
        guard !held.consumed else { return }
        boundaryGeneration &+= 1
        postHeldEnter(held, proxy: proxy)
    }

    private func postHeldEnter(_ held: HeldEnter, proxy: CGEventTapProxy?) {
        releasedEnterCount += 1
        guard !skipEventPosting else { return }
        keyEventPoster.postKeyEvent(keyCode: held.keyCode, flags: held.flags, proxy: proxy)
    }

    private func handleBackspace() {
        clearTransliterationHint()
        trace.log(.backspace, fields: ["buffer": inputSession.typedToken])

        if !inputSession.typedToken.isEmpty {
            inputSession.typedToken.removeLast()
            bumpSessionMutation(at: timeProvider.now)
        } else {
            erasePhraseContextCharacter()
            inputSession.isDirty = true
            inputSession.lastVerifiedSnapshot = nil
            inputSession.mutationSeq &+= 1
            boundaryGeneration &+= 1
            lastCommittedToken = nil
        }

        lastKeyTime = timeProvider.now
        Task { await engine.resetCycling() }

        // Erasing the corrected word whole takes the correction back. Fewer Backspaces fix
        // its ending or a typo in the next word, which says nothing against the
        // correction (three quick ones used to count as taking it back, and made
        // contexts where most corrections were kept cautious).
        guard let erase = correctionErase, erase.id == lastCorrectionTrackingId else {
            correctionErase = nil
            return
        }
        guard erase.remaining <= 1 else {
            correctionErase = (erase.id, erase.remaining - 1)
            return
        }
        correctionErase = nil
        let id = erase.id
        guard backspaceReportedForId != id else { return }
        backspaceReportedForId = id
        Task {
            if let transaction = await engine.transaction(for: id),
               let transactionEpoch = transaction.sessionEpoch,
               transactionEpoch != self.inputSession.sessionEpoch {
                return
            }
            await engine.reportNegativeFeedback(id: id, reason: .backspaceBurst)
        }
    }

    private func keepCommittedWordAsTyped(token: String, separator: String) {
        updatePhraseBuffer(with: splitBufferContent(token).token)
        lastCommittedToken = CommittedTokenContext(token: token, separator: separator)
        clearTransliterationHint()
        lastCorrectionTrackingId = nil
        lastCorrectionTime = .distantPast
        Task { await engine.resetCycling() }
    }

    /// Returns `true` if the word was replaced.
    @discardableResult
    private func processCommittedBoundary(
        token: String,
        separator: String,
        proxy: CGEventTapProxy,
        expectedMutationSeq: UInt64,
        boundaryGeneration generation: UInt64,
        latencies: [TimeInterval],
        heldEnterId: UInt64? = nil
    ) async -> Bool {
        boundaryTasksInFlight += 1
        defer { boundaryTasksInFlight -= 1 }

        runtimeState = .boundaryPending
        guard generation == boundaryGeneration else {
            preserveCommittedBoundaryIfNeeded(token: token, separator: separator)
            return false
        }

        // With automatic correction off the word stays as typed, but is still tracked so
        // the manual trigger can convert it.
        guard settings.isEnabled else {
            keepCommittedWordAsTyped(token: token, separator: separator)
            return false
        }

        let isSyntheticHost = skipEventPosting || skipPIDCheck
        let focusedCapabilities = textContextService.resolveFocusedElementCapabilities()
        let bundleId = focusedCapabilities?.bundleId ?? lastActiveApp
        let hostProfile = currentHostRuntimeProfile(bundleId: bundleId, capabilities: focusedCapabilities?.capabilities)
        let canVerifyText = isSyntheticHost
            || (hostProfile.editingEnvironment == .accessibility
                && focusedCapabilities?.capabilities.supportsFullTextRead == true)
        trace.log(
            .boundaryDetected,
            fields: [
                "bundle_id": bundleId,
                "host_profile": hostProfile.rawValue,
                "capabilities": focusedCapabilities.map { Self.traceValue(of: $0.capabilities) },
                "session_epoch": String(inputSession.sessionEpoch),
                "mutation_seq": String(inputSession.mutationSeq),
                "token": token,
                "separator": separator
            ]
        )
        let editingEnvironment = hostProfile.editingEnvironment
        let appBundleId = isSyntheticHost ? lastActiveApp : bundleId

        // The focused field can belong to an excluded app whose activation hasn't been
        // handled yet.
        if settings.isExcluded(bundleId: appBundleId) {
            forgetSessionInExcludedApp()
            return false
        }

        if await engine.checkForRetype(text: token, bundleId: appBundleId) {
            keepCommittedWordAsTyped(token: token, separator: separator)
            return false
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
                "token": token,
                "corrected": planned.result.corrected,
                "pending": planned.result.pendingOriginal.map { "\($0)→\(planned.result.pendingCorrection ?? "")" },
                "hypothesis": planned.result.evidence?.decision.layoutHypothesis.rawValue,
                "token_kind": planned.result.evidence.map { String(describing: $0.tokenKind) },
                "margin": planned.result.evidence.map { String(format: "%.3f", $0.winnerMargin) },
                "phrase": inputSession.phraseContext,
                "why": planned.trail
            ]
        )

        // A word ended by a held Enter gets no later context to confirm a suggestion, and
        // the Enter is held precisely so the message isn't sent garbled: apply it now. The
        // Enter stays held, so the user sees the change before sending.
        if skipEventPosting || heldEnterId != nil,
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
            return false
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
            beginHoldingUserKeys()
            defer { endHoldingUserKeys() }

            // As for a single word: switch first, so the next keystrokes land in the new
            // layout. Switched after the replacement, the next letter could still come in
            // the old one ("Z tve" + "уже" became "Я ему eже").
            let targetLanguage = planned.result.targetLanguage
            let layoutBeforeSwitch = InputSourceManager.shared.currentLayoutId()
            var switchedEarly = false
            if editingEnvironment == .accessibility && canVerifyText {
                switchedEarly = switchInputSourceIfNeeded(to: targetLanguage, transactionId: planned.result.transaction?.id)
            }

            let combinedStem = pendingOriginal + last.separator + token
            guard let combinedVerification = await verifyCommittedBoundary(
                token: combinedStem,
                separator: separator,
                generation: generation,
                allowTrailingText: false,
                canVerifyText: canVerifyText
            ) else {
                if switchedEarly {
                    revertInputSource(to: layoutBeforeSwitch)
                }
                if generation != boundaryGeneration || !inputSession.typedToken.isEmpty {
                    preserveCommittedBoundaryIfNeeded(token: token, separator: separator)
                    await engine.resetCycling()
                }
                return false
            }
            let combinedContext = combinedVerification.context

            markHeldEnterConsumed(heldEnterId)

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
                proxy: proxy,
                unverifiedSuffix: combinedVerification.includesSeparator ? "" : separator
            )
            guard let applied else {
                if switchedEarly {
                    revertInputSource(to: layoutBeforeSwitch)
                }
                return false
            }

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
            let switchAllowed = shouldSwitchLayout(after: applied, hostRuntimeProfile: hostProfile)
            if switchedEarly {
                if !switchAllowed {
                    revertInputSource(to: layoutBeforeSwitch)
                }
            } else if switchAllowed {
                switchInputSourceIfNeeded(to: targetLanguage, transactionId: planned.result.transaction?.id)
            }
            return true
        }

        switch planned.plan {
        case .autoReplace(let candidate):
            beginHoldingUserKeys()
            defer { endHoldingUserKeys() }
            let transaction = candidate.transaction ?? planned.result.transaction
            let targetLanguage = planned.result.targetLanguage
            let blindReplayRefusal: String?
            if !inputSession.typedToken.isEmpty {
                blindReplayRefusal = "typing_next_word"
            } else if separator.contains(where: { $0.isNewline }) {
                blindReplayRefusal = "newline"
            } else {
                blindReplayRefusal = automaticReplayFallbackRefusal(
                    for: token + separator,
                    replacement: candidate.replacement,
                    confidence: planned.result.confidence,
                    hostRuntimeProfile: hostProfile
                )
            }
            let allowEventReplayFallback = blindReplayRefusal == nil

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
                return false
            }

            guard verification != nil || allowEventReplayFallback else {
                if switchedEarly {
                    revertInputSource(to: layoutBeforeSwitch)
                }
                trace.log(
                    .replacementSkipped,
                    fields: [
                        "token": token,
                        "replacement": candidate.replacement,
                        "reason": canVerifyText ? "verification_failed" : "text_unreadable",
                        "blind_replay": blindReplayRefusal
                    ]
                )
                // The word stays as typed: the hotkey must correct it, not "undo" a
                // correction that never happened (which made it work only on the
                // second press).
                await engine.resetCycling()
                updatePhraseBuffer(with: splitBufferContent(token).token)
                lastCommittedToken = CommittedTokenContext(token: token, separator: separator)
                setTransliterationHint(nil, separator: separator, commitRevision: expectedMutationSeq)
                return false
            }

            let expectedOriginal: String
            let replacement: String
            if let verification {
                let trailingText = switchedEarly
                    ? convertTypedTail(
                        verification.trailingText,
                        charactersTypedBeforeSwitch: charactersTypedBeforeSwitch,
                        from: transaction?.hypothesis?.sourceLanguage ?? currentLanguage,
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

            markHeldEnterConsumed(heldEnterId)

            let applied = await performReplacement(
                intent: .autoCorrection,
                expectedOriginal: expectedOriginal,
                replacement: replacement,
                verifiedContext: verification?.context,
                allowClipboardFallback: false,
                allowEventReplayFallback: allowEventReplayFallback,
                currentVisibleText: expectedOriginal,
                hostRuntimeProfile: hostProfile,
                proxy: proxy,
                unverifiedSuffix: verification.map { $0.includesSeparator ? "" : separator } ?? "",
                typedTailTransform: typedTailTransform(
                    switchedEarly: switchedEarly,
                    from: transaction?.hypothesis?.sourceLanguage ?? currentLanguage,
                    to: targetLanguage
                )
            )
            guard let applied else {
                if switchedEarly {
                    revertInputSource(to: layoutBeforeSwitch)
                }
                // The word is still there as typed: let the hotkey correct it rather
                // than "undo" a correction that never happened.
                await engine.resetCycling()
                if !inputSession.isDirty {
                    lastCommittedToken = CommittedTokenContext(token: token, separator: separator)
                }
                return false
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
            runtimeState = .tracking
            return true
        case .hint, .none:
            updatePhraseBuffer(with: splitBufferContent(outputToken).token)
            lastCommittedToken = CommittedTokenContext(token: outputToken, separator: separator)
            setTransliterationHint(planned.result.transliterationSuggestion, separator: separator, commitRevision: expectedMutationSeq)
        case .manualCycle:
            break
        }
        runtimeState = .tracking
        return false
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
        result += Self.convertLettersTypedAfterSwitch(
            String(characters[headCount...]),
            from: source,
            to: target,
            activeLayouts: activeLayouts
        )
        return result
    }

    /// Letters typed after a layout switch may still arrive in the old layout (Chromium
    /// apps pick the switch up late); convert those, and leave everything else.
    nonisolated static func convertLettersTypedAfterSwitch(
        _ text: String,
        from source: Language,
        to target: Language,
        activeLayouts: [String: String]
    ) -> String {
        var result = ""
        for character in text {
            let original = String(character)
            if character.isLetter,
               let converted = LayoutMapper.shared.convert(original, from: source, to: target, activeLayouts: activeLayouts),
               converted != original,
               converted.allSatisfy({ $0.isLetter }) {
                result += converted
            } else {
                result += original
            }
        }
        return result
    }

    /// Converts the letters typed between reading the text back and retyping it, the
    /// same way as the ones read back: they were typed after the early switch too
    /// ("ghbdtn tcnm" became "привет еcnm").
    private func typedTailTransform(switchedEarly: Bool, from source: Language?, to target: Language?) -> (@Sendable (String) -> String)? {
        guard switchedEarly, let source, let target, source != target else { return nil }
        let activeLayouts = settings.activeLayouts
        return { tail in
            Self.convertLettersTypedAfterSwitch(tail, from: source, to: target, activeLayouts: activeLayouts)
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

    private static func traceValue(of capabilities: AppEditCapabilities) -> String {
        var flags = [capabilities.capabilityClass.rawValue]
        if capabilities.supportsFullTextRead { flags.append("read") }
        if capabilities.supportsSelectionRead { flags.append("selection_read") }
        if capabilities.supportsSelectedTextWrite { flags.append("selected_text_write") }
        if capabilities.supportsSelectedRangeWrite { flags.append("range_write") }
        if capabilities.supportsValueWrite { flags.append("value_write") }
        return flags.joined(separator: ",")
    }

    /// Whether to switch the layout after a replacement. A retyped word that can't be read
    /// back only switches it in hosts known to take retyping, unless the user asked for the
    /// correction (`manual`): they see the result, and expect to keep typing in its layout.
    private func shouldSwitchLayout(
        after result: TextEditResult,
        hostRuntimeProfile: HostRuntimeProfile,
        manual: Bool = false
    ) -> Bool {
        switch result.commitKind {
        case .verifiedCommit:
            return true
        case .blindCommit:
            return manual || hostRuntimeProfile.switchSafeAfterBlindReplay
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

    private func convertSelection(
        _ selectionSnapshot: FocusedTextSnapshot,
        bundleId: String?,
        hostProfile: HostRuntimeProfile
    ) async {
        let selectedText = selectionSnapshot.selectedText
        let replacement: String
        let targetLanguage: Language?
        if let reverted = lastSelectionConversion?.reverting(selectedText) {
            await engine.resetCycling()
            replacement = reverted
            targetLanguage = SelectionConversion.dominantLanguage(of: reverted)
        } else if let corrected = await engine.correctLastWord(selectedText, bundleId: bundleId) {
            replacement = corrected
            targetLanguage = await engine.currentCyclingTargetLanguage()
        } else {
            return
        }
        guard replacement != selectedText else { return }

        let verified = VerifiedEditContext(
            snapshot: selectionSnapshot,
            verifiedRange: selectionSnapshot.selectedRange,
            verifiedText: selectedText
        )
        let applied = await performReplacement(
            intent: .manualSelection,
            expectedOriginal: selectedText,
            replacement: replacement,
            verifiedContext: verified,
            allowClipboardFallback: true,
            allowEventReplayFallback: false,
            currentVisibleText: selectedText,
            hostRuntimeProfile: hostProfile,
            proxy: nil,
            syncPhraseContext: true
        )
        guard let applied else { return }
        lastSelectionConversion = SelectionConversion(original: selectedText, replacement: replacement)
        let transaction = await buildManualTransaction(
            original: selectedText,
            replacement: replacement,
            intent: .manualSelection,
            bundleId: bundleId
        )
        await commitReplacementTransaction(transaction, editResult: applied, verifiedContext: verified)
        if shouldSwitchLayout(after: applied, hostRuntimeProfile: hostProfile, manual: true) {
            switchInputSourceIfNeeded(to: targetLanguage, transactionId: transaction?.id)
        }
    }

    private func handleHotkeyPress() async {
        beginHoldingUserKeys()
        defer { endHoldingUserKeys() }
        let bundleId = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let focusedCapabilities = textContextService.resolveFocusedElementCapabilities()
        let hostProfile = currentHostRuntimeProfile(bundleId: bundleId, capabilities: focusedCapabilities?.capabilities)
        trace.log(
            .hotkeyPressed,
            fields: [
                "bundle_id": bundleId,
                "host_profile": hostProfile.rawValue,
                "capabilities": focusedCapabilities.map { Self.traceValue(of: $0.capabilities) },
                "typed_token": inputSession.typedToken,
                "last_committed": lastCommittedToken.map { $0.token + $0.separator }
            ]
        )

        // Selected text is what the user wants converted, even right after a correction
        // that could otherwise be cycled.
        if let selectionSnapshot = textContextService.snapshotSelectionForManualAction(),
           !selectionSnapshot.selectedText.isEmpty {
            await convertSelection(selectionSnapshot, bundleId: bundleId, hostProfile: hostProfile)
            return
        }

        if await engine.hasCyclingState(),
           let currentVisible = await engine.getCurrentCyclingText() {
            let trailingSeparator = await engine.cyclingTrailingSeparator()
            // Check the text first: a press that can't replace anything must not move
            // the cycle on, or the next press would skip the alternative it was for.
            let verified = await hotkeyVerification(token: currentVisible, separator: trailingSeparator)
            guard verified != nil || canUseManualReplayFallback(for: currentVisible + trailingSeparator, hostRuntimeProfile: hostProfile) else { return }
            guard let newText = await engine.cycleCorrection(bundleId: bundleId) else { return }

            let cyclingOriginal = await engine.getCyclingOriginalText()
            let intent: TextEditIntent = newText == cyclingOriginal ? .manualUndo : .manualCycle
            let applied = await performHotkeyReplacement(
                intent: intent,
                token: currentVisible,
                separator: trailingSeparator,
                replacement: newText,
                verified: verified,
                hostRuntimeProfile: hostProfile
            )
            if let applied {
                replaceLastPhraseBufferWord(
                    from: splitBufferContent(currentVisible).token,
                    to: splitBufferContent(newText).token
                )
                let manualTransaction = await buildManualTransaction(
                    original: currentVisible,
                    replacement: newText,
                    intent: intent,
                    bundleId: bundleId
                )
                await commitReplacementTransaction(manualTransaction, editResult: applied, verifiedContext: verified?.context)
                if shouldSwitchLayout(after: applied, hostRuntimeProfile: hostProfile, manual: true) {
                    switchInputSourceIfNeeded(to: await engine.currentCyclingTargetLanguage(), transactionId: manualTransaction?.id)
                }
            }
            return
        }

        if let result = await engine.applyPendingSuggestion(),
           let corrected = result.corrected {
            let trailingSeparator = await engine.cyclingTrailingSeparator()
            let original = await engine.getCyclingOriginalText() ?? corrected
            let verified = await hotkeyVerification(token: original, separator: trailingSeparator)
            guard verified != nil || canUseManualReplayFallback(for: original + trailingSeparator, hostRuntimeProfile: hostProfile) else { return }

            let applied = await performHotkeyReplacement(
                intent: .manualCycle,
                token: original,
                separator: trailingSeparator,
                replacement: corrected,
                verified: verified,
                hostRuntimeProfile: hostProfile
            )
            if let applied {
                replaceLastPhraseBufferWord(
                    from: splitBufferContent(original).token,
                    to: splitBufferContent(corrected).token
                )
                await commitReplacementTransaction(result.transaction, editResult: applied, verifiedContext: verified?.context)
                if shouldSwitchLayout(after: applied, hostRuntimeProfile: hostProfile, manual: true) {
                    switchInputSourceIfNeeded(to: result.targetLanguage, transactionId: result.transaction?.id)
                }
            }
            return
        }

        var outcome = await convertLastWordForHotkey(bundleId: bundleId, hostProfile: hostProfile)
        if outcome == .reseeded {
            // The word didn't match the field, which gave the session its word instead:
            // convert that one now, not on a second press.
            outcome = await convertLastWordForHotkey(bundleId: bundleId, hostProfile: hostProfile)
        }
        guard outcome == .notApplicable else { return }

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
                if shouldSwitchLayout(after: result, hostRuntimeProfile: hostProfile, manual: true) {
                    switchInputSourceIfNeeded(to: await engine.currentCyclingTargetLanguage(), transactionId: transaction?.id)
                }
            }
        }
    }

    private enum HotkeyWordOutcome {
        /// The word was handled (converted, or found not to be there).
        case done
        /// The word didn't match the field, and the session took the field's word.
        case reseeded
        /// There was no word to convert.
        case notApplicable
    }

    /// Converts the word being typed, or else the last committed one, for the hotkey.
    private func convertLastWordForHotkey(bundleId: String?, hostProfile: HostRuntimeProfile) async -> HotkeyWordOutcome {
        let sessionEpoch = inputSession.sessionEpoch
        if !inputSession.typedToken.isEmpty,
           var replacement = await engine.correctLastWord(inputSession.typedToken, bundleId: bundleId) {
            var original = inputSession.typedToken
            var verified = await verificationContext(
                forExpectedSuffix: original,
                preserveSessionOnUnavailable: true
            )
            // The start of the word may be missing from the typed buffer (it is dropped
            // after a pause, or when the app moves its focus while showing suggestions);
            // the field still has it. Convert the whole word, not just its end.
            if let context = verified,
               let wholeWord = wholeWordBeforeCaret(endingWith: original, in: context),
               let wholeReplacement = await engine.correctLastWord(wholeWord.verifiedText, bundleId: bundleId) {
                original = wholeWord.verifiedText
                replacement = wholeReplacement
                verified = wholeWord
            }
            guard verified != nil || canUseManualReplayFallback(for: original, hostRuntimeProfile: hostProfile) else {
                return reseededSince(sessionEpoch)
            }
            let applied = await performReplacement(
                intent: .manualCycle,
                expectedOriginal: original,
                replacement: replacement,
                verifiedContext: verified,
                allowClipboardFallback: false,
                allowEventReplayFallback: false,
                currentVisibleText: original,
                hostRuntimeProfile: hostProfile,
                proxy: nil
            )
            if let applied {
                let transaction = await buildManualTransaction(
                    original: original,
                    replacement: replacement,
                    intent: .manualCycle,
                    bundleId: bundleId
                )
                await commitReplacementTransaction(transaction, editResult: applied, verifiedContext: verified)
                if shouldSwitchLayout(after: applied, hostRuntimeProfile: hostProfile, manual: true) {
                    switchInputSourceIfNeeded(to: await engine.currentCyclingTargetLanguage(), transactionId: transaction?.id)
                }
            }
            return .done
        }

        if let last = lastCommittedToken,
           let replacement = await engine.correctLastWord(last.token, bundleId: bundleId) {
            let verified = await hotkeyVerification(token: last.token, separator: last.separator)
            guard verified != nil || canUseManualReplayFallback(for: last.token + last.separator, hostRuntimeProfile: hostProfile) else {
                return reseededSince(sessionEpoch)
            }
            let applied = await performHotkeyReplacement(
                intent: .manualCycle,
                token: last.token,
                separator: last.separator,
                replacement: replacement,
                verified: verified,
                hostRuntimeProfile: hostProfile
            )
            if let applied {
                replaceLastPhraseBufferWord(
                    from: splitBufferContent(last.token).token,
                    to: splitBufferContent(replacement).token
                )
                let transaction = await buildManualTransaction(
                    original: last.token,
                    replacement: replacement,
                    intent: .manualCycle,
                    bundleId: bundleId
                )
                await commitReplacementTransaction(transaction, editResult: applied, verifiedContext: verified?.context)
                if shouldSwitchLayout(after: applied, hostRuntimeProfile: hostProfile, manual: true) {
                    switchInputSourceIfNeeded(to: await engine.currentCyclingTargetLanguage(), transactionId: transaction?.id)
                }
            }
            return .done
        }

        return .notApplicable
    }

    /// Whether a failed verification since `sessionEpoch` gave the session the field's
    /// word to convert instead.
    private func reseededSince(_ sessionEpoch: UInt64) -> HotkeyWordOutcome {
        inputSession.sessionEpoch != sessionEpoch && !inputSession.typedToken.isEmpty ? .reseeded : .done
    }

    /// Verifies `token` + `separator` before the caret for a hotkey correction.
    ///
    /// As at a word boundary, the host may not show the separator yet (ChatGPT, Slack):
    /// then only the word is verified, and the separator is kept.
    private func hotkeyVerification(token: String, separator: String) async -> BoundaryVerification? {
        if !separator.isEmpty,
           !(skipEventPosting || skipPIDCheck),
           case .verified(let context) = textContextService.verifyCommittedBoundary(
               token: token,
               separator: separator,
               revision: inputSession.mutationSeq
           ) {
            inputSession.lastVerifiedSnapshot = context.snapshot
            inputSession.isDirty = false
            return BoundaryVerification(
                context: context,
                includesSeparator: context.verifiedText.utf16.count >= (token + separator).utf16.count,
                trailingText: ""
            )
        }
        guard let context = await verificationContext(
            forExpectedSuffix: token + separator,
            preserveSessionOnUnavailable: true
        ) else {
            return nil
        }
        return BoundaryVerification(context: context, includesSeparator: true, trailingText: "")
    }

    /// Replaces `token` + `separator`, checked by `hotkeyVerification`, with `replacement`
    /// followed by the same separator.
    private func performHotkeyReplacement(
        intent: TextEditIntent,
        token: String,
        separator: String,
        replacement: String,
        verified: BoundaryVerification?,
        hostRuntimeProfile: HostRuntimeProfile
    ) async -> TextEditResult? {
        let includesSeparator = verified?.includesSeparator ?? true
        let expectedOriginal = verified?.context.verifiedText ?? token + separator
        return await performReplacement(
            intent: intent,
            expectedOriginal: expectedOriginal,
            replacement: replacement + (includesSeparator ? separator : ""),
            verifiedContext: verified?.context,
            allowClipboardFallback: false,
            allowEventReplayFallback: false,
            currentVisibleText: expectedOriginal,
            hostRuntimeProfile: hostRuntimeProfile,
            proxy: nil,
            unverifiedSuffix: includesSeparator ? "" : separator
        )
    }

    /// The word before the caret, when `context` verified only its end (`token`).
    private func wholeWordBeforeCaret(endingWith token: String, in context: VerifiedEditContext) -> VerifiedEditContext? {
        let caret = NSMaxRange(context.verifiedRange)
        guard caret == context.snapshot.selectedRange.location,
              let range = Self.wholeWordRange(endingWith: token, in: context.snapshot.fullText, caret: caret) else {
            return nil
        }
        return VerifiedEditContext(
            snapshot: context.snapshot,
            verifiedRange: range,
            verifiedText: (context.snapshot.fullText as NSString).substring(with: range)
        )
    }

    /// The range of the word that ends at `caret` (a UTF-16 offset), if it is longer
    /// than `token` and ends with it.
    nonisolated package static func wholeWordRange(endingWith token: String, in fullText: String, caret: Int) -> NSRange? {
        let nsText = fullText as NSString
        guard caret >= 0, caret <= nsText.length else { return nil }
        let beforeCaret = FocusedTextContextService.comparable(nsText.substring(to: caret))
        let start = beforeCaret.lastIndex(where: { $0.isWhitespace || $0.isNewline })
            .map { beforeCaret.index(after: $0) } ?? beforeCaret.startIndex
        let word = beforeCaret[start...]
        guard word.count > token.count,
              word.hasSuffix(FocusedTextContextService.comparable(token)) else {
            return nil
        }
        let length = word.utf16.count
        return NSRange(location: caret - length, length: length)
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
        proxy: CGEventTapProxy?,
        unverifiedSuffix: String = "",
        typedTailTransform: (@Sendable (String) -> String)? = nil,
        syncPhraseContext: Bool = false
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
            currentTypedToken: currentVisibleText,
            unverifiedSuffix: unverifiedSuffix,
            typedTailTransform: typedTailTransform
        )

        let result = await applyRequest(request, proxy: proxy)
        guard let result, !result.needsResync else {
            runtimeState = .dirtyNeedsResync
            return nil
        }

        // Blind hosts (and terminals, whose AX text is the screen buffer) can't seed the
        // session; reading them back would only cost time or mislead.
        if hostRuntimeProfile.editingEnvironment == .accessibility,
           let snapshot = textContextService.snapshotFocusedText() {
            // A field still catching up with the retyped text would make it the start of
            // the next word; the word being typed is then what follows its last separator.
            let seed = FocusedTextContextService.seedSession(from: snapshot, typedTail: replacement)
                ?? InputSessionSeed(
                    typedToken: Self.trailingWord(of: replacement),
                    phraseContext: "",
                    sourceApp: snapshot.bundleId,
                    snapshotRevision: snapshot.revision
                )
            // The callers add the corrected word to the phrase themselves; taking the
            // field's phrase as well listed it twice ("Hello Hello").
            applySeed(seed, snapshot: snapshot, keepPhraseContext: !syncPhraseContext)
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
            // The corrected word, its separator and whatever was typed after it.
            correctionErase = (
                committed.id,
                committed.replacement.count + (lastCommittedToken?.separator.count ?? 0) + inputSession.typedToken.count
            )
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
            } else if !skipEventPosting,
                      result.commitKind == .verifiedCommit || result.commitKind == .blindCommit {
                CorrectionSoundPlayer.shared.playIfEnabled()
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

        // Wait for a host that is still catching up with the last keystrokes.
        var result = textContextService.verifyExpectedSuffix(expectedText, revision: inputSession.mutationSeq)
        var lagRetries = 0
        while case .mismatch(let snapshot?, _) = result,
              lagRetries < Self.laggingHostRetries,
              FocusedTextContextService.lagsBehind(snapshot, typedTail: expectedText) {
            try? await Task.sleep(nanoseconds: Self.laggingHostRetryDelay)
            lagRetries += 1
            result = textContextService.verifyExpectedSuffix(expectedText, revision: inputSession.mutationSeq)
        }

        switch result {
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
                    "expected_text": expectedText,
                    "word_before_caret": seed?.typedToken,
                    "selection": snapshot.map { NSStringFromRange($0.selectedRange) + "/" + String(($0.fullText as NSString).length) }
                ]
            )
            if let snapshot, FocusedTextContextService.lagsBehind(snapshot, typedTail: expectedText) {
                // Still behind: what was typed is known better than what the field shows.
                return nil
            }
            if let snapshot, let seed {
                applySeed(seed, snapshot: snapshot, bumpSessionEpoch: true)
            } else {
                resetSession(reason: "Verification Mismatch", clearPhraseContext: false)
            }
            lastCommittedToken = nil
            clearTransliterationHint()
            // Before anything converts the field's word: a reset arriving later would
            // drop the conversion's alternatives.
            await engine.resetCycling()
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
        // The field shows the start of what was typed, but not all of it yet.
        var fieldLagsBehind = false

        attempts: for attempt in 0..<(Self.boundaryVerificationAttempts + Self.laggingHostRetries) {
            if attempt >= Self.boundaryVerificationAttempts {
                // Past the usual window, wait only for a host visibly catching up (Slack,
                // in a long message, showed only the start of the word for over 100 ms).
                guard fieldLagsBehind else { break attempts }
                try? await Task.sleep(nanoseconds: Self.laggingHostRetryDelay)
            } else if attempt > 0 {
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
            case .verified(let context) where Self.continuesWordBefore(context):
                // The buffer held only the end of a word: it is dropped after a pause, or
                // when the app moves its focus. Correcting that end alone breaks the word
                // ("всякийс лучай" became "всякийc kexfq"), so leave it, and take the
                // field's word as the session's.
                trace.log(
                    .verificationResult,
                    fields: [
                        "mode": "boundary",
                        "result": "partial_word",
                        "attempt": String(attempt),
                        "token": token,
                        "verified_text": context.verifiedText
                    ]
                )
                latestSnapshot = context.snapshot
                latestSeed = textContextService.seedSession(from: context.snapshot)
                lastAttemptMismatched = true
                fieldLagsBehind = false
                break attempts
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
                fieldLagsBehind = false
            case .mismatch(let snapshot, let seed):
                trace.log(
                    .verificationResult,
                    fields: [
                        "mode": "boundary",
                        "result": "mismatch",
                        "attempt": String(attempt),
                        "token": token,
                        "separator": separator,
                        "word_before_caret": seed?.typedToken,
                        "selection": snapshot.map { NSStringFromRange($0.selectedRange) + "/" + String(($0.fullText as NSString).length) }
                    ]
                )
                latestSnapshot = snapshot
                latestSeed = seed
                lastAttemptMismatched = true
                fieldLagsBehind = snapshot.map {
                    FocusedTextContextService.lagsBehind($0, typedTail: committedText + inputSession.typedToken)
                } ?? false
            }
        }

        guard lastAttemptMismatched, generation == boundaryGeneration else { return nil }
        // Still behind: the session knows what was typed better than the field shows it.
        // Seeding from it made the previous word the start of the next one.
        guard !fieldLagsBehind else { return nil }

        if let latestSnapshot, let latestSeed {
            applySeed(latestSeed, snapshot: latestSnapshot, bumpSessionEpoch: true)
        } else {
            resetSession(reason: "Boundary Verification Mismatch", clearPhraseContext: false)
        }
        lastCommittedToken = nil
        clearTransliterationHint()
        await engine.resetCycling()
        return nil
    }

    /// Whether the verified text starts in the middle of a word: a letter or digit
    /// right before it in the field.
    nonisolated static func continuesWordBefore(_ context: VerifiedEditContext) -> Bool {
        continuesWordBefore(location: context.verifiedRange.location, in: context.snapshot.fullText)
    }

    nonisolated static func continuesWordBefore(location: Int, in fullText: String) -> Bool {
        let text = fullText as NSString
        guard location > 0, location <= text.length else { return false }
        let previous = text.rangeOfComposedCharacterSequence(at: location - 1)
        guard let character = text.substring(with: previous).first else { return false }
        return character.isLetter || character.isNumber
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

    /// Why a word may not be retyped blind where its text can't be read back, or nil if
    /// it may.
    private func automaticReplayFallbackRefusal(
        for expectedText: String,
        replacement: String,
        confidence: Double?,
        hostRuntimeProfile: HostRuntimeProfile
    ) -> String? {
        guard !expectedText.isEmpty else { return "empty" }
        guard hostRuntimeProfile.allowsAutomaticBlindReplay else { return "host_profile" }
        guard !inputSession.isDirty, activeSyntheticTransactions == 0 else { return "session_dirty" }
        guard timeProvider.now.timeIntervalSince(inputSession.lastMutationAt) <= settings.blindReplayMaxDelay else {
            return "too_late"
        }

        guard let word = Self.blindReplayWord(original: expectedText, replacement: replacement) else {
            return "not_a_word"
        }
        // A one-letter Russian word is only corrected on its own where the engine has
        // a reason ("Прочитай b" → "Прочитай и", "Привет. Z" → "Привет. Я"), under the
        // default length limit.
        let minimumLetters = Self.isOneLetterRussianWord(original: word, replacement: replacement)
            ? 1
            : max(1, settings.minAutoCorrectWordLength)
        guard word.count >= minimumLetters, word.count <= 18 else {
            return "word_length"
        }

        let threshold = CorrectionDecisionPolicy.blindAutoApplyThreshold(
            preset: settings.behaviorPreset,
            limits: settings.autoCorrectionLimits
        )
        guard let confidence, confidence >= threshold else {
            return "confidence"
        }

        return nil
    }

    nonisolated static func isOneLetterRussianWord(original: Substring, replacement: String) -> Bool {
        original.count == 1
            && original.allSatisfy(\.isASCII)
            && CorrectionEngine.singleLetterWords[.russian]?.contains(replacement.lowercased()) == true
    }

    /// The word a blind retype replaces, or nil if it isn't one. Its letters are those of
    /// the typed text, or of the replacement when keys that are punctuation on the typed
    /// layout are letters on the other ("Yf;fk" → "Нажал", "Cgfcb,j!" → "Спасибо!").
    nonisolated static func blindReplayWord(original: String, replacement: String) -> Substring? {
        let trimmed = original.trimmingCharacters(in: .whitespacesAndNewlines)
        if let word = CorrectionDecisionPolicy.letterCore(of: trimmed, typedInWrongLayout: true) {
            return word
        }
        let converted = replacement.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let word = CorrectionDecisionPolicy.letterCore(of: converted),
              converted.count == trimmed.count else {
            return nil
        }
        return word
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
        inputSession.charactersAfterPhrase = nil
        // What Backspace erases after the caret moved is unknown.
        correctionErase = nil
        inputSession.isDirty = true
        inputSession.lastVerifiedSnapshot = nil
        inputSession.lastMutationAt = timeProvider.now
        keyTimings.removeAll()
        lastKeyTime = nil
    }

    /// Re-reads the focused text once events have settled, unless the user has started
    /// typing in the meantime (then the locally tracked session is already correct).
    private func scheduleDeferredResync(lagRetry: Int = 0) {
        guard !skipEventPosting else { return }
        deferredResyncTask?.cancel()
        let expectedMutationSeq = inputSession.mutationSeq
        deferredResyncTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: Self.deferredResyncDelay)
            guard !Task.isCancelled, let self else { return }
            self.deferredResyncTask = nil
            self.performDeferredResync(expectedMutationSeq: expectedMutationSeq, lagRetry: lagRetry)
        }
    }

    private func performDeferredResync(expectedMutationSeq: UInt64, lagRetry: Int) {
        guard expectedMutationSeq == inputSession.mutationSeq,
              activeSyntheticTransactions == 0,
              boundaryTasksInFlight == 0,
              !HostRuntimeProfile.isTerminalBundleId(lastActiveApp),
              let snapshot = textContextService.snapshotFocusedText() else {
            return
        }
        // Right after a word typed here, the field must show it and what followed. Slack
        // can lag behind; seeding from it then made the previous word the start of the
        // next one ("can" + "use" was checked as "canuse"). Read it again a bit later.
        if let typedTail = locallyTypedTail() {
            guard let seed = FocusedTextContextService.seedSession(from: snapshot, typedTail: typedTail) else {
                if lagRetry < Self.deferredResyncLagRetries {
                    scheduleDeferredResync(lagRetry: lagRetry + 1)
                }
                return
            }
            applySeed(seed, snapshot: snapshot)
            return
        }
        // Seeding bumps the mutation sequence, so the next invalidating event takes the
        // full path again and drops the seeded state.
        applySeed(textContextService.seedSession(from: snapshot), snapshot: snapshot)
    }

    /// What the user has just typed before the caret, when the session knows it: the
    /// last committed word, its separator and the word being typed.
    private func locallyTypedTail() -> String? {
        guard !inputSession.isDirty, let last = lastCommittedToken else { return nil }
        return last.token + last.separator + inputSession.typedToken
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
        inputSession.charactersAfterPhrase = nil
        // What Backspace erases after the caret moved is unknown.
        correctionErase = nil
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
        keepPhraseContext: Bool = false,
        bumpSessionEpoch: Bool = false
    ) {
        if bumpSessionEpoch {
            inputSession.sessionEpoch &+= 1
        }
        inputSession.mutationSeq &+= 1
        boundaryGeneration &+= 1
        inputSession.typedToken = seed.typedToken
        if clearPhraseContext {
            inputSession.phraseContext = ""
        } else if !keepPhraseContext {
            inputSession.phraseContext = seed.phraseContext
        }
        if !keepPhraseContext {
            inputSession.charactersAfterPhrase = nil
        }
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

    /// The word `text` ends with: what follows its last whitespace.
    nonisolated static func trailingWord(of text: String) -> String {
        guard let lastSpace = text.lastIndex(where: { $0.isWhitespace || $0.isNewline }) else {
            return text
        }
        return String(text[text.index(after: lastSpace)...])
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
        // The word was just ended by its separator.
        inputSession.charactersAfterPhrase = 1

        if inputSession.phraseContext.count > 100 {
            inputSession.phraseContext = String(inputSession.phraseContext.suffix(100))
            if let firstSpace = inputSession.phraseContext.firstIndex(of: " ") {
                inputSession.phraseContext = String(inputSession.phraseContext[inputSession.phraseContext.index(after: firstSpace)...])
            }
        }
    }

    /// Follows a Backspace that erases text typed before the current word: once it
    /// reaches a word of the phrase, that word is no longer context ("Прочитай b" with the
    /// "b" erased and "и" typed instead is "Прочитай и"). Where the session doesn't know
    /// what lies before the caret (after a click or a paste), the phrase is left as is.
    private func erasePhraseContextCharacter() {
        guard let gap = inputSession.charactersAfterPhrase else { return }
        if gap > 0 {
            inputSession.charactersAfterPhrase = gap - 1
            return
        }
        var words = inputSession.phraseContext.split(separator: " ").map(String.init)
        guard let last = words.popLast() else {
            inputSession.charactersAfterPhrase = nil
            return
        }
        inputSession.phraseContext = words.joined(separator: " ")
        // Its other letters, and the space before it, are still in the field.
        inputSession.charactersAfterPhrase = last.count - 1 + (words.isEmpty ? 0 : 1)
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
        correctionErase = nil
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
