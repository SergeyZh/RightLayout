import XCTest
@testable import RightLayout

/// The switches and parameters of the Algorithm page, and that the parts of the word
/// check follow them.
final class DecisionPipelineTests: XCTestCase {
    private var engine: CorrectionEngine!
    private var originalPipeline = DecisionPipelineSettings.default
    private var originalLanguages: Set<Language>?
    private var originalLayouts: [String: String] = [:]
    private var originalLearning = true
    private var originalMinLength = AutoCorrectionLimits.default.minimumWordLength

    @MainActor
    override func setUp() async throws {
        let settings = SettingsManager.shared
        originalPipeline = settings.decisionPipeline
        originalLanguages = settings.customEnabledLanguages
        originalLayouts = settings.activeLayouts
        originalLearning = settings.isLearningEnabled
        originalMinLength = settings.minAutoCorrectWordLength
        settings.isEnabled = true
        settings.activeLayouts = ["en": "us", "ru": "russianwin", "he": "hebrew"]
        settings.customEnabledLanguages = [.english, .russian]
        settings.isLearningEnabled = false
        settings.minAutoCorrectWordLength = AutoCorrectionLimits.default.minimumWordLength
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
        settings.minAutoCorrectWordLength = originalMinLength
        engine = nil
    }

    @MainActor
    private func turn(_ component: DecisionComponent, on: Bool) {
        SettingsManager.shared.setDecisionComponent(component, enabled: on)
    }

    // MARK: Settings

    func testEverythingIsOnWithTheConfiguredValuesByDefault() {
        let settings = DecisionPipelineSettings.default
        XCTAssertTrue(DecisionComponent.allCases.allSatisfy(settings.isEnabled))
        XCTAssertEqual(settings.value(.scoredLongMargin), ThresholdsConfig.shared.longWordMargin)
        XCTAssertEqual(settings.value(.coreMLMinConfidence), ThresholdsConfig.shared.correctionThreshold)
        XCTAssertEqual(settings.value(.deferredTimeout), ThresholdsConfig.shared.timing.pendingWordTimeout)
        for parameter in DecisionParameter.allCases {
            XCTAssertTrue(parameter.range.contains(parameter.defaultValue), "\(parameter) default is outside its range")
        }
    }

    func testSettingsSurviveStorage() {
        var settings = DecisionPipelineSettings()
        settings.disabled = [.coreML, .heuristic]
        settings.values = [.policyAutoConfidence: 0.85, .deferredTimeout: 8]
        XCTAssertEqual(DecisionPipelineSettings(stored: settings.stored), settings)
    }

    func testStoredSettingsFromAnotherVersionAreReadSafely() {
        let stored: [String: Any] = [
            "disabled": ["coreML", "somethingRemoved"],
            "values": ["policyAutoConfidence": 5.0, "somethingRemoved": 0.3]
        ]
        let settings = DecisionPipelineSettings(stored: stored)
        XCTAssertEqual(settings.disabled, [.coreML])
        XCTAssertEqual(settings.value(.policyAutoConfidence), DecisionParameter.policyAutoConfidence.range.upperBound)
        XCTAssertEqual(DecisionPipelineSettings(stored: nil), .default)
    }

    @MainActor
    func testRestoringDefaultsTurnsEverythingBackOn() {
        let settings = SettingsManager.shared
        let saved = (
            settings.isVerifierEnabled,
            settings.isFoundationModelEnabled,
            settings.holdEnterForCorrection,
            settings.transliterationHintsEnabled,
            settings.fastPathThreshold,
            settings.standardPathThreshold
        )
        defer {
            settings.isVerifierEnabled = saved.0
            settings.isFoundationModelEnabled = saved.1
            settings.holdEnterForCorrection = saved.2
            settings.transliterationHintsEnabled = saved.3
            settings.fastPathThreshold = saved.4
            settings.standardPathThreshold = saved.5
        }
        settings.setDecisionComponent(.coreML, enabled: false)
        settings.setDecisionParameter(.policyAutoConfidence, to: 0.9)
        settings.isVerifierEnabled = false

        settings.resetDecisionAlgorithm()

        XCTAssertTrue(settings.decisionPipeline.isDefault)
        XCTAssertTrue(DecisionPipeline.current.isDefault)
        XCTAssertTrue(settings.isVerifierEnabled)
    }

    // MARK: The diagram

    func testTheDiagramShowsEveryComponentOnce() {
        let shown = AlgorithmDiagram.allNodes.compactMap { node -> DecisionComponent? in
            if case .component(let component) = node.toggle { return component }
            return nil
        }
        XCTAssertEqual(shown.count, Set(shown).count, "A component is shown twice")
        XCTAssertEqual(Set(shown), Set(DecisionComponent.allCases))
    }

    func testTheDiagramOffersEveryParameter() {
        let offered = AlgorithmDiagram.allNodes.flatMap(\.controls).compactMap { control -> DecisionParameter? in
            if case .parameter(let parameter) = control { return parameter }
            return nil
        }
        XCTAssertEqual(Set(offered), Set(DecisionParameter.allCases))
        let ids = AlgorithmDiagram.allNodes.map(\.id)
        XCTAssertEqual(ids.count, Set(ids).count, "Node ids must be unique")
    }

    func testTheDiagramIsTranslatedToRussian() throws {
        let path = try XCTUnwrap(Bundle.rightLayoutResources.path(forResource: "ru", ofType: "lproj"))
        let russian = try XCTUnwrap(Bundle(path: path))
        var texts = AlgorithmDiagram.outcomes.map(\.title)
        for stage in [AlgorithmDiagram.knowledgeSources] + AlgorithmDiagram.stages {
            texts += [stage.title, stage.detail]
            for node in stage.nodes {
                texts += [node.title, node.summary, node.detail]
            }
        }
        for parameter in DecisionParameter.allCases {
            texts += [parameter.title, parameter.detail]
        }
        // Proper names stay as they are.
        let untranslated: Set<String> = ["Foundation Model"]
        for text in texts where !untranslated.contains(text) {
            XCTAssertNotEqual(NSLocalizedString(text, bundle: russian, comment: ""), text, "No Russian for \"\(text)\"")
        }
    }

