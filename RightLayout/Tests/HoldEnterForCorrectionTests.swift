import XCTest
import CoreGraphics
@testable import RightLayout

@MainActor
final class HoldEnterForCorrectionTests: XCTestCase {
    private var engine: CorrectionEngine!
    private var settings: SettingsManager!
    private var eventMonitor: EventMonitor!
    private var mockTime: MockTimeProvider!
    private var originalHoldEnter = true
    private var originalAutoSwitch = true

    override func setUp() async throws {
        settings = SettingsManager.shared
        settings.isEnabled = true
        originalHoldEnter = settings.holdEnterForCorrection
        originalAutoSwitch = settings.autoSwitchLayout
        settings.holdEnterForCorrection = true
        // Keep the machine's input source untouched.
        settings.autoSwitchLayout = false

        engine = CorrectionEngine(settings: settings)
        // Warm up the models so the first decision fits in the Enter hold window.
        _ = await engine.correctText("hello", phraseBuffer: "", expectedLayout: nil)
        await engine.clearHistory()
        mockTime = MockTimeProvider()
        let encoder = MockCharacterEncoder()
        encoder.mapping[14] = "e"
        encoder.mapping[37] = "l"
        encoder.mapping[31] = "o"
        eventMonitor = EventMonitor(engine: engine, timeProvider: mockTime, charEncoder: encoder)
        eventMonitor.skipPIDCheck = true
        eventMonitor.skipSecureInputCheck = true
        eventMonitor.skipEventPosting = true
    }

    override func tearDown() async throws {
        settings.holdEnterForCorrection = originalHoldEnter
        settings.autoSwitchLayout = originalAutoSwitch
        eventMonitor = nil
        engine = nil
    }

    /// Returns what the event tap does with the event: `true` if it lets it through.
    @discardableResult
    private func press(_ keyCode: CGKeyCode) -> Bool {
        let proxy = unsafeBitCast(Int(0), to: CGEventTapProxy.self)
        let event = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: true)!
        let result = eventMonitor.handleEvent(proxy: proxy, type: .keyDown, event: event)
        mockTime.advance(by: 0.03)
        return result != nil
    }

    private func type(_ codes: [CGKeyCode]) {
        for code in codes {
            press(code)
        }
    }

    func testEnterAfterWrongLayoutWordFixesWordAndIsSwallowed() async throws {
        type([5, 4, 11, 2, 17, 45]) // "ghbdtn"
        XCTAssertFalse(press(36), "Enter should be held while the word is checked")

        try await Task.sleep(nanoseconds: 600_000_000)

        XCTAssertEqual(eventMonitor.lastReplacement?.insertedText, "привет")
        XCTAssertEqual(eventMonitor.releasedEnterCount, 0, "Enter must not be sent after a correction")

        // The next Enter sends the (now corrected) message.
        XCTAssertTrue(press(36))
    }

    func testEnterAfterCorrectWordIsReleased() async throws {
        type([4, 14, 37, 37, 31]) // "hello" — already in the right layout
        press(36)

        try await Task.sleep(nanoseconds: 600_000_000)

        XCTAssertNil(eventMonitor.lastReplacement)
        XCTAssertEqual(eventMonitor.releasedEnterCount, 1)
    }

    func testTypingAfterHeldEnterReleasesItImmediately() async throws {
        type([5, 4, 11, 2, 17, 45]) // "ghbdtn"
        press(36)
        press(15) // user keeps typing before the decision

        XCTAssertEqual(eventMonitor.releasedEnterCount, 1)
        try await Task.sleep(nanoseconds: 600_000_000)
        XCTAssertNil(eventMonitor.lastReplacement, "No correction once the Enter has gone through")
    }
}
