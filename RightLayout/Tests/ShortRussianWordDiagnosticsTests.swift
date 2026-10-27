import XCTest
@testable import RightLayout

/// Temporary: prints how the dictionaries judge capitalized short words.
final class ShortRussianWordDiagnosticsTests: XCTestCase {
    func testPrintValidators() {
        let system = SystemWordValidator()
        let hybrid = HybridWordValidator()
        var lines: [String] = []
        for (token, language) in [("Yj", Language.english), ("yj", .english), ("Lf", .english), ("lf", .english),
                                  ("Yt", .english), ("yt", .english), ("Но", .russian), ("но", .russian)] {
            lines.append("DIAG \(token) \(language) system=\(system.confidence(for: token, language: language)) hybrid=\(hybrid.confidence(for: token, language: language))")
        }
        XCTFail(lines.joined(separator: "\n"))
    }
}
