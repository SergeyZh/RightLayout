import XCTest
import ApplicationServices
@testable import RightLayout

/// From a Telegram field report: every correction there was counted as failed although
/// the text had changed. The layout was switched back, so every next word came in the
/// wrong layout again, and a word after a corrected short one ("e" → "у", then "dfc")
/// was checked together with the typed "e" and left as typed.
final class TelegramReadBackTests: XCTestCase {

    private func snapshot(_ text: String, caret: Int? = nil, selectionLength: Int = 0) -> FocusedTextSnapshot {
        let location = caret ?? (text as NSString).length
        return FocusedTextSnapshot(
            element: AXUIElementCreateSystemWide(),
            bundleId: "ru.keepcoder.Telegram",
            pid: 0,
            fullText: text,
            selectedRange: NSRange(location: location, length: selectionLength),
            selectedText: "",
            caretLocation: location,
            supportsAXSelectedTextWrite: true,
            supportsAXValueWrite: true,
            supportsAXRangeWrite: true,
            capabilities: AppEditCapabilities(
                supportsSelectedTextWrite: true,
                supportsSelectedRangeWrite: true,
                supportsValueWrite: true,
                supportsSelectionRead: true,
                supportsFullTextRead: true,
                isSecureOrReadBlind: false,
                capabilityClass: .axFull,
                elementFingerprint: nil
            ),
            source: .accessibility,
            revision: 1
        )
    }

    func testFieldShowingTheCorrectionIsRecognized() {
        // Read again after "e " was reported as not replaced: the field shows "у ".
        let field = snapshot("Central, который у ")
        XCTAssertTrue(EventMonitor.textBeforeCaret(in: field, endsWith: "у "))
        XCTAssertFalse(EventMonitor.textBeforeCaret(in: field, endsWith: "e "))
    }

    func testFieldStillShowingTheTypedWordKeepsIt() {
        let field = snapshot("Central, который e ")
        XCTAssertTrue(EventMonitor.textBeforeCaret(in: field, endsWith: "e "))
        XCTAssertFalse(EventMonitor.textBeforeCaret(in: field, endsWith: "у "))
    }

    func testOnlyTheTextBeforeTheCaretCounts() {
        let text = "который у дальше"
        let caret = (text as NSString).range(of: "дальше").location
        XCTAssertTrue(EventMonitor.textBeforeCaret(in: snapshot(text, caret: caret), endsWith: "у "))
        XCTAssertFalse(EventMonitor.textBeforeCaret(in: snapshot(text), endsWith: "у "))
    }

    func testNoSnapshotOrASelectionTellsNothing() {
        XCTAssertFalse(EventMonitor.textBeforeCaret(in: nil, endsWith: "у "))
        XCTAssertFalse(EventMonitor.textBeforeCaret(in: snapshot("который у ", caret: 0, selectionLength: 3), endsWith: "у "))
        XCTAssertFalse(EventMonitor.textBeforeCaret(in: snapshot("который у "), endsWith: ""))
    }

    func testNoBreakSpaceCountsAsASpace() {
        XCTAssertTrue(EventMonitor.textBeforeCaret(in: snapshot("который у\u{00A0}"), endsWith: "у "))
        // The field is read back the same way after a write.
        XCTAssertTrue(SelectionReplacementService.showsRetypedText("у ", at: 8, in: "который у\u{00A0}"))
    }
}
