import Foundation
import AppKit
import ApplicationServices

package enum FocusedTextSnapshotSource: String, Sendable {
    case accessibility
    case accessibilityPartial
    case synthetic
}

package struct FocusedElementCapabilities: @unchecked Sendable {
    package let element: AXUIElement
    package let bundleId: String?
    package let pid: pid_t
    package let capabilities: AppEditCapabilities
}

package struct FocusedTextSnapshot: @unchecked Sendable {
    package let element: AXUIElement
    package let bundleId: String?
    package let pid: pid_t
    package let fullText: String
    package let selectedRange: NSRange
    package let selectedText: String
    package let caretLocation: Int
    package let supportsAXSelectedTextWrite: Bool
    package let supportsAXValueWrite: Bool
    package let supportsAXRangeWrite: Bool
    package let capabilities: AppEditCapabilities
    package let source: FocusedTextSnapshotSource
    package let revision: UInt64
}

extension FocusedTextSnapshot {
    /// The same snapshot with the caret at `location`.
    package func withCaret(at location: Int) -> FocusedTextSnapshot {
        FocusedTextSnapshot(
            element: element,
            bundleId: bundleId,
            pid: pid,
            fullText: fullText,
            selectedRange: NSRange(location: location, length: 0),
            selectedText: "",
            caretLocation: location,
            supportsAXSelectedTextWrite: supportsAXSelectedTextWrite,
            supportsAXValueWrite: supportsAXValueWrite,
            supportsAXRangeWrite: supportsAXRangeWrite,
            capabilities: capabilities,
            source: source,
            revision: revision
        )
    }
}

package struct VerifiedEditContext: @unchecked Sendable {
    package let snapshot: FocusedTextSnapshot
    package let verifiedRange: NSRange
    package let verifiedText: String
}

package struct InputSessionSeed: Sendable {
    package let typedToken: String
    package let phraseContext: String
    package let sourceApp: String?
    package let snapshotRevision: UInt64
}

package enum SessionSyncResult: @unchecked Sendable {
    case verified(VerifiedEditContext)
    case mismatch(snapshot: FocusedTextSnapshot?, seed: InputSessionSeed?)
    case unavailable
}

