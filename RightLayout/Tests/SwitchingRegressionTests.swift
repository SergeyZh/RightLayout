import XCTest
@testable import RightLayout

/// Words that were switched wrongly, or not switched, in real use.
final class SwitchingRegressionTests: XCTestCase {
    private var engine: CorrectionEngine!
    private var originalLanguages: Set<Language>?

    private let activeLayouts = ["en": "us", "ru": "russianwin", "he": "hebrew"]
    private let installedLayouts: Set<String> = ["us", "russianwin", "hebrew"]

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

    // MARK: - Layouts the user doesn't have

    func testRussianWordIsNotTransliteratedThroughPhoneticLayout() {
        let variants = LayoutMapper.shared.convertAllVariants(
            "Саммари", from: .russian, to: .english,
            activeLayouts: activeLayouts, installedLayouts: installedLayouts
        )
        XCTAssertFalse(variants.contains { $0.result == "Sammari" }, "got \(variants.map(\.result))")
    }

    func testRussianWordIsNotConvertedThroughDvorak() {
        let variants = LayoutMapper.shared.convertAllVariants(
            "пзе", from: .russian, to: .english,
            activeLayouts: activeLayouts, installedLayouts: installedLayouts
        )
        let results = variants.map(\.result)
        XCTAssertFalse(results.contains("ily"), "got \(results)")
        XCTAssertTrue(results.contains("gpt"), "got \(results)")
    }

    func testEnabledRearrangedLayoutIsStillTried() {
        let variants = LayoutMapper.shared.convertAllVariants(
            "пзе", from: .russian, to: .english,
            activeLayouts: activeLayouts, installedLayouts: installedLayouts.union(["dvorak"])
        )
        XCTAssertTrue(variants.contains { $0.result == "ily" }, "got \(variants.map(\.result))")
    }

    func testSummaryInRussianIsLeftAlone() async {
        let planned = await engine.planCorrection("Саммари", editingEnvironment: .accessibility)
        if case .autoReplace(let candidate) = planned.plan {
            XCTFail("Саммари was replaced with \(candidate.replacement)")
        }
    }

    func testGptTypedInRussianIsNotTurnedIntoIly() async {
        let planned = await engine.planCorrection("пзе", editingEnvironment: .accessibility)
        if case .autoReplace(let candidate) = planned.plan {
            XCTAssertNotEqual(candidate.replacement, "ily")
        }
    }

    // MARK: - "Lf/" → "Да."

    actor IntentHost {
        let detector = IntentDetector()
        func check(_ text: String) async -> UserIntent { await detector.detect(text: text) }
    }

    func testWordWithTrailingSlashIsProse() async {
        let host = IntentHost()
        let lf = await host.check("Lf/")
        XCTAssertEqual(lf, .prose)
        let path = await host.check("src/main")
        XCTAssertEqual(path, .urlOrCommand)
        let root = await host.check("/usr")
        XCTAssertEqual(root, .urlOrCommand)
    }

    func testSlashThatBecomesAPeriodIsEdgePunctuation() {
        XCTAssertTrue(CorrectionDecisionPolicy.isWordWithEdgePunctuation(original: "Lf/", converted: "Да."))
        XCTAssertTrue(CorrectionDecisionPolicy.isWordWithEdgePunctuation(original: "Lf&", converted: "Да?"))
        // The other way round "/" is not punctuation the user meant.
        XCTAssertFalse(CorrectionDecisionPolicy.isWordWithEdgePunctuation(original: "руддщ.", converted: "hello/"))
    }

    func testDiagLf() async {
        for t in ["Lf", "Lf/", "Lf."] {
            await engine.resetCycling()
            let planned = await engine.planCorrection(t, editingEnvironment: .accessibility)
            let e = planned.result.evidence
            XCTFail("DIAG \(t): plan=\(planned.plan) conf=\(String(describing: planned.result.confidence)) hyp=\(String(describing: e?.decision.layoutHypothesis)) kind=\(String(describing: e?.tokenKind)) conv=\(String(describing: e?.convertedText)) margin=\(String(describing: e?.winnerMargin)) wl=\(String(describing: e?.isWhitelistedShort))")
        }
    }

    func testYesWithPeriodTypedInEnglishIsCorrected() async {
        let planned = await engine.planCorrection("Lf/", editingEnvironment: .accessibility)
        guard case .autoReplace(let candidate) = planned.plan else {
            return XCTFail("Lf/ was not auto-corrected: \(String(describing: planned.plan))")
        }
        XCTAssertEqual(candidate.replacement, "Да.")
    }

    // MARK: - Retyping when the host hides the separator (Slack)

    func testRetypeDeletesSeparatorTheHostDoesNotShow() {
        // Slack reports the caret before the space that was just typed.
        let plan = SelectionReplacementService.verifiedReplayPlan(
            fullText: "Gjlujnjdm ",
            selection: NSRange(location: 9, length: 0),
            verifiedRange: NSRange(location: 0, length: 9),
            expectedOriginal: "Gjlujnjdm",
            unverifiedSuffix: " "
        )
        XCTAssertEqual(plan?.deleteCount, 10)
        XCTAssertEqual(plan?.tail, " ")
        XCTAssertEqual(plan?.tailIsUnverified, true)
    }

    func testRetypeWhenTextLagsBehindCaret() {
        let plan = SelectionReplacementService.verifiedReplayPlan(
            fullText: "Gjlujnjdm",
            selection: NSRange(location: 10, length: 0),
            verifiedRange: NSRange(location: 0, length: 9),
            expectedOriginal: "Gjlujnjdm",
            unverifiedSuffix: " "
        )
        XCTAssertEqual(plan?.deleteCount, 10)
        XCTAssertEqual(plan?.tail, " ")
    }

    func testRetypeKeepsSeparatorTheHostShows() {
        let plan = SelectionReplacementService.verifiedReplayPlan(
            fullText: "Gjlujnjdm ",
            selection: NSRange(location: 10, length: 0),
            verifiedRange: NSRange(location: 0, length: 9),
            expectedOriginal: "Gjlujnjdm",
            unverifiedSuffix: " "
        )
        XCTAssertEqual(plan?.deleteCount, 10)
        XCTAssertEqual(plan?.tail, " ")
        XCTAssertEqual(plan?.tailIsUnverified, false)
    }

    func testRetypeWithoutSeparator() {
        let plan = SelectionReplacementService.verifiedReplayPlan(
            fullText: "Gjlujnjdm ",
            selection: NSRange(location: 10, length: 0),
            verifiedRange: NSRange(location: 0, length: 10),
            expectedOriginal: "Gjlujnjdm ",
            unverifiedSuffix: ""
        )
        XCTAssertEqual(plan?.deleteCount, 10)
        XCTAssertEqual(plan?.tail, "")
    }

    func testRetypeNeverRetypesANewline() {
        let plan = SelectionReplacementService.verifiedReplayPlan(
            fullText: "Gjlujnjdm",
            selection: NSRange(location: 9, length: 0),
            verifiedRange: NSRange(location: 0, length: 9),
            expectedOriginal: "Gjlujnjdm",
            unverifiedSuffix: "\n"
        )
        XCTAssertNil(plan)
    }
}
