import XCTest
@testable import RightLayout

/// Converting a selection, re-selecting the result and converting again must give back
/// the original text, not a word-by-word guess.
final class SelectionConversionTests: XCTestCase {
    private let conversion = SelectionConversion(
        original: "инференс и обслуживать ",
        replacement: "byathtyc b j,cke;bdfnm "
    )

    func testReselectedResultTogglesBack() {
        XCTAssertEqual(conversion.reverting("byathtyc b j,cke;bdfnm "), "инференс и обслуживать ")
    }

    func testReselectedWithoutTrailingSpaceKeepsSelectionWhitespace() {
        XCTAssertEqual(conversion.reverting("byathtyc b j,cke;bdfnm"), "инференс и обслуживать")
        XCTAssertEqual(conversion.reverting(" byathtyc b j,cke;bdfnm\n"), " инференс и обслуживать\n")
    }

    func testOtherSelectionIsNotReverted() {
        XCTAssertNil(conversion.reverting("byathtyc b"))
        XCTAssertNil(conversion.reverting("   "))
    }

    func testDominantLanguage() {
        XCTAssertEqual(SelectionConversion.dominantLanguage(of: "инференс и обслуживать"), .russian)
        XCTAssertEqual(SelectionConversion.dominantLanguage(of: "byathtyc b j,cke;bdfnm"), .english)
        XCTAssertNil(SelectionConversion.dominantLanguage(of: "123 ,."))
    }
}