@MainActor
package final class FocusedTextContextService {
    package static let shared = FocusedTextContextService()

    /// Upper bound for a single AX round trip. The default (~6s) lets a busy or hung
    /// target app freeze our main thread, and with it keyboard event delivery.
    private static let axMessagingTimeout: Float = 0.3

    /// Capabilities of a text element don't change while it stays focused, but probing
    /// them costs ~8 AX round trips. Cache them per focused element for a short time.
    private static let capabilitiesCacheLifetime: TimeInterval = 2.0

    private let systemWideElement = AXUIElementCreateSystemWide()
    private var revisionCounter: UInt64 = 0
    private var cachedFocusedCapabilities: FocusedElementCapabilities?
    private var cachedFocusedCapabilitiesAt: Date = .distantPast

    package init() {
        AXUIElementSetMessagingTimeout(systemWideElement, Self.axMessagingTimeout)
    }

    /// Drops cached element capabilities (focus or frontmost app changed).
    package func invalidateCachedCapabilities() {
        cachedFocusedCapabilities = nil
    }

    package func resolveFocusedElementCapabilities() -> FocusedElementCapabilities? {
        guard let element = focusedElement() else {
            cachedFocusedCapabilities = nil
            return nil
        }

        let now = Date()
        if let cached = cachedFocusedCapabilities,
           now.timeIntervalSince(cachedFocusedCapabilitiesAt) < Self.capabilitiesCacheLifetime,
           CFEqual(cached.element, element) {
            return cached
        }

        var pid: pid_t = 0
        AXUIElementGetPid(element, &pid)

        let bundleId = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
        let capabilities = buildCapabilities(on: element, pid: pid)

        let resolved = FocusedElementCapabilities(
            element: element,
            bundleId: bundleId,
            pid: pid,
            capabilities: capabilities
        )
        cachedFocusedCapabilities = resolved
        cachedFocusedCapabilitiesAt = now
        return resolved
    }

    package func snapshotFocusedText() -> FocusedTextSnapshot? {
        guard let focused = resolveFocusedElementCapabilities() else { return nil }
        guard focused.capabilities.supportsFullTextRead,
              let fullText = stringAttribute(kAXValueAttribute, on: focused.element),
              let selectedRange = rangeAttribute(kAXSelectedTextRangeAttribute, on: focused.element) else {
            return nil
        }

        revisionCounter &+= 1

        let selectedText = stringAttribute(kAXSelectedTextAttribute, on: focused.element)
            ?? substring(in: fullText, range: selectedRange)
            ?? ""

        return FocusedTextSnapshot(
            element: focused.element,
            bundleId: focused.bundleId,
            pid: focused.pid,
            fullText: fullText,
            selectedRange: selectedRange,
            selectedText: selectedText,
            caretLocation: selectedRange.location,
            supportsAXSelectedTextWrite: focused.capabilities.supportsSelectedTextWrite,
            supportsAXValueWrite: focused.capabilities.supportsValueWrite,
            supportsAXRangeWrite: focused.capabilities.supportsSelectedRangeWrite,
            capabilities: focused.capabilities,
            source: .accessibility,
            revision: revisionCounter
        )
    }

    package func snapshotSelectionForManualAction() -> FocusedTextSnapshot? {
        if let snapshot = snapshotFocusedText(),
           snapshot.selectedRange.length > 0 || !snapshot.selectedText.isEmpty {
            return snapshot
        }

        guard let focused = resolveFocusedElementCapabilities() else { return nil }
        guard focused.capabilities.capabilityClass != .blind,
              focused.capabilities.capabilityClass != .secure,
              let selectedRange = rangeAttribute(kAXSelectedTextRangeAttribute, on: focused.element),
              let selectedText = stringAttribute(kAXSelectedTextAttribute, on: focused.element),
              selectedRange.length > 0 || !selectedText.isEmpty else {
            return nil
        }

        revisionCounter &+= 1

        return FocusedTextSnapshot(
            element: focused.element,
            bundleId: focused.bundleId,
            pid: focused.pid,
            fullText: focused.capabilities.supportsFullTextRead ? (stringAttribute(kAXValueAttribute, on: focused.element) ?? selectedText) : selectedText,
            selectedRange: selectedRange,
            selectedText: selectedText,
            caretLocation: selectedRange.location + selectedRange.length,
            supportsAXSelectedTextWrite: focused.capabilities.supportsSelectedTextWrite,
            supportsAXValueWrite: focused.capabilities.supportsValueWrite,
            supportsAXRangeWrite: focused.capabilities.supportsSelectedRangeWrite,
            capabilities: focused.capabilities,
            source: .accessibilityPartial,
            revision: revisionCounter
        )
    }

    package func verifyTrailingToken(localToken: String, revision: UInt64) -> SessionSyncResult {
        verifyExpectedSuffix(localToken, revision: revision)
    }

    package func verifyCommittedBoundary(token: String, separator: String, revision: UInt64) -> SessionSyncResult {
        guard !token.isEmpty else { return .unavailable }
        guard let snapshot = snapshotFocusedText() else { return .unavailable }
        return Self.verifyCommittedBoundary(token: token, separator: separator, in: snapshot)
    }

    nonisolated package static func verifyCommittedBoundary(
        token: String,
        separator: String,
        in snapshot: FocusedTextSnapshot
    ) -> SessionSyncResult {
        verifyAllowingCaretLag(snapshot, typedTails: [token + separator, token]) { snapshot in
            guard snapshot.selectedRange.length == 0 else {
                return .mismatch(snapshot: snapshot, seed: sessionSeed(from: snapshot))
            }

            let beforeCaret = comparable(prefix(in: snapshot.fullText, utf16Length: snapshot.selectedRange.location))
            let committedText = comparable(token + separator)

            if beforeCaret.hasSuffix(committedText) {
                let location = beforeCaret.utf16.count - committedText.utf16.count
                let range = NSRange(location: location, length: committedText.utf16.count)
                return .verified(
                    VerifiedEditContext(
                        snapshot: snapshot,
                        verifiedRange: range,
                        verifiedText: committedText
                    )
                )
            }

            if beforeCaret.hasSuffix(comparable(token)) {
                let location = beforeCaret.utf16.count - token.utf16.count
                let range = NSRange(location: location, length: token.utf16.count)
                return .verified(
                    VerifiedEditContext(
                        snapshot: snapshot,
                        verifiedRange: range,
                        verifiedText: token
                    )
                )
            }

            return .mismatch(snapshot: snapshot, seed: sessionSeed(from: snapshot))
        }
    }

    /// Verifies a committed boundary (`token` + `separator`) followed by
    /// `trailingCharacterCount` characters the user has typed since.
    ///
    /// The trailing characters are not compared literally: while a layout switch is
    /// in flight they may show up in either layout. The verified text contains them
    /// exactly as they appear in the document.
    package func verifyCommittedBoundary(
        token: String,
        separator: String,
        trailingCharacterCount: Int,
        revision: UInt64
    ) -> SessionSyncResult {
        guard trailingCharacterCount > 0 else {
            return verifyCommittedBoundary(token: token, separator: separator, revision: revision)
        }
        guard !token.isEmpty else { return .unavailable }
        guard let snapshot = snapshotFocusedText() else { return .unavailable }
        return Self.verifyCommittedBoundary(
            token: token,
            separator: separator,
            trailingCharacterCount: trailingCharacterCount,
            in: snapshot
        )
    }

    nonisolated package static func verifyCommittedBoundary(
        token: String,
        separator: String,
        trailingCharacterCount: Int,
        in snapshot: FocusedTextSnapshot
    ) -> SessionSyncResult {
        guard trailingCharacterCount > 0 else {
            return verifyCommittedBoundary(token: token, separator: separator, in: snapshot)
        }
        let committedText = comparable(token + separator)

        // The trailing characters as the field shows them at its end, if the caret lags
        // behind them.
        var typedTails: [String] = []
        let fullText = comparable(snapshot.fullText)
        if fullText.count >= trailingCharacterCount {
            let tailStart = fullText.index(fullText.endIndex, offsetBy: -trailingCharacterCount)
            typedTails.append(committedText + fullText[tailStart...])
        }

        return verifyAllowingCaretLag(snapshot, typedTails: typedTails) { snapshot in
            guard snapshot.selectedRange.length == 0 else {
                return .mismatch(snapshot: snapshot, seed: sessionSeed(from: snapshot))
            }

            let beforeCaret = comparable(prefix(in: snapshot.fullText, utf16Length: snapshot.selectedRange.location))
            var trailingStart = beforeCaret.endIndex
            for _ in 0..<trailingCharacterCount {
                guard trailingStart > beforeCaret.startIndex else {
                    return .mismatch(snapshot: snapshot, seed: sessionSeed(from: snapshot))
                }
                trailingStart = beforeCaret.index(before: trailingStart)
            }

            let trailingText = beforeCaret[trailingStart...]
            guard beforeCaret[..<trailingStart].hasSuffix(committedText),
                  !trailingText.contains(where: { $0.isWhitespace || $0.isNewline }) else {
                return .mismatch(snapshot: snapshot, seed: sessionSeed(from: snapshot))
            }

            let verifiedText = committedText + String(trailingText)
            let location = beforeCaret.utf16.count - verifiedText.utf16.count
            let range = NSRange(location: location, length: verifiedText.utf16.count)
            return .verified(
                VerifiedEditContext(
                    snapshot: snapshot,
                    verifiedRange: range,
                    verifiedText: verifiedText
                )
            )
        }
    }

    package func verifyExpectedSuffix(_ expectedText: String, revision: UInt64) -> SessionSyncResult {
        guard !expectedText.isEmpty else { return .unavailable }
        guard let snapshot = snapshotFocusedText() else { return .unavailable }
        return Self.verifyExpectedSuffix(expectedText, in: snapshot)
    }

    nonisolated package static func verifyExpectedSuffix(
        _ expectedText: String,
        in snapshot: FocusedTextSnapshot
    ) -> SessionSyncResult {
        guard !expectedText.isEmpty else { return .unavailable }
        return verifyAllowingCaretLag(snapshot, typedTails: [expectedText]) { snapshot in
            guard snapshot.selectedRange.length == 0 else {
                return .mismatch(snapshot: snapshot, seed: sessionSeed(from: snapshot))
            }

            let beforeCaret = comparable(prefix(in: snapshot.fullText, utf16Length: snapshot.selectedRange.location))
            guard beforeCaret.hasSuffix(comparable(expectedText)) else {
                return .mismatch(snapshot: snapshot, seed: sessionSeed(from: snapshot))
            }

            let location = beforeCaret.utf16.count - expectedText.utf16.count
            let range = NSRange(location: location, length: expectedText.utf16.count)
            return .verified(
                VerifiedEditContext(
                    snapshot: snapshot,
                    verifiedRange: range,
                    verifiedText: expectedText
                )
            )
        }
    }

    package func seedSession(from snapshot: FocusedTextSnapshot) -> InputSessionSeed {
        Self.sessionSeed(from: snapshot)
    }

    nonisolated package static func sessionSeed(from snapshot: FocusedTextSnapshot) -> InputSessionSeed {
        let beforeCaret = prefix(in: snapshot.fullText, utf16Length: snapshot.selectedRange.location)
        let typedToken: String
        if snapshot.selectedRange.length == 0 {
            typedToken = trailingToken(in: beforeCaret)
        } else {
            typedToken = ""
        }

        let phraseContext = trailingPhraseContext(in: beforeCaret)
        return InputSessionSeed(
            typedToken: typedToken,
            phraseContext: phraseContext,
            sourceApp: snapshot.bundleId,
            snapshotRevision: snapshot.revision
        )
    }

    /// Seeds the session from `snapshot` when, as far as the session knows, the user has
    /// just typed `typedTail` before the caret. Returns nil while the field is still
    /// behind those keystrokes: seeding from it made the previous word the start of the
    /// next one in Slack ("can" + "use" was read as "canuse").
    nonisolated package static func seedSession(
        from snapshot: FocusedTextSnapshot,
        typedTail: String
    ) -> InputSessionSeed? {
        let current = laggingCaretLocation(
            fullText: snapshot.fullText,
            selection: snapshot.selectedRange,
            typedTail: typedTail
        ).map { snapshot.withCaret(at: $0) } ?? snapshot
        if lagsBehind(current, typedTail: typedTail) {
            return nil
        }
        return sessionSeed(from: current)
    }

    // MARK: Hosts lagging behind the keystrokes

    /// How far behind its text a host may report the caret right after typing.
    nonisolated package static let maxCaretLag = 3

    /// How many of the last typed characters a host may not show yet.
    nonisolated package static let maxTextLag = 4

    /// How much of what was just typed is compared with the end of the field to tell a
    /// lagging host. Only the end: further back the session's idea of the text can differ
    /// from the field's without the caret being wrong, e.g. after a paste Slack added a
    /// space to ("…/timeline" + "Pffghedmnt" was one word to the session).
    nonisolated package static let lagEvidenceLength = maxTextLag + 3

    nonisolated private static func recentTail(_ typedTail: String) -> String {
        String(typedTail.suffix(lagEvidenceLength))
    }

    /// Slack (Chromium) can report the caret a character or two behind the text it
    /// shows, for seconds in a long message ("Скуысуте|Ж"). When the field ends with the
    /// end of `typedTail`, text the user has just typed there, and the caret is inside
    /// it, the caret is really at the end of the text: returns that location.
    nonisolated package static func laggingCaretLocation(
        fullText: String,
        selection: NSRange,
        typedTail: String
    ) -> Int? {
        let typedTail = recentTail(typedTail)
        let length = (fullText as NSString).length
        let tailLength = typedTail.utf16.count
        guard selection.length == 0,
              tailLength > 0,
              selection.location < length,
              length - selection.location <= maxCaretLag,
              selection.location >= length - tailLength,
              comparable(fullText).hasSuffix(comparable(typedTail)) else {
            return nil
        }
        return length
    }

    /// Whether the text before the caret stops partway through `typedTail`, the text the
    /// user has just typed there: the host hasn't caught up with the last keystrokes yet
    /// ("…can" right after "can " was typed).
    nonisolated package static func lagsBehind(_ snapshot: FocusedTextSnapshot, typedTail: String) -> Bool {
        guard snapshot.selectedRange.length == 0 else { return false }
        let beforeCaret = comparable(prefix(in: snapshot.fullText, utf16Length: snapshot.selectedRange.location))
        let tail = Array(comparable(recentTail(typedTail)))
        guard tail.count > 1, !beforeCaret.hasSuffix(String(tail)) else { return false }
        // One shared letter is no evidence, unless the tail is a letter and a separator.
        let shortest = max(min(2, tail.count - 1), tail.count - maxTextLag)
        for length in stride(from: tail.count - 1, through: shortest, by: -1) {
            if beforeCaret.hasSuffix(String(tail[..<length])) {
                return true
            }
        }
        return false
    }

    /// Runs `check`; if it fails and the caret lags behind one of `typedTails` at the end
    /// of the text, runs it again with the caret at the end. A mismatch then comes with
    /// the field's word at the real caret: the one at the reported caret lacked its last
    /// letters, and converting it left them behind ("gj;fkeqcn" for "gj;fkeqcnf", retyped
    /// from the end, became "gпожалуйст").
    nonisolated private static func verifyAllowingCaretLag(
        _ snapshot: FocusedTextSnapshot,
        typedTails: [String],
        _ check: (FocusedTextSnapshot) -> SessionSyncResult
    ) -> SessionSyncResult {
        let result = check(snapshot)
        guard case .mismatch = result else { return result }
        var laggingMismatch: SessionSyncResult?
        for tail in typedTails {
            guard let caret = laggingCaretLocation(
                fullText: snapshot.fullText,
                selection: snapshot.selectedRange,
                typedTail: tail
            ) else { continue }
            let atCaret = check(snapshot.withCaret(at: caret))
            if case .verified = atCaret {
                return atCaret
            }
            laggingMismatch = laggingMismatch ?? atCaret
        }
        return laggingMismatch ?? result
    }

    private func focusedElement() -> AXUIElement? {
        var focused: AnyObject?
        let err = AXUIElementCopyAttributeValue(systemWideElement, kAXFocusedUIElementAttribute as CFString, &focused)
        guard err == .success else { return nil }
        return focused as! AXUIElement?
    }

    private func stringAttribute(_ name: String, on element: AXUIElement) -> String? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else {
            return nil
        }
        return value as? String
    }

    private func rangeAttribute(_ name: String, on element: AXUIElement) -> NSRange? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success,
              let axValue = value,
              CFGetTypeID(axValue) == AXValueGetTypeID() else {
            return nil
        }

        var range = CFRange()
        guard AXValueGetValue(axValue as! AXValue, .cfRange, &range) else { return nil }
        guard range.location >= 0, range.length >= 0 else { return nil }
        return NSRange(location: range.location, length: range.length)
    }

    private func isAttributeSettable(_ name: String, on element: AXUIElement) -> Bool {
        var settable = DarwinBoolean(false)
        guard AXUIElementIsAttributeSettable(element, name as CFString, &settable) == .success else {
            return false
        }
        return settable.boolValue
    }

    private func isAttributeReadable(_ name: String, on element: AXUIElement) -> Bool {
        var value: AnyObject?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success
    }

    private func buildCapabilities(on element: AXUIElement, pid: pid_t) -> AppEditCapabilities {
        let supportsSelectedTextWrite = isAttributeSettable(kAXSelectedTextAttribute, on: element)
        let supportsSelectedRangeWrite = isAttributeSettable(kAXSelectedTextRangeAttribute, on: element)
        let supportsValueWrite = isAttributeSettable(kAXValueAttribute, on: element)
        let supportsSelectionRead = isAttributeReadable(kAXSelectedTextAttribute, on: element)
        let supportsRangeRead = isAttributeReadable(kAXSelectedTextRangeAttribute, on: element)
        let supportsFullTextRead = isAttributeReadable(kAXValueAttribute, on: element)

        let role = stringAttribute(kAXRoleAttribute, on: element)?.lowercased()
        let subrole = stringAttribute(kAXSubroleAttribute, on: element)?.lowercased()
        let secureRole = role?.contains("secure") == true || subrole?.contains("secure") == true

        let capabilityClass: CapabilityClass
        if secureRole {
            capabilityClass = .secure
        } else if supportsFullTextRead && supportsRangeRead {
            capabilityClass = .axFull
        } else if supportsSelectionRead || supportsSelectedTextWrite || supportsSelectedRangeWrite || supportsValueWrite || supportsRangeRead {
            capabilityClass = .axPartial
        } else {
            capabilityClass = .blind
        }

        return AppEditCapabilities(
            supportsSelectedTextWrite: supportsSelectedTextWrite,
            supportsSelectedRangeWrite: supportsSelectedRangeWrite,
            supportsValueWrite: supportsValueWrite,
            supportsSelectionRead: supportsSelectionRead,
            supportsFullTextRead: supportsFullTextRead,
            isSecureOrReadBlind: capabilityClass == .secure || capabilityClass == .blind,
            capabilityClass: capabilityClass,
            elementFingerprint: elementFingerprint(element: element, pid: pid, role: role, subrole: subrole)
        )
    }

    private func elementFingerprint(element: AXUIElement, pid: pid_t, role: String?, subrole: String?) -> String {
        "\(pid):\(CFHash(element)):\(role ?? "unknown"):\(subrole ?? "unknown")"
    }

    /// Text as compared with what was typed. Web editors keep a trailing space as a
    /// no-break space; both are one UTF-16 unit, so ranges stay valid.
    nonisolated package static func comparable(_ text: String) -> String {
        text.replacingOccurrences(of: "\u{00A0}", with: " ")
    }

    nonisolated private static func prefix(in text: String, utf16Length: Int) -> String {
        let nsText = text as NSString
        guard utf16Length >= 0, utf16Length <= nsText.length else {
            return text
        }
        return nsText.substring(to: utf16Length)
    }

    private func substring(in text: String, range: NSRange) -> String? {
        let nsText = text as NSString
        guard NSMaxRange(range) <= nsText.length else { return nil }
        return nsText.substring(with: range)
    }

    nonisolated private static func trailingToken(in text: String) -> String {
        let scalars = Array(text)
        guard !scalars.isEmpty else { return "" }

        var start = scalars.endIndex
        while start > scalars.startIndex {
            let previous = scalars.index(before: start)
            let char = scalars[previous]
            if char.isWhitespace || char.isNewline {
                break
            }
            start = previous
        }
        return String(scalars[start..<scalars.endIndex])
    }

    nonisolated private static func trailingPhraseContext(in text: String) -> String {
        let suffix = String(text.suffix(100))
        let words = suffix.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).suffix(5)
        return words.joined(separator: " ")
    }
}
