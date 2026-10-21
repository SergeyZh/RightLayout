import XCTest
@testable import RightLayout

final class CorrectionDecisionPolicyTests: XCTestCase {
    private func makeEvidence(
        original: String,
        converted: String,
        confidence: Double,
        margin: Double,
        tokenKind: DecisionTokenKind = .plain,
        targetLanguage: Language = .russian
    ) -> DecisionEvidence {
        let decision = LanguageDecision(
            language: targetLanguage,
            layoutHypothesis: .ruFromEnLayout,
            confidence: confidence,
            scores: [
                .ruFromEnLayout: confidence,
                .en: max(0.0, confidence - margin)
            ]
        )

        return DecisionEvidence(
            original: original,
            decision: decision,
            confidence: confidence,
            winnerMargin: margin,
            primaryCandidate: DecisionEvidenceCandidate(hypothesis: .ruFromEnLayout, score: confidence),
            secondaryCandidate: DecisionEvidenceCandidate(hypothesis: .en, score: max(0.0, confidence - margin)),
            tokenKind: tokenKind,
            convertedText: converted,
            sourceLayout: .english,
            targetLanguage: targetLanguage,
            isCorrection: true,
            isWhitelistedShort: false
        )
    }

    func testNonAccessibilityPlainTokenAutoAppliesAtRelaxedThreshold() {
        let evidence = makeEvidence(
            original: "ghbdtn",
            converted: "привет",
            confidence: 0.89,
            margin: 0.17
        )

        let disposition = CorrectionDecisionPolicy.evaluate(
            evidence: evidence,
            environment: .nonAccessibility,
            preset: .balanced
        )

        XCTAssertEqual(disposition, .autoApply)
    }

    func testSingleLetterRemainsManualOnlyInNonAccessibility() {
        let evidence = makeEvidence(
            original: "r",
            converted: "к",
            confidence: 0.99,
            margin: 0.40,
            tokenKind: .short
        )

        let disposition = CorrectionDecisionPolicy.evaluate(
            evidence: evidence,
            environment: .nonAccessibility,
            preset: .balanced
        )

        XCTAssertEqual(disposition, .manualOnly)
    }

    func testShortWordAutoAppliesInNonAccessibilityByDefault() {
        let evidence = makeEvidence(
            original: "yt",
            converted: "не",
            confidence: 0.95,
            margin: 0.30,
            tokenKind: .short
        )

        let disposition = CorrectionDecisionPolicy.evaluate(
            evidence: evidence,
            environment: .nonAccessibility,
            preset: .balanced
        )

        XCTAssertEqual(disposition, .autoApply)
    }

    func testMinimumWordLengthKeepsShorterWordsManual() {
        let evidence = makeEvidence(
            original: "yt",
            converted: "не",
            confidence: 0.95,
            margin: 0.30,
            tokenKind: .short
        )

        let disposition = CorrectionDecisionPolicy.evaluate(
            evidence: evidence,
            environment: .accessibility,
            preset: .balanced,
            limits: AutoCorrectionLimits(minimumWordLength: 3, blindConfidence: 0.88)
        )

        XCTAssertEqual(disposition, .manualOnly)
    }

    func testFourLetterWordAutoAppliesInNonAccessibility() {
        let evidence = makeEvidence(
            original: "ntcn",
            converted: "тест",
            confidence: 0.90,
            margin: 0.20
        )

        let disposition = CorrectionDecisionPolicy.evaluate(
            evidence: evidence,
            environment: .nonAccessibility,
            preset: .balanced
        )

        XCTAssertEqual(disposition, .autoApply)
    }

    func testBlindConfidenceSettingRaisesNonAccessibilityBar() {
        let evidence = makeEvidence(
            original: "ghbdtn",
            converted: "привет",
            confidence: 0.90,
            margin: 0.20
        )

        let disposition = CorrectionDecisionPolicy.evaluate(
            evidence: evidence,
            environment: .nonAccessibility,
            preset: .balanced,
            limits: AutoCorrectionLimits(minimumWordLength: 2, blindConfidence: 0.95)
        )

        XCTAssertEqual(disposition, .hint)
    }

    /// A "." typed after a Slack mention was held for the hotkey as "ю".
    func testLonePunctuationIsNotAWordTypedInTheWrongLayout() {
        for (original, converted) in [(".", "ю"), (",", "б"), (";", "ж")] {
            let evidence = makeEvidence(
                original: original,
                converted: converted,
                confidence: 0.95,
                margin: 0.95,
                tokenKind: .punctuated
            )
            for environment in [EditingEnvironment.accessibility, .nonAccessibility] {
                let disposition = CorrectionDecisionPolicy.evaluate(
                    evidence: evidence,
                    environment: environment,
                    preset: .aggressive
                )
                XCTAssertEqual(disposition, .reject, original)
            }
        }
    }

    /// "Yf;fk" ("Нажал") and "Drk.xbk" ("Включил") were only held for the hotkey in the
    /// Claude app, whose text can't be read back.
    func testWordWithLetterKeysThatArePunctuationAutoAppliesWithoutAccessibility() {
        for (original, converted) in [("Yf;fk", "Нажал"), ("Drk.xbk", "Включил"), ("[jhjij", "хорошо")] {
            let evidence = makeEvidence(
                original: original,
                converted: converted,
                confidence: 0.95,
                margin: 0.95,
                tokenKind: .punctuated
            )
            for preset in [SettingsManager.BehaviorPreset.balanced, .aggressive] {
                let disposition = CorrectionDecisionPolicy.evaluate(
                    evidence: evidence,
                    environment: .nonAccessibility,
                    preset: preset
                )
                XCTAssertEqual(disposition, .autoApply, "\(original) (\(preset))")
            }
        }
    }

    func testPunctuatedTokenThatIsNotAWordStaysManualWithoutAccessibility() {
        let shortWord = makeEvidence(original: "j,", converted: "об", confidence: 0.95, margin: 0.95, tokenKind: .punctuated)
        XCTAssertNotEqual(
            CorrectionDecisionPolicy.evaluate(evidence: shortWord, environment: .nonAccessibility, preset: .aggressive),
            .autoApply
        )
        let notAWord = makeEvidence(original: "Ж-)", converted: ":-)", confidence: 0.95, margin: 0.95, tokenKind: .punctuated)
        XCTAssertNotEqual(
            CorrectionDecisionPolicy.evaluate(evidence: notAWord, environment: .nonAccessibility, preset: .aggressive),
            .autoApply
        )
        let unsure = makeEvidence(original: "Yf;fk", converted: "Нажал", confidence: 0.80, margin: 0.95, tokenKind: .punctuated)
        XCTAssertNotEqual(
            CorrectionDecisionPolicy.evaluate(evidence: unsure, environment: .nonAccessibility, preset: .balanced),
            .autoApply
        )
    }

    func testBlindRetypeTakesTheLettersOfTheConvertedWord() {
        XCTAssertEqual(EventMonitor.blindReplayWord(original: "Yf;fk ", replacement: "Нажал").map(String.init), "Нажал")
        XCTAssertEqual(EventMonitor.blindReplayWord(original: "ghbdtn ", replacement: "привет").map(String.init), "ghbdtn")
        XCTAssertEqual(EventMonitor.blindReplayWord(original: "Lf/ ", replacement: "Да.").map(String.init), "Lf")
        XCTAssertNil(EventMonitor.blindReplayWord(original: "Ж-) ", replacement: ":-)"))
    }
}
