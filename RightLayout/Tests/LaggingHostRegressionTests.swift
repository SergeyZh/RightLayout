import XCTest
import CoreGraphics
import ApplicationServices
@testable import RightLayout

/// From a Slack field report: in a long message Slack showed the text before the caret
/// a keystroke or two late, and its caret behind its text for seconds. Words were glued
/// to the previous one ("canuse"), the hotkey needed two presses, and retyping from the
/// stale caret left stray letters ("СCrescent").
final class LaggingHostRegressionTests: XCTestCase {

    private func snapshot(_ text: String, caret: Int? = nil, selectionLength: Int = 0) -> FocusedTextSnapshot {
        let location = caret ?? (text as NSString).length
        return FocusedTextSnapshot(
            element: AXUIElementCreateSystemWide(),
            bundleId: "com.tinyspeck.slackmacgap",
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

    private func length(_ text: String) -> Int {
        (text as NSString).length
    }

    // MARK: A caret reported behind the text

    func testCaretLaggingInsideTheTypedTextIsAtTheEnd() {
        let text = "пропало его приложение для СкуысутеЖ"
        let end = length(text)
        XCTAssertEqual(
            FocusedTextContextService.laggingCaretLocation(
                fullText: text,
                selection: NSRange(location: end - 1, length: 0),
                typedTail: "СкуысутеЖ"
            ),
            end
        )
        XCTAssertEqual(
            FocusedTextContextService.laggingCaretLocation(
                fullText: text,
                selection: NSRange(location: end - 2, length: 0),
                typedTail: "СкуысутеЖ"
            ),
            end
        )
    }

    func testCaretIsTakenAsReportedOtherwise() {
        let text = "пропало его приложение для СкуысутеЖ"
        let end = length(text)
        // Already at the end.
        XCTAssertNil(FocusedTextContextService.laggingCaretLocation(
            fullText: text, selection: NSRange(location: end, length: 0), typedTail: "СкуысутеЖ"))
        // Too far back to be lag.
        XCTAssertNil(FocusedTextContextService.laggingCaretLocation(
            fullText: text, selection: NSRange(location: end - 5, length: 0), typedTail: "СкуысутеЖ"))
        // The field doesn't end with what was typed.
        XCTAssertNil(FocusedTextContextService.laggingCaretLocation(
            fullText: text + "x", selection: NSRange(location: end, length: 0), typedTail: "СкуысутеЖ"))
        // Before what was typed.
        XCTAssertNil(FocusedTextContextService.laggingCaretLocation(
            fullText: "ab", selection: NSRange(location: 0, length: 0), typedTail: "b"))
        // A selection.
        XCTAssertNil(FocusedTextContextService.laggingCaretLocation(
            fullText: text, selection: NSRange(location: end - 1, length: 1), typedTail: "СкуысутеЖ"))
    }

    func testSuffixIsVerifiedDespiteALaggingCaret() {
        // selection={78, 0}/79, word_before_caret="кгв
        let text = "чистку приложений в Space? \"кгву"
        let end = length(text)
        guard case .verified(let context) = FocusedTextContextService.verifyExpectedSuffix(
            "\"кгву",
            in: snapshot(text, caret: end - 1)
        ) else {
            return XCTFail("A caret one character behind the typed word must not fail the check")
        }
        XCTAssertEqual(context.verifiedText, "\"кгву")
        XCTAssertEqual(context.verifiedRange, NSRange(location: end - 5, length: 5))
        XCTAssertEqual(context.snapshot.selectedRange, NSRange(location: end, length: 0))
    }

    func testBoundaryIsVerifiedDespiteALaggingCaret() {
        // selection={199, 0}/201, word_before_caret="n
        let text = "Crescent 69592f37-3017-4cae-9541-c9755d01c17d \"nj "
        let end = length(text)
        guard case .verified(let context) = FocusedTextContextService.verifyCommittedBoundary(
            token: "\"nj",
            separator: " ",
            in: snapshot(text, caret: end - 2)
        ) else {
            return XCTFail("A caret two characters behind the separator must not fail the check")
        }
        XCTAssertEqual(context.verifiedText, "\"nj ")
        XCTAssertEqual(NSMaxRange(context.verifiedRange), end)
    }

    func testBoundaryWithTypedTailIsVerifiedDespiteALaggingCaret() {
        let text = "Hi ghbdtn rf"
        let end = length(text)
        guard case .verified(let context) = FocusedTextContextService.verifyCommittedBoundary(
            token: "ghbdtn",
            separator: " ",
            trailingCharacterCount: 2,
            in: snapshot(text, caret: end - 1)
        ) else {
            return XCTFail("The word, its separator and the letters typed after it are all there")
        }
        XCTAssertEqual(context.verifiedText, "ghbdtn rf")
        XCTAssertEqual(NSMaxRange(context.verifiedRange), end)
    }

    func testDifferentTextIsStillAMismatch() {
        guard case .mismatch = FocusedTextContextService.verifyExpectedSuffix("word", in: snapshot("hello world")) else {
            return XCTFail("Text that isn't there must not verify")
        }
        guard case .mismatch = FocusedTextContextService.verifyCommittedBoundary(
            token: "can",
            separator: " ",
            in: snapshot("You can use", caret: 9)
        ) else {
            return XCTFail("A caret before other text must not be moved")
        }
    }

    // MARK: Text before the caret behind the keystrokes

    func testFieldThatDoesNotShowTheSeparatorYetLagsBehind() {
        XCTAssertTrue(FocusedTextContextService.lagsBehind(snapshot("Hello Anya, You can"), typedTail: "can "))
        XCTAssertTrue(FocusedTextContextService.lagsBehind(snapshot("Crescent \"n"), typedTail: "\"nj "))
        XCTAssertFalse(FocusedTextContextService.lagsBehind(snapshot("Hello Anya, You can "), typedTail: "can "))
        XCTAssertFalse(FocusedTextContextService.lagsBehind(snapshot("something else"), typedTail: "can "))
    }

    func testSeedingWaitsForAFieldThatLagsBehind() {
        // The deferred resync read "can" right after "can " and took it as the start of
        // the next word: "canuse", "usemy", "myGoogle".
        XCTAssertNil(FocusedTextContextService.seedSession(from: snapshot("Hello Anya, You can"), typedTail: "can "))
    }

    func testSeedingFromALaggingCaretStartsANewWord() {
        let text = "Hello Anya, You can "
        let seed = FocusedTextContextService.seedSession(from: snapshot(text, caret: length(text) - 1), typedTail: "can ")
        XCTAssertEqual(seed?.typedToken, "")
        XCTAssertEqual(seed?.phraseContext, "Hello Anya, You can")
    }

    func testSeedingFromChangedTextTakesTheField() {
        // An app's autocomplete replaced what was typed: the field is right.
        let seed = FocusedTextContextService.seedSession(from: snapshot("@Andrey.Kopysov"), typedTail: "@kopy")
        XCTAssertEqual(seed?.typedToken, "@Andrey.Kopysov")
    }

    // MARK: Retyping from a lagging caret

    func testRetypingStartsFromTheRealCaret() {
        let text = "пропало его приложение для СкуысутеЖ"
        let end = length(text)
        let verifiedRange = NSRange(location: end - 9, length: 9)
        let selection = SelectionReplacementService.replaySelection(
            fullText: text,
            selection: NSRange(location: end - 1, length: 0),
            verifiedRange: verifiedRange,
            expectedOriginal: "СкуысутеЖ"
        )
        XCTAssertEqual(selection, NSRange(location: end, length: 0))

        let plan = SelectionReplacementService.verifiedReplayPlan(
            fullText: text,
            selection: selection,
            verifiedRange: verifiedRange,
            expectedOriginal: "СкуысутеЖ",
            unverifiedSuffix: ""
        )
        XCTAssertEqual(plan?.deleteCount, 9, "Deleting from the stale caret left the word's first letter")
        XCTAssertEqual(plan?.tail, "")
    }

    func testRetypingKeepsACaretThatIsNotLagging() {
        let text = "abc def"
        let selection = NSRange(location: 3, length: 0)
        XCTAssertEqual(
            SelectionReplacementService.replaySelection(
                fullText: text,
                selection: selection,
                verifiedRange: NSRange(location: 0, length: 3),
                expectedOriginal: "abc"
            ),
            selection
        )
    }

    func testRetypedTextIsFoundWhereItStarted() {
        // "Ghbdtn? " was retyped as "Привет, " and the user had already typed "Са".
        let text = "Привет, Са"
        XCTAssertTrue(SelectionReplacementService.showsRetypedText("Привет, ", at: 0, in: text))
        XCTAssertFalse(SelectionReplacementService.showsRetypedText("Привет, ", at: 1, in: text))
        XCTAssertFalse(SelectionReplacementService.showsRetypedText("Привет, Саша", at: 0, in: text))
        XCTAssertFalse(SelectionReplacementService.showsRetypedText("", at: 0, in: text))
    }

    func testTrailingWordOfAReplacement() {
        XCTAssertEqual(EventMonitor.trailingWord(of: "привет "), "")
        XCTAssertEqual(EventMonitor.trailingWord(of: "привет ка"), "ка")
        XCTAssertEqual(EventMonitor.trailingWord(of: "Саша!"), "Саша!")
    }
}

/// The event monitor keeps the user's keystrokes in order around a correction, and the
/// word being typed whole across a pause.
final class LaggingHostEventMonitorTests: XCTestCase {
    private var engine: CorrectionEngine!
    private var settings: SettingsManager!
    private var eventMonitor: EventMonitor!
    private var mockTime: MockTimeProvider!
    private var encoder: MockCharacterEncoder!
    private var originalAutoSwitchLayout = false

    @MainActor
    override func setUp() async throws {
        settings = SettingsManager.shared
        settings.isEnabled = true
        originalAutoSwitchLayout = settings.autoSwitchLayout
        settings.autoSwitchLayout = false

        engine = CorrectionEngine(settings: settings)
        await engine.clearHistory()
        mockTime = MockTimeProvider()
        encoder = MockCharacterEncoder()
        eventMonitor = EventMonitor(engine: engine, timeProvider: mockTime, charEncoder: encoder)
        eventMonitor.skipPIDCheck = true
        eventMonitor.skipSecureInputCheck = true
        eventMonitor.skipEventPosting = true
    }

    @MainActor
    override func tearDown() async throws {
        settings.autoSwitchLayout = originalAutoSwitchLayout
        eventMonitor = nil
        engine = nil
    }

    @MainActor
    @discardableResult
    private func press(_ keyCode: CGKeyCode) -> Bool {
        let proxy = unsafeBitCast(Int(0), to: CGEventTapProxy.self)
        let event = CGEvent(keyboardEventSource: CGEventSource(stateID: .privateState), virtualKey: keyCode, keyDown: true)!
        let passed = eventMonitor.handleEvent(proxy: proxy, type: .keyDown, event: event) != nil
        mockTime.advance(by: 0.03)
        return passed
    }

    @MainActor
    func testKeysTypedDuringACorrectionWaitForItAndKeepTheirOrder() {
        press(5) // g
        eventMonitor.beginHoldingUserKeys()
        XCTAssertFalse(press(15), "A key typed while a word is retyped must not reach the app yet")
        XCTAssertFalse(press(3))
        XCTAssertEqual(eventMonitor.typedTokenForTesting, "g")

        eventMonitor.endHoldingUserKeys()
        XCTAssertEqual(eventMonitor.typedTokenForTesting, "grf")
    }

    @MainActor
    func testNestedHoldsReleaseOnceAllAreDone() {
        eventMonitor.beginHoldingUserKeys()
        eventMonitor.beginHoldingUserKeys()
        press(15)
        eventMonitor.endHoldingUserKeys()
        XCTAssertEqual(eventMonitor.typedTokenForTesting, "")
        eventMonitor.endHoldingUserKeys()
        XCTAssertEqual(eventMonitor.typedTokenForTesting, "r")
    }

    @MainActor
    func testKeysAreNotHeldForever() {
        eventMonitor.beginHoldingUserKeys()
        XCTAssertFalse(press(15))
        mockTime.advance(by: 1.5)
        XCTAssertTrue(press(3), "After a second keys go through again")
        XCTAssertEqual(eventMonitor.typedTokenForTesting, "rf", "The held key comes first")
        eventMonitor.endHoldingUserKeys()
        XCTAssertEqual(eventMonitor.typedTokenForTesting, "rf")
    }

    @MainActor
    func testPauseInsideAWordKeepsIt() {
        for code: CGKeyCode in [5, 4, 11] { press(code) } // "ghb"
        mockTime.advance(by: 2.5)
        for code: CGKeyCode in [2, 17, 45] { press(code) } // "dtn"
        XCTAssertEqual(eventMonitor.typedTokenForTesting, "ghbdtn")
    }

    /// "Прочитай b" with the "b" erased and "и" typed instead stayed "Прочитай b и".
    @MainActor
    func testErasedWordLeavesThePhrase() async throws {
        encoder.mapping[14] = "e"
        encoder.mapping[31] = "o"
        for code: CGKeyCode in [17, 4, 14, 49] { press(code) } // "the "
        try await Task.sleep(nanoseconds: 300_000_000)
        for code: CGKeyCode in [2, 31, 5, 49] { press(code) } // "dog "
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(eventMonitor.phraseContextForTesting, "the dog")

        press(51) // the space
        XCTAssertEqual(eventMonitor.phraseContextForTesting, "the dog")
        press(51) // "g"
        XCTAssertEqual(eventMonitor.phraseContextForTesting, "the")
        for _ in 0..<3 { press(51) } // "o", "d" and the space
        XCTAssertEqual(eventMonitor.phraseContextForTesting, "the")
        press(51) // "e"
        XCTAssertEqual(eventMonitor.phraseContextForTesting, "")
    }

    @MainActor
    func testBackspaceAfterTheCaretMovedLeavesThePhrase() async throws {
        encoder.mapping[14] = "e"
        encoder.mapping[31] = "o"
        for code: CGKeyCode in [17, 4, 14, 49] { press(code) } // "the "
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(eventMonitor.phraseContextForTesting, "the")

        press(123) // Left arrow: what Backspace erases is no longer known
        for _ in 0..<3 { press(51) }
        XCTAssertEqual(eventMonitor.phraseContextForTesting, "the")
    }

    @MainActor
    func testCorrectedWordIsInThePhraseOnce() async throws {
        // "ghbdtn " (intended "привет ")
        for code: CGKeyCode in [5, 4, 11, 2, 17, 45, 49] { press(code) }
        try await Task.sleep(nanoseconds: 500_000_000)

        guard eventMonitor.lastReplacement != nil else {
            return XCTFail("Expected \"ghbdtn\" to be corrected")
        }
        let words = eventMonitor.phraseContextForTesting.split(separator: " ")
        XCTAssertEqual(words.filter { $0 == "привет" }.count, 1, "phrase: \(eventMonitor.phraseContextForTesting)")
    }
}