    // MARK: Switches

    @MainActor
    func testKnowledgeSourcesCanBeTurnedOff() throws {
        let frequency = try XCTUnwrap(WordFrequencyModel.shared("ru"))
        XCTAssertTrue(BuiltinLexicon.contains("привет", language: .russian))
        XCTAssertGreaterThan(frequency.score("привет"), 0)

        turn(.builtinLexicon, on: false)
        turn(.frequencyDictionaries, on: false)
        XCTAssertFalse(BuiltinLexicon.contains("привет", language: .russian))
        XCTAssertEqual(frequency.score("привет"), 0)
        XCTAssertFalse(frequency.contains("привет"))

        turn(.builtinLexicon, on: true)
        turn(.frequencyDictionaries, on: true)
        XCTAssertTrue(BuiltinLexicon.contains("привет", language: .russian))
    }

    @MainActor
    func testAbbreviationsAndEmoticonsCanBeTurnedOffSeparately() {
        let layouts = ["en": "us", "ru": "russianwin", "he": "hebrew"]
        let languages: Set<Language> = [.english, .russian]

        turn(.abbreviations, on: false)
        XCTAssertNil(WrongLayoutShorthand.match("n/r/", enabledLanguages: languages, activeLayouts: layouts))
        XCTAssertEqual(WrongLayoutShorthand.match("Ж-)", enabledLanguages: languages, activeLayouts: layouts)?.text, ":-)")

        turn(.abbreviations, on: true)
        turn(.emoticons, on: false)
        XCTAssertEqual(WrongLayoutShorthand.match("n/r/", enabledLanguages: languages, activeLayouts: layouts)?.text, "т.к.")
        XCTAssertNil(WrongLayoutShorthand.match("Ж-)", enabledLanguages: languages, activeLayouts: layouts))
    }

    func testOneLetterRussianWordsCanBeTurnedOff() async {
        let corrected = await engine.planCorrection("b", phraseBuffer: "Прочитай", editingEnvironment: .accessibility)
        guard case .autoReplace(let candidate) = corrected.plan else {
            return XCTFail("Expected \"b\" after a Russian word to be corrected, got \(corrected.plan)")
        }
        XCTAssertEqual(candidate.replacement, "и")

        await MainActor.run { turn(.singleRussianLetter, on: false) }
        await engine.resetCycling()
        let kept = await engine.planCorrection("b", phraseBuffer: "Прочитай", editingEnvironment: .accessibility)
        if case .autoReplace(let candidate) = kept.plan {
            XCTFail("\"b\" was replaced with \(candidate.replacement) with the rule turned off")
        }
    }

    @MainActor
    func testTechnicalTokenGuardCanBeTurnedOff() {
        let router = ConfidenceRouter(settings: SettingsManager.shared)
        XCTAssertTrue(router.isTechnicalToken("readme.md"))
        turn(.technicalTokenGuard, on: false)
        XCTAssertFalse(router.isTechnicalToken("readme.md"))
    }

    // MARK: Parameters

    @MainActor
    func testPolicyThresholdsCanBeChanged() {
        let decision = LanguageDecision(
            language: .russian,
            layoutHypothesis: .ruFromEnLayout,
            confidence: 0.80,
            scores: [.ruFromEnLayout: 0.80, .en: 0.60]
        )
        let evidence = DecisionEvidence(
            original: "ghbdtn",
            decision: decision,
            confidence: 0.80,
            winnerMargin: 0.20,
            primaryCandidate: DecisionEvidenceCandidate(hypothesis: .ruFromEnLayout, score: 0.80),
            secondaryCandidate: DecisionEvidenceCandidate(hypothesis: .en, score: 0.60),
            tokenKind: .plain,
            convertedText: "привет",
            sourceLayout: .english,
            targetLanguage: .russian,
            isCorrection: true,
            isWhitelistedShort: false
        )
        func disposition() -> CorrectionDisposition {
            CorrectionDecisionPolicy.evaluate(evidence: evidence, environment: .accessibility, preset: .balanced)
        }

        XCTAssertEqual(disposition(), .autoApply)

        SettingsManager.shared.setDecisionParameter(.policyAutoConfidence, to: 0.85)
        XCTAssertEqual(disposition(), .hint)

        SettingsManager.shared.setDecisionParameter(.policyHintConfidence, to: 0.85)
        XCTAssertEqual(disposition(), .manualOnly)

        SettingsManager.shared.setDecisionParameter(.policyAutoConfidence, to: nil)
        SettingsManager.shared.setDecisionParameter(.policyHintConfidence, to: nil)
        XCTAssertEqual(disposition(), .autoApply)
    }

    @MainActor
    func testLearningThresholdsCanBeChanged() {
        // 3 corrections kept and 2 undone, on top of a prior of one each: the hopeful
        // estimate of the kept share is 4/7 + 1/√8 ≈ 0.93, above the default bar of 0.70.
        var state = RiskState()
        state.alpha = 4
        state.beta = 3
        XCTAssertEqual(RiskController.demote(policy: .autoApply, state: state), .autoApply)

        SettingsManager.shared.setDecisionParameter(.learningAutoDemoteBelow, to: 1.0)
        XCTAssertEqual(RiskController.demote(policy: .autoApply, state: state), .suggestHint)
    }
}
