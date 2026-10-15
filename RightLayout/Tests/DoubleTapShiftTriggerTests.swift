import XCTest
import CoreGraphics
@testable import RightLayout

@MainActor
final class DoubleTapShiftTriggerTests: XCTestCase {
    private var engine: CorrectionEngine!
    private var settings: SettingsManager!
    private var eventMonitor: EventMonitor!
    private var mockTime: MockTimeProvider!
    private var originalMode: SettingsManager.ManualTriggerMode = .doubleTapOption
    private var originalSide: SettingsManager.ManualTriggerOptionSide = .left
    private var originalHotkeyEnabled = true

    override func setUp() async throws {
        settings = SettingsManager.shared
        settings.isEnabled = true
        originalMode = settings.manualTriggerMode
        originalSide = settings.manualTriggerOptionSide
        originalHotkeyEnabled = settings.hotkeyEnabled
        settings.hotkeyEnabled = true
        settings.manualTriggerMode = .doubleTapShift
        settings.manualTriggerOptionSide = .left

        engine = CorrectionEngine(settings: settings)
        mockTime = MockTimeProvider()
        eventMonitor = EventMonitor(engine: engine, timeProvider: mockTime, charEncoder: MockCharacterEncoder())
        eventMonitor.skipPIDCheck = true
        eventMonitor.skipSecureInputCheck = true
        eventMonitor.skipEventPosting = true
    }

    override func tearDown() async throws {
        settings.manualTriggerMode = originalMode
        settings.manualTriggerOptionSide = originalSide
        settings.hotkeyEnabled = originalHotkeyEnabled
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

    private func typeWrongLayoutWord() {
        // "ghbdtn" (intended "привет"), no trailing space.
        for code: CGKeyCode in [5, 4, 11, 2, 17, 45] {
            press(code)
        }
    }

    func testDoubleTapShiftCorrectsLastWord() async throws {
        typeWrongLayoutWord()

        tapLeftShift()
        tapLeftShift()
        try await Task.sleep(nanoseconds: 500_000_000)

        let replacement = eventMonitor.lastReplacement
        XCTAssertEqual(replacement?.insertedText, "привет")
    }

    func testShiftUsedForTypingDoesNotTrigger() async throws {
        typeWrongLayoutWord()

        tapLeftShift()
        // Shift + letter, as when typing a capital.
        let down = CGEvent(keyboardEventSource: nil, virtualKey: 56, keyDown: true)!
        down.flags = CGEventFlags(rawValue: CGEventFlags.maskShift.rawValue | 0x02)
        _ = eventMonitor.handleEvent(proxy: proxy, type: .flagsChanged, event: down)
        press(3)
        let up = CGEvent(keyboardEventSource: nil, virtualKey: 56, keyDown: false)!
        up.flags = CGEventFlags(rawValue: 0)
        _ = eventMonitor.handleEvent(proxy: proxy, type: .flagsChanged, event: up)
        try await Task.sleep(nanoseconds: 500_000_000)

        let replacement = eventMonitor.lastReplacement
        XCTAssertNil(replacement)
    }
}
