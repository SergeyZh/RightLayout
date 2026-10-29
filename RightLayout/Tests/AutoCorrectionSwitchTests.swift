import XCTest
import CoreGraphics
@testable import RightLayout

/// "Enable auto-correction" turned off, or an excluded app, used to stop nothing: words
/// were still corrected as they were typed. With auto-correction off the manual trigger
/// keeps working; excluded apps are never monitored, so it does nothing there.
@MainActor
final class AutoCorrectionSwitchTests: XCTestCase {
    private static let excludedApp = "com.example.excluded"
    private static let otherApp = "com.example.other"

    private var engine: CorrectionEngine!
    private var settings: SettingsManager!
    private var eventMonitor: EventMonitor!
    private var mockTime: MockTimeProvider!
    private var originalEnabled = true
    private var originalExcludedApps: Set<String> = []
    private var originalAutoSwitch = true
    private var originalHotkeyEnabled = true
    private var originalMode: SettingsManager.ManualTriggerMode = .doubleTapOption
    private var originalSide: SettingsManager.ManualTriggerOptionSide = .left

    override func setUp() async throws {
        settings = SettingsManager.shared
        originalEnabled = settings.isEnabled
        originalExcludedApps = settings.excludedApps
        originalAutoSwitch = settings.autoSwitchLayout
        originalHotkeyEnabled = settings.hotkeyEnabled
        originalMode = settings.manualTriggerMode
        originalSide = settings.manualTriggerOptionSide
        settings.isEnabled = true
        settings.excludedApps = [Self.excludedApp]
        // Keep the machine's input source untouched.
        settings.autoSwitchLayout = false
        settings.hotkeyEnabled = true
        settings.manualTriggerMode = .doubleTapShift
        settings.manualTriggerOptionSide = .left

        engine = CorrectionEngine(settings: settings)
        await engine.clearHistory()
        mockTime = MockTimeProvider()
        eventMonitor = EventMonitor(engine: engine, timeProvider: mockTime, charEncoder: MockCharacterEncoder())
        eventMonitor.skipPIDCheck = true
        eventMonitor.skipSecureInputCheck = true
        eventMonitor.skipEventPosting = true
        eventMonitor.activeAppForTesting = Self.otherApp
    }

    override func tearDown() async throws {
        settings.isEnabled = originalEnabled
        settings.excludedApps = originalExcludedApps
        settings.autoSwitchLayout = originalAutoSwitch
        settings.hotkeyEnabled = originalHotkeyEnabled
        settings.manualTriggerMode = originalMode
        settings.manualTriggerOptionSide = originalSide
        eventMonitor = nil
        engine = nil
    }

    private var proxy: CGEventTapProxy {
        unsafeBitCast(Int(0), to: CGEventTapProxy.self)
    }

    private func press(_ keyCode: CGKeyCode) {
        let event = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: true)!
        _ = eventMonitor.handleEvent(proxy: proxy, type: .keyDown, event: event)
        mockTime.advance(by: 0.03)
    }

    /// "ghbdtn" (intended "привет").
    private func typeWrongLayoutWord() {
        for code: CGKeyCode in [5, 4, 11, 2, 17, 45] {
            press(code)
        }
    }

    /// Left Shift down/up, with the device-specific bit real events carry.
    private func tapLeftShift() {
        let down = CGEvent(keyboardEventSource: nil, virtualKey: 56, keyDown: true)!
        down.flags = CGEventFlags(rawValue: CGEventFlags.maskShift.rawValue | 0x02)
        _ = eventMonitor.handleEvent(proxy: proxy, type: .flagsChanged, event: down)
        mockTime.advance(by: 0.04)

        let up = CGEvent(keyboardEventSource: nil, virtualKey: 56, keyDown: false)!
        up.flags = CGEventFlags(rawValue: 0)
        _ = eventMonitor.handleEvent(proxy: proxy, type: .flagsChanged, event: up)
        mockTime.advance(by: 0.04)
    }

    private func doubleTapTrigger() async throws {
        tapLeftShift()
        tapLeftShift()
        try await Task.sleep(nanoseconds: 500_000_000)
    }

    private var inserted: String? {
        eventMonitor.lastReplacement?.insertedText.trimmingCharacters(in: .whitespaces)
    }

    // MARK: Auto-correction switch

    /// The baseline the other tests rely on: the word is corrected in an app that isn't
    /// excluded while another app is.
    func testWordIsCorrectedWhenEnabledAndAppIsNotExcluded() async throws {
        typeWrongLayoutWord()
        press(49)
        try await Task.sleep(nanoseconds: 500_000_000)

        XCTAssertEqual(inserted, "привет")
    }

    func testWordIsNotCorrectedWhenAutoCorrectionIsOff() async throws {
        settings.isEnabled = false

        typeWrongLayoutWord()
        press(49)
        try await Task.sleep(nanoseconds: 500_000_000)

        XCTAssertNil(eventMonitor.lastReplacement)
    }

    func testEnterIsNotHeldWhenAutoCorrectionIsOff() async throws {
        settings.isEnabled = false

        typeWrongLayoutWord()
        let event = CGEvent(keyboardEventSource: nil, virtualKey: 36, keyDown: true)!
        XCTAssertNotNil(eventMonitor.handleEvent(proxy: proxy, type: .keyDown, event: event))
        try await Task.sleep(nanoseconds: 500_000_000)

        XCTAssertNil(eventMonitor.lastReplacement)
    }

    func testManualTriggerStillConvertsTheWordBeingTypedWhenAutoCorrectionIsOff() async throws {
        settings.isEnabled = false

        typeWrongLayoutWord()
        try await doubleTapTrigger()

        XCTAssertEqual(inserted, "привет")
    }

    func testManualTriggerStillConvertsTheLastWordWhenAutoCorrectionIsOff() async throws {
        settings.isEnabled = false

        typeWrongLayoutWord()
        press(49)
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertNil(eventMonitor.lastReplacement)

        try await doubleTapTrigger()

        XCTAssertEqual(inserted, "привет")
    }

    // MARK: Excluded apps

    func testWordIsNotCorrectedInExcludedApp() async throws {
        eventMonitor.activeAppForTesting = Self.excludedApp

        typeWrongLayoutWord()
        XCTAssertEqual(eventMonitor.typedTokenForTesting, "", "Typing in an excluded app must not be tracked")
        press(49)
        try await Task.sleep(nanoseconds: 500_000_000)

        XCTAssertNil(eventMonitor.lastReplacement)
    }

    func testManualTriggerDoesNothingInExcludedApp() async throws {
        eventMonitor.activeAppForTesting = Self.excludedApp

        typeWrongLayoutWord()
        try await doubleTapTrigger()

        XCTAssertNil(eventMonitor.lastReplacement)
    }

    /// An app added to the list while the user types in it: what was typed before is
    /// dropped, neither corrected on the space nor converted by the trigger.
    func testWordTypedBeforeTheAppWasExcludedIsDropped() async throws {
        typeWrongLayoutWord()
        XCTAssertEqual(eventMonitor.typedTokenForTesting, "ghbdtn")

        settings.excludedApps.insert(Self.otherApp)
        press(49)
        XCTAssertEqual(eventMonitor.typedTokenForTesting, "")
        XCTAssertEqual(eventMonitor.phraseContextForTesting, "")
        try await doubleTapTrigger()

        XCTAssertNil(eventMonitor.lastReplacement)
    }
}
