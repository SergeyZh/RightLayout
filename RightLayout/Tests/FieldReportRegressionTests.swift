import XCTest
@testable import RightLayout

/// Words from user reports: abbreviations and emoticons typed in the wrong layout,
/// and corrections that broke the text around them.
final class FieldReportRegressionTests: XCTestCase {
    private var engine: CorrectionEngine!
    private var originalLanguages: Set<Language>?
    private var originalLayouts: [String: String] = [:]
    private var originalLearning = true
    private let layouts = ["en": "us", "ru": "russianwin", "he": "hebrew"]
    private let enRu: Set<Language> = [.english, .russian]

    @MainActor
    override func setUp() async throws {
        let settings = SettingsManager.shared
        originalLayouts = settings.activeLayouts
        originalLearning = settings.isLearningEnabled
        settings.isEnabled = true
        settings.activeLayouts = layouts
        settings.isLearningEnabled = false
        originalLanguages = settings.customEnabledLanguages
        settings.customEnabledLanguages = [.english, .russian, .hebrew]
        engine = CorrectionEngine(settings: settings)
    }

    @MainActor
    override func tearDown() async throws {
        let settings = SettingsManager.shared
        settings.customEnabledLanguages = originalLanguages
        settings.activeLayouts = originalLayouts
        settings.isLearningEnabled = originalLearning
        engine = nil
    }

    // MARK: Abbreviations: "n/r/" is "т.к." on the Russian PC layout

    func testRussianAbbreviationsTypedOnTheEnglishLayout() {
        XCTAssertEqual(WrongLayoutShorthand.match("n/r/", enabledLanguages: enRu, activeLayouts: layouts)?.text, "т.к.")
        XCTAssertEqual(WrongLayoutShorthand.match("n/t/", enabledLanguages: enRu, activeLayouts: layouts)?.text, "т.е.")
        XCTAssertEqual(WrongLayoutShorthand.match("n/l/", enabledLanguages: enRu, activeLayouts: layouts)?.text, "т.д.")
        XCTAssertEqual(WrongLayoutShorthand.match("N/r/", enabledLanguages: enRu, activeLayouts: layouts)?.text, "Т.к.")
    }

    func testPathsAndEnglishShorthandAreNotAbbreviations() {
        for token in ["src/main", "n/a", "n/r", "a/b/", "and/or", "/usr/"] {
            XCTAssertNil(WrongLayoutShorthand.match(token, enabledLanguages: enRu, activeLayouts: layouts), token)
        }
    }

    func testAbbreviationIsCorrectedAutomatically() async {
        let planned = await engine.planCorrection("n/r/")
        guard case .autoReplace(let candidate) = planned.plan else {
            return XCTFail("Expected an automatic correction, got \(planned.plan)")
        }
        XCTAssertEqual(candidate.replacement, "т.к.")
        XCTAssertEqual(planned.result.targetLanguage, .russian)
    }

    func testAbbreviationIsTheFirstHotkeyCandidate() async {
        let corrected = await engine.correctLastWord("n/r/")
        XCTAssertEqual(corrected, "т.к.")
    }

    // MARK: Emoticons: Shift+; is "Ж" on the Russian layout

    func testEmoticonsTypedOnTheRussianLayout() {
        let expected = ["Ж-)": ":-)", "Ж)": ":)", "ж)": ";)", "Ж(": ":(", "Ж-(": ":-(", "ЖВ": ":D", "ЖЗ": ":P", "Ж))": ":))"]
        for (typed, emoticon) in expected {
            XCTAssertEqual(WrongLayoutShorthand.match(typed, enabledLanguages: enRu, activeLayouts: layouts)?.text, emoticon, typed)
        }
    }

    func testWordsAreNotEmoticons() {
        for token in ["Ж", "ЖБ", "Ж.", "жук", "привет", ":-)", "hello"] {
            XCTAssertNil(WrongLayoutShorthand.match(token, enabledLanguages: enRu, activeLayouts: layouts), token)
        }
    }

