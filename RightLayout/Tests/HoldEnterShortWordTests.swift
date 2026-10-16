import XCTest
import CoreGraphics
@testable import RightLayout

/// Short wrong-layout words followed by Enter must be fixed before the Enter goes out,
/// just like they are when followed by a space.
@MainActor
final class HoldEnterShortWordTests: XCTestCase {
    private var engine: CorrectionEngine!
    private var settings: SettingsManager!
    private var eventMonitor: EventMonitor!
    private var mockTime: MockTimeProvider!
    private var originalHoldEnter = true
    private var originalAutoSwitch = true
    private var originalLanguages: Set<Language>?

    override func setUp() async throws {
        settings = SettingsManager.shared
        settings.isEnabled = true
        originalHoldEnter = settings.holdEnterForCorrection
        originalAutoSwitch = settings.autoSwitchLayout
        originalLanguages = settings.customEnabledLanguages
        settings.holdEnterForCorrection = true
        settings.autoSwitchLayout = false
        settings.customEnabledLanguages = [.english, .russian]

        engine = CorrectionEngine(settings: settings)
        _ = await engine.correctText("hello", phraseBuffer: "", expectedLayout: nil)
        await engine.clearHistory()
        mockTime = MockTimeProvider()
        let encoder = MockCharacterEncoder()
        // Arbitrary key codes standing for the characters typed.
        encoder.mapping = [
            37: "L", 3: "f", 44: "/",
            5: "п", 35: "з", 17: "е",
            49: " "
        ]
        eventMonitor = EventMonitor(engine: engine, timeProvider: mockTime, charEncoder: encoder)
        eventMonitor.skipPIDCheck = true
        eventMonitor.skipSecureInputCheck = true
        eventMonitor.skipEventPosting = true
    }

    override func tearDown() async throws {
        settings.holdEnterForCorrection = originalHoldEnter
        settings.autoSwitchLayout = originalAutoSwitch
        settings.customEnabledLanguages = originalLanguages
        eventMonitor = nil
        engine = nil
    }

    @discardableResult
    private func press(_ keyCode: CGKeyCode) -> Bool {
        let proxy = unsafeBitCast(Int(0), to: CGEventTapProxy.self)
        let event = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: true)!
        let result = eventMonitor.handleEvent(proxy: proxy, type: .keyDown, event: event)
        mockTime.advance(by: 0.03)
        return result != nil
    }

    private func check(_ codes: [CGKeyCode], word: String, expected: String, terminator: CGKeyCode) async throws {
        let planned = await engine.planCorrection(word, editingEnvironment: .accessibility)
        await engine.clearHistory()
        await engine.resetCycling()
        for code in codes { press(code) }
        press(terminator)
        try await Task.sleep(nanoseconds: 700_000_000)
        let inserted = eventMonitor.lastReplacement?.insertedText
        XCTAssertEqual(
            inserted.map { $0.trimmingCharacters(in: .whitespaces) },
            expected,
            "\(word) + key \(terminator): inserted \(String(describing: inserted)), released enters \(eventMonitor.releasedEnterCount), plan \(planned.plan), conf \(String(describing: planned.result.confidence)), kind \(String(describing: planned.result.evidence?.tokenKind))"
        )
    }

    func testYesWithPeriodAndEnter() async throws {
        try await check([37, 3, 44], word: "Lf/", expected: "Да.", terminator: 36)
        XCTAssertEqual(eventMonitor.releasedEnterCount, 0)
    }

    func testYesWithPeriodAndSpace() async throws {
        try await check([37, 3, 44], word: "Lf/", expected: "Да.", terminator: 49)
    }

    func testGptAndEnter() async throws {
        try await check([5, 35, 17], word: "пзе", expected: "gpt", terminator: 36)
        XCTAssertEqual(eventMonitor.releasedEnterCount, 0)
    }

    func testGptAndSpace() async throws {
        try await check([5, 35, 17], word: "пзе", expected: "gpt", terminator: 49)
    }

    /// With the conservative style a short word only gets a suggestion. On a held Enter
    /// there is no next word to confirm it, so the suggestion is applied before sending.
    func testConservativeShortWordSuggestionIsAppliedOnEnter() async throws {
        let originalPreset = settings.behaviorPreset
        settings.behaviorPreset = .conservative
        defer { settings.behaviorPreset = originalPreset }

        let planned = await engine.planCorrection("Lf/", editingEnvironment: .accessibility)
        guard case .hint = planned.plan else {
            return XCTFail("expected a suggestion for Lf/ in the conservative style, got \(planned.plan)")
        }
        await engine.resetCycling()
        try await check([37, 3, 44], word: "Lf/", expected: "Да.", terminator: 36)
        XCTAssertEqual(eventMonitor.releasedEnterCount, 0)
    }
}
