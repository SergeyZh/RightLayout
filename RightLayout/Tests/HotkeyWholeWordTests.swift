import XCTest
@testable import RightLayout

/// The hotkey converts the whole word before the caret even when the typed buffer
/// only holds its end ("фьфящт" became "фьфяon").
final class HotkeyWholeWordTests: XCTestCase {
    func testWordWhoseStartWasDroppedFromTheBuffer() {
        let text = "Hello фьфящт"
        let range = EventMonitor.wholeWordRange(endingWith: "щт", in: text, caret: (text as NSString).length)
        XCTAssertEqual(range, NSRange(location: 6, length: 6))
    }

    func testWordAfterANonBreakingSpace() {
        let text = "Hello\u{00A0}фьфящт"
        let range = EventMonitor.wholeWordRange(endingWith: "щт", in: text, caret: (text as NSString).length)
        XCTAssertEqual(range, NSRange(location: 6, length: 6))
    }

    func testWholeWordInTheBufferNeedsNothingMore() {
        let text = "Hello фьфящт"
        XCTAssertNil(EventMonitor.wholeWordRange(endingWith: "фьфящт", in: text, caret: (text as NSString).length))
    }

    func testOtherTextBeforeTheCaret() {
        let text = "Hello фьфящт"
        XCTAssertNil(EventMonitor.wholeWordRange(endingWith: "xy", in: text, caret: (text as NSString).length))
        XCTAssertNil(EventMonitor.wholeWordRange(endingWith: "щт", in: text, caret: 9))
        XCTAssertNil(EventMonitor.wholeWordRange(endingWith: "щт", in: text, caret: 40))
    }

    func testCaretInsideTheText() {
        let text = "фьфящт and more"
        XCTAssertEqual(EventMonitor.wholeWordRange(endingWith: "щт", in: text, caret: 6), NSRange(location: 0, length: 6))
    }
}