    func testEmoticonIsCorrectedWithoutSwitchingTheLayout() async {
        let planned = await engine.planCorrection("Ж-)")
        guard case .autoReplace(let candidate) = planned.plan else {
            return XCTFail("Expected an automatic correction, got \(planned.plan)")
        }
        XCTAssertEqual(candidate.replacement, ":-)")
        XCTAssertNil(planned.result.targetLanguage, "An emoticon must not switch the layout")
    }

    func testEmoticonIsTheFirstHotkeyCandidate() async {
        let corrected = await engine.correctLastWord("Ж-)")
        XCTAssertEqual(corrected, ":-)")
    }

    func testNoShorthandWithoutTheLanguages() {
        XCTAssertNil(WrongLayoutShorthand.match("Ж-)", enabledLanguages: [.russian, .hebrew], activeLayouts: layouts))
        XCTAssertNil(WrongLayoutShorthand.match("n/r/", enabledLanguages: [.english, .hebrew], activeLayouts: layouts))
    }

    // MARK: "На всякийс лучай" became "На всякийc kexfq"

    func testTextStartingInsideAWordIsNotAWholeWord() {
        let text = "На всякийс лучай "
        let location = (text as NSString).range(of: "с лучай").location
        XCTAssertTrue(EventMonitor.continuesWordBefore(location: location, in: text))
        XCTAssertFalse(EventMonitor.continuesWordBefore(location: (text as NSString).range(of: "всякийс").location, in: text))
        XCTAssertFalse(EventMonitor.continuesWordBefore(location: 0, in: text))
        XCTAssertFalse(EventMonitor.continuesWordBefore(location: 1, in: "(ghbdtn"))
        XCTAssertTrue(EventMonitor.continuesWordBefore(location: 3, in: "abc1"))
    }

    func testSingleLetterBeforeAWordIsOnlyConvertedIntoAWord() async {
        let cyrillicS = await engine.contextualCascadeCorrection(for: "с", targetLanguage: .english)
        XCTAssertNil(cyrillicS, "A Russian \"с\" before an English word is not \"c\"")
        let cyrillicV = await engine.contextualCascadeCorrection(for: "в", targetLanguage: .english)
        XCTAssertNil(cyrillicV)
        let englishI = await engine.contextualCascadeCorrection(for: "Ш", targetLanguage: .english)
        XCTAssertEqual(englishI, "I")
        let russianU = await engine.contextualCascadeCorrection(for: "e", targetLanguage: .russian)
        XCTAssertEqual(russianU, "у")
    }

    func testMisspelledRussianWordStaysRussian() async {
        for environment in [EditingEnvironment.accessibility, .nonAccessibility] {
            let planned = await engine.planCorrection("лучай", editingEnvironment: environment)
            let evidence = planned.result.evidence
            XCTAssertNotEqual(
                planned.result.targetLanguage, .english,
                "\(environment): plan=\(planned.plan) corrected=\(planned.result.corrected ?? "nil") "
                    + "action=\(planned.result.action) hyp=\(String(describing: evidence?.decision.layoutHypothesis)) "
                    + "conf=\(String(describing: evidence?.confidence)) kind=\(String(describing: evidence?.tokenKind))"
            )
            if case .autoReplace = planned.plan {
                XCTFail("\(environment): \"лучай\" must not be replaced, got \(planned.result.corrected ?? "nil")")
            }
        }
    }

    // MARK: "ghbdtn tcnm" became "привет еcnm"

    func testLettersTypedAfterTheSwitchAreConverted() {
        XCTAssertEqual(
            EventMonitor.convertLettersTypedAfterSwitch("cnm", from: .english, to: .russian, activeLayouts: layouts),
            "сть"
        )
        XCTAssertEqual(
            EventMonitor.convertLettersTypedAfterSwitch("сть", from: .english, to: .russian, activeLayouts: layouts),
            "сть",
            "Letters already in the new layout stay"
        )
        XCTAssertEqual(
            EventMonitor.convertLettersTypedAfterSwitch("n,", from: .english, to: .russian, activeLayouts: layouts),
            "т,",
            "Punctuation stays"
        )
    }
}
