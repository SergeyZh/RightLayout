import XCTest
@testable import RightLayout

final class WorkingLanguagesTests: XCTestCase {
    private var engine: CorrectionEngine!
    private var originalLanguages: Set<Language>?

    @MainActor
    override func setUp() async throws {
        let settings = SettingsManager.shared
        settings.isEnabled = true
        originalLanguages = settings.customEnabledLanguages
        engine = CorrectionEngine(settings: settings)
    }

    @MainActor
    override func tearDown() async throws {
        SettingsManager.shared.customEnabledLanguages = originalLanguages
        engine = nil
    }

    func testHypothesisFiltering() {
        let enRu: Set<Language> = [.english, .russian]
        XCTAssertTrue(LanguageHypothesis.ruFromEnLayout.isAllowed(in: enRu))
        XCTAssertTrue(LanguageHypothesis.enFromRuLayout.isAllowed(in: enRu))
        XCTAssertFalse(LanguageHypothesis.heFromRuLayout.isAllowed(in: enRu))
        XCTAssertFalse(LanguageHypothesis.heFromEnLayout.isAllowed(in: enRu))
        XCTAssertFalse(LanguageHypothesis.ruFromHeLayout.isAllowed(in: enRu))
        XCTAssertTrue(LanguageHypothesis.he.isAllowed(in: enRu), "Keeping text as typed is always allowed")
    }

    func testDisabledLanguageIsNeverATarget() async {
        await MainActor.run { SettingsManager.shared.customEnabledLanguages = [.english, .russian] }

        // "akuo" is "שלום" typed on an English layout.
        let result = await engine.correctText("akuo", phraseBuffer: "", expectedLayout: nil)

        XCTAssertNotEqual(result.targetLanguage, .hebrew)
        let hebrewLetters = result.corrected?.unicodeScalars.contains { (0x0590...0x05FF).contains($0.value) } ?? false
        XCTAssertFalse(hebrewLetters, "Got Hebrew output: \(result.corrected ?? "")")
    }

    func testRussianWordsAreKeptAsTyped() async {
        for word in ["раскладка", "перекодируется", "перекодировать"] {
            let result = await engine.correctText(word, phraseBuffer: "", expectedLayout: nil)
            XCTAssertNil(result.corrected, "\(word) was changed to \(result.corrected ?? "")")
        }
    }

    func testRussianWordsTypedOnEnglishLayoutBecomeRussian() async {
        // "раскладка" and "перекодируется" typed with the English layout active.
        let cases = ["hfcrkflrf": "раскладка", "gthtrjlbhetncz": "перекодируется"]
        for (typed, expected) in cases {
            let result = await engine.correctText(typed, phraseBuffer: "", expectedLayout: nil)
            XCTAssertEqual(result.corrected, expected, "\(typed) → \(result.corrected ?? "nil")")
        }
    }
}
