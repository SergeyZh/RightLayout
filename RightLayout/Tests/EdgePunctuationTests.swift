import XCTest
@testable import RightLayout

/// Words with sentence punctuation stuck to them ("Вщту!" → "Done!") are corrected
/// like the bare word, including in apps whose text can't be read.
final class EdgePunctuationTests: XCTestCase {
    private var engine: CorrectionEngine!
    private var originalLanguages: Set<Language>?

    @MainActor
    override func setUp() async throws {
        let settings = SettingsManager.shared
        settings.isEnabled = true
        originalLanguages = settings.customEnabledLanguages
        settings.customEnabledLanguages = [.english, .russian]
        engine = CorrectionEngine(settings: settings)
    }

    @MainActor
    override func tearDown() async throws {
        SettingsManager.shared.customEnabledLanguages = originalLanguages
        engine = nil
    }

    func testLetterCore() {
        XCTAssertEqual(CorrectionDecisionPolicy.letterCore(of: "Вщту!").map(String.init), "Вщту")
        XCTAssertEqual(CorrectionDecisionPolicy.letterCore(of: "(ghbdtn)").map(String.init), "ghbdtn")
        XCTAssertEqual(CorrectionDecisionPolicy.letterCore(of: "ghbdtn").map(String.init), "ghbdtn")
        XCTAssertNil(CorrectionDecisionPolicy.letterCore(of: "k.,k."))
        XCTAssertNil(CorrectionDecisionPolicy.letterCore(of: "rjt-xnj"))
        XCTAssertNil(CorrectionDecisionPolicy.letterCore(of: "?!"))
    }

    func testEdgePunctuationThatStaysPunctuation() {
        XCTAssertTrue(CorrectionDecisionPolicy.isWordWithEdgePunctuation(original: "Вщту!", converted: "Done!"))
        XCTAssertTrue(CorrectionDecisionPolicy.isWordWithEdgePunctuation(original: "ghbdtn?", converted: "привет,"))
        XCTAssertTrue(CorrectionDecisionPolicy.isWordWithEdgePunctuation(original: "(ghbdtn)", converted: "(привет)"))
    }

    func testPunctuationThatIsALetterIsNotEdgePunctuation() {
        // The period is the "ю" key on the Russian layout.
        XCTAssertFalse(CorrectionDecisionPolicy.isWordWithEdgePunctuation(original: "ghbdtn.", converted: "приветю"))
        XCTAssertFalse(CorrectionDecisionPolicy.isWordWithEdgePunctuation(original: "k.,k.", converted: "люблю"))
        XCTAssertFalse(CorrectionDecisionPolicy.isWordWithEdgePunctuation(original: "ghbdtn", converted: "привет"))
    }

    func testWordWithExclamationIsAutoCorrected() async {
        for environment in [EditingEnvironment.accessibility, .nonAccessibility] {
            let planned = await engine.planCorrection("Вщту!", editingEnvironment: environment)
            guard case .autoReplace(let candidate) = planned.plan else {
                XCTFail("Вщту! was not auto-corrected (\(environment)): \(String(describing: planned.plan))")
                continue
            }
            XCTAssertEqual(candidate.replacement, "Done!")
        }
    }

    func testRussianWordWithExclamationIsAutoCorrected() async {
        let planned = await engine.planCorrection("ghbdtn!", editingEnvironment: .nonAccessibility)
        guard case .autoReplace(let candidate) = planned.plan else {
            return XCTFail("ghbdtn! was not auto-corrected: \(String(describing: planned.plan))")
        }
        XCTAssertEqual(candidate.replacement, "привет!")
    }
}
