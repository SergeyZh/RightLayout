import XCTest
@testable import RightLayout

/// The Algorithm page's test field: what each block reports about a typed word.
final class DecisionPlaygroundTests: XCTestCase {
    private var engine: CorrectionEngine!
    /// Loading the models takes a moment; one copy serves every test.
    private static let knowledge = KnowledgeLookup()
    private var originalPipeline = DecisionPipelineSettings.default
    private var originalLanguages: Set<Language>?
    private var originalLayouts: [String: String] = [:]
    private var originalLearning = true

    @MainActor
    override func setUp() async throws {
        let settings = SettingsManager.shared
        originalPipeline = settings.decisionPipeline
        originalLanguages = settings.customEnabledLanguages
        originalLayouts = settings.activeLayouts
        originalLearning = settings.isLearningEnabled
        settings.isEnabled = true
        settings.activeLayouts = ["en": "us", "ru": "russianwin", "he": "hebrew"]
        settings.customEnabledLanguages = [.english, .russian]
        settings.isLearningEnabled = false
        settings.decisionPipeline = .default
        engine = CorrectionEngine(settings: settings)
    }

    @MainActor
    override func tearDown() async throws {
        let settings = SettingsManager.shared
        settings.decisionPipeline = originalPipeline
        settings.customEnabledLanguages = originalLanguages
        settings.activeLayouts = originalLayouts
        settings.isLearningEnabled = originalLearning
        engine = nil
    }

    private func check(
        _ text: String,
        in app: PlaygroundApp = .readsText,
        endsWithEnter: Bool = false,
        settings: PlaygroundApplySettings = PlaygroundApplySettings()
    ) async -> [PlaygroundWord] {
        await DecisionPlayground.check(
            text,
            engine: engine,
            knowledge: Self.knowledge,
            app: app,
            endsWithEnter: endsWithEnter,
            settings: settings
        )
    }

    private func steps(_ word: PlaygroundWord, _ effect: DecisionEffect) -> [DecisionStep] {
        word.events.filter { $0.effect == effect }.map(\.step)
    }

    // MARK: The diagram and the probe name the same blocks

    func testEveryBlockReportsUnderItsOwnName() {
        let steps = AlgorithmDiagram.allNodes.map(\.step)
        XCTAssertFalse(steps.contains(nil), "A block of the diagram has no step of the probe")
        XCTAssertEqual(Set(steps.compactMap { $0 }), Set(DecisionStep.allCases))
    }

    func testEveryProbeNoteIsTranslated() throws {
        for code in ["ru", "he"] {
            let path = try XCTUnwrap(Bundle.rightLayoutResources.path(forResource: code, ofType: "lproj"))
            let bundle = try XCTUnwrap(Bundle(path: path))
            for note in ProbeNote.allCases {
                let translated = NSLocalizedString(note.rawValue, bundle: bundle, comment: "")
                // Notes with no words of their own ("\"%@\" (%@)") may stay as they are.
                let hasWords = note.rawValue.replacingOccurrences(of: "%@", with: "").contains(where: \.isLetter)
                if hasWords {
                    XCTAssertNotEqual(translated, note.rawValue, "No \(code) translation for \"\(note.rawValue)\"")
                }
                XCTAssertEqual(
                    translated.components(separatedBy: "%@").count,
                    note.rawValue.components(separatedBy: "%@").count,
                    "\(code): \"\(translated)\" takes other arguments than \"\(note.rawValue)\""
                )
            }
        }
    }

    func testNothingIsRecordedWithoutAProbe() {
        XCTAssertNil(DecisionProbe.current)
        DecisionProbe.record(.policy, .decided, .noAnswer)
        let probe = DecisionProbe()
        DecisionProbe.$current.withValue(probe) {
            DecisionProbe.record(.policy, .contributed, .kindPlain)
            DecisionProbe.record(.policy, .contributed, .kindPlain)
        }
        XCTAssertEqual(probe.events.map(\.note), [.kindPlain], "A repeated event is kept once")
    }

    // MARK: Checking words

    func testAWordTypedInTheWrongLayoutShowsWhoDecided() async {
        let words = await check("ghbdtn")
        XCTAssertEqual(words.count, 1)
        let word = words[0]
        XCTAssertEqual(word.outcome, .replace)
        XCTAssertEqual(word.shown, "привет")

        let decided = word.events.filter { $0.effect == .decided }.map(\.step)
        XCTAssertFalse(decided.isEmpty, "Some block must have decided: \(word.events)")
        XCTAssertTrue(word.events.contains { $0.step == .policy }, "The policy saw the word")
        XCTAssertTrue(word.events.contains { $0.step == .builtinLexicon && $0.arguments.first == "привет" })
        XCTAssertTrue(word.events.contains { $0.step == .userDictionary && $0.effect == .checked })
    }

    func testABlockThatDecidesSkipsTheRest() async {
        let word = await check("n/r/")[0]
        XCTAssertEqual(word.outcome, .replace)
        XCTAssertEqual(word.shown, "т.к.")
        XCTAssertTrue(word.events.contains { $0.step == .abbreviations && $0.effect == .decided })
        XCTAssertFalse(word.events.contains { $0.step == .scoredDecision || $0.step == .policy }, "\(word.events)")
    }

    func testAWordTypedCorrectlyIsLeftAlone() async {
        let word = await check("привет")[0]
        XCTAssertEqual(word.outcome, .leave)
        let decided = word.events.filter { $0.effect == .decided }.map(\.step)
        XCTAssertTrue(decided.contains(.russianProtection) || decided.contains(.whitelist), "\(word.events)")
    }

    func testEveryWordOfAPhraseIsChecked() async {
        let words = await check("ghbdtn rfr ltkf")
        XCTAssertEqual(words.map(\.typed), ["ghbdtn", "rfr", "ltkf"])
        XCTAssertEqual(words.first?.shown, "привет")
    }

