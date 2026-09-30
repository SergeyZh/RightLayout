import XCTest
import CoreGraphics
@testable import RightLayout

/// The user doesn't wait for the correction of a word before typing the next one.
/// Characters typed while the boundary is being processed must not cancel it.
final class ContinuedTypingBoundaryTests: XCTestCase {
    private var engine: CorrectionEngine!
    private var settings: SettingsManager!
    private var eventMonitor: EventMonitor!
    private var mockTime: MockTimeProvider!
    private var originalAutoSwitchLayout = false

    @MainActor
    override func setUp() async throws {
        settings = SettingsManager.shared
        settings.isEnabled = true
        originalAutoSwitchLayout = settings.autoSwitchLayout
        // Keep the machine's input source untouched; the tail is then carried over as typed.
        settings.autoSwitchLayout = false

        engine = CorrectionEngine(settings: settings)
        await engine.clearHistory()
        mockTime = MockTimeProvider()
        eventMonitor = EventMonitor(engine: engine, timeProvider: mockTime, charEncoder: MockCharacterEncoder())
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
    private func press(_ keyCode: CGKeyCode) {
        let proxy = unsafeBitCast(Int(0), to: CGEventTapProxy.self)
        let event = CGEvent(keyboardEventSource: CGEventSource(stateID: .privateState), virtualKey: keyCode, keyDown: true)!
        _ = eventMonitor.handleEvent(proxy: proxy, type: .keyDown, event: event)
        mockTime.advance(by: 0.03)
    }

    @MainActor
    private func typeWrongLayoutWordAndSpace() {
        // "ghbdtn " (intended "привет ")
        for code: CGKeyCode in [5, 4, 11, 2, 17, 45, 49] {
            press(code)
        }
    }

    @MainActor
    func testCorrectionSurvivesTypingStartedBeforeBoundaryIsProcessed() async throws {
        typeWrongLayoutWordAndSpace()
        // Next word starts before the boundary task had a chance to run.
        press(15) // r
        press(3)  // f

        try await Task.sleep(nanoseconds: 500_000_000)

        guard let replacement = eventMonitor.lastReplacement else {
            XCTFail("Correction was dropped because typing continued")
            return
        }
        XCTAssertEqual(replacement.deletedCount, "ghbdtn rf".count)
        XCTAssertEqual(replacement.insertedText, "привет rf")
    }

    @MainActor
    func testCorrectionIsDroppedWhenCaretMovesAway() async throws {
        typeWrongLayoutWordAndSpace()
        press(123) // Left arrow: text around the caret is no longer what we tracked.

        try await Task.sleep(nanoseconds: 500_000_000)

        XCTAssertNil(eventMonitor.lastReplacement)
    }
}
