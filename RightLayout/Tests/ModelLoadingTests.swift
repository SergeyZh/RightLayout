import XCTest
@testable import RightLayout

final class ModelLoadingTests: XCTestCase {
    
    func testLoadRussianModel() throws {
        let model = try NgramLanguageModel.loadLanguage("ru")
        // Check some known trigrams from our sample corpus
        // "при" from "привет" should be present
        let score = model.lookup("п", "р", "и")
        XCTAssertGreaterThan(score, -10.0, "Should find 'при' in Russian model")
    }
    
    func testLoadEnglishModel() throws {
        let model = try NgramLanguageModel.loadLanguage("en")
        // "hel" from "hello" should be present
        let score = model.lookup("h", "e", "l")
        XCTAssertGreaterThan(score, -10.0, "Should find 'hel' in English model")
    }
    
    func testLoadHebrewModel() throws {
        let model = try NgramLanguageModel.loadLanguage("he")
        // "שלו" from "שלום" should be present
        let score = model.lookup("ש", "ל", "ו")
        XCTAssertGreaterThan(score, -10.0, "Should find 'שלו' in Hebrew model")
    }
    
    func testLoadNonExistentModel() {
        XCTAssertThrowsError(try NgramLanguageModel.loadLanguage("xx")) { error in
            guard let modelError = error as? ModelError else {
                XCTFail("Expected ModelError")
                return
            }
            if case .resourceNotFound(let lang) = modelError {
                XCTAssertEqual(lang, "xx")
            } else {
                XCTFail("Expected resourceNotFound error")
            }
        }
    }

    // The word-frequency lists used to be looked up in a "LanguageModels" subdirectory that
    // SwiftPM flattens away, so they silently never loaded.
    func testWordFrequencyListsLoad() throws {
        let ru = try XCTUnwrap(WordFrequencyModel.shared("ru"), "ru_unigrams.tsv should load")
        XCTAssertTrue(ru.contains("раскладка"))
        XCTAssertGreaterThan(ru.score("привет"), 0.0)

        let en = try XCTUnwrap(WordFrequencyModel.shared("en"), "en_unigrams.tsv should load")
        XCTAssertTrue(en.contains("hello"))

        let he = try XCTUnwrap(WordFrequencyModel.shared("he"), "he_unigrams.tsv should load")
        XCTAssertTrue(he.contains("שלום"))
    }

    func testMissingWordFrequencyListIsNil() {
        XCTAssertNil(WordFrequencyModel.shared("xx"))
    }
}