    func testEachCheckStartsAfresh() async {
        let first = await check("ghbdtn")
        let second = await check("ghbdtn")
        XCTAssertEqual(first.map(\.shown), second.map(\.shown))
        XCTAssertEqual(first.map(\.outcome), second.map(\.outcome))
    }

    // MARK: Replacing the word

    func testAnAppThatReadsItsTextIsWrittenInPlace() async {
        let word = await check("ghbdtn")[0]
        XCTAssertTrue(steps(word, .decided).contains(.accessibilityWrite), "\(word.events)")
        XCTAssertTrue(word.events.contains { $0.step == .fieldCheck && $0.arguments == ["ghbdtn␣"] })
        XCTAssertTrue(word.events.contains { $0.step == .layoutSwitch && $0.note == .switchesBefore && $0.arguments == ["RU"] })
    }

    func testSlackIsRetypedAndReadBack() async {
        let word = await check("ghbdtn", in: .slack)[0]
        XCTAssertEqual(word.outcome, .replace)
        XCTAssertTrue(steps(word, .rejected).contains(.accessibilityWrite))
        let retype = word.events.first { $0.step == .verifiedRetype }
        XCTAssertEqual(retype?.effect, .decided)
        XCTAssertEqual(retype?.arguments, ["7", "привет␣"], "Erases the word and its space, then types both")
    }

    func testAnAppThatHidesItsTextIsRetypedBlind() async {
        let word = await check("ghbdtn", in: .hidesText)[0]
        XCTAssertEqual(word.outcome, .replace, "\(word.events)")
        XCTAssertTrue(steps(word, .decided).contains(.blindRetype))
        XCTAssertFalse(word.events.contains { $0.step == .accessibilityWrite || $0.step == .verifiedRetype })
    }

    func testAnUnknownAppThatHidesItsTextIsLeftToTheHotkey() async {
        let word = await check("ghbdtn", in: .unknownHidden)[0]
        XCTAssertEqual(word.outcome, .hotkeyOnly)
        XCTAssertEqual(word.shown, "ghbdtn")
        XCTAssertEqual(word.proposed, "привет")
        XCTAssertTrue(steps(word, .rejected).contains(.blindRetype))
        XCTAssertTrue(word.events.contains { $0.step == .layoutSwitch && $0.note == .layoutStays })
    }

    func testAWordEndingALineIsNotRetypedBlind() async {
        var settings = PlaygroundApplySettings()
        settings.holdsEnter = false
        let word = await check("ghbdtn", in: .hidesText, endsWithEnter: true, settings: settings)[0]
        XCTAssertEqual(word.outcome, .hotkeyOnly)
        XCTAssertTrue(word.events.contains { $0.step == .blindRetype && $0.note == .notRetypedNewline })
    }

    func testAHeldEnterIsNotRetypedYet() async {
        let word = await check("ghbdtn", in: .slack, endsWithEnter: true)[0]
        XCTAssertEqual(word.events.first { $0.step == .verifiedRetype }?.arguments, ["6", "привет"])
    }

    func testAHeldEnterShowsWhatItDidWithACorrectedWord() async {
        let word = await check("ghbdtn", endsWithEnter: true)[0]
        XCTAssertEqual(word.outcome, .replace)
        XCTAssertEqual(word.events.first { $0.step == .holdEnter }?.note, .enterHeld, "\(word.events)")

        let spaced = await check("ghbdtn")[0]
        XCTAssertEqual(spaced.events.first { $0.step == .holdEnter }?.note, .endsWithSpace)
    }

    func testLastChecksSayWhyTheyLeftACorrectionAlone() async {
        // "Ghbdtn/" is "Привет." already before the check for Russian punctuation at the
        // end; "Lf/" only becomes "Да." there.
        let word = await check("Ghbdtn/")[0]
        XCTAssertEqual(word.shown, "Привет.")
        XCTAssertEqual(word.events.first { $0.step == .wrongLayoutPunctuation }?.note, .alreadyCorrection, "\(word.events)")

        let short = await check("Lf/")[0]
        XCTAssertEqual(short.shown, "Да.")
        XCTAssertTrue(short.events.contains { $0.step == .wrongLayoutPunctuation && $0.effect == .decided }, "\(short.events)")

        // The lowercase rule takes letters only, so it says why it leaves "Lf/" to the next check.
        XCTAssertEqual(short.events.first { $0.step == .capitalizedShortWords }?.note, .capitalizedWithPunctuation, "\(short.events)")

        let typedCorrectly = await check("привет")[0]
        XCTAssertEqual(typedCorrectly.events.first { $0.step == .capitalizedShortWords }?.note, .doesNotApply)
    }

    func testWithAutoCorrectionOffNothingElseIsChecked() async {
        var settings = PlaygroundApplySettings()
        settings.correctsAutomatically = false
        let word = await check("ghbdtn", settings: settings)[0]
        XCTAssertEqual(word.outcome, .leave)
        XCTAssertEqual(word.shown, "ghbdtn")
        XCTAssertEqual(word.events.map(\.step), [.autoCorrectionOn], "\(word.events)")
        XCTAssertEqual(word.events.first?.effect, .decided)

        let on = await check("ghbdtn")[0]
        XCTAssertEqual(on.events.first { $0.step == .autoCorrectionOn }?.note, .autoCorrectionOnHere)
    }

    func testABlockTurnedOffReportsNothing() async {
        await MainActor.run { SettingsManager.shared.setDecisionComponent(.scoredDecision, enabled: false) }
        let word = await check("ghbdtn")[0]
        XCTAssertFalse(word.events.contains { $0.step == .scoredDecision }, "\(word.events)")
    }
}
