import Foundation

package enum DecisionTokenKind: String, Sendable {
    case plain
    case short
    case punctuated
    case mixed
    case technical
}

package enum EditingEnvironment: Sendable {
    case accessibility
    case nonAccessibility
    case secureReadBlind
}

package enum CorrectionDisposition: Sendable {
    case autoApply
    case hint
    case manualOnly
    case reject
}

package struct DecisionEvidenceCandidate: Sendable {
    package let hypothesis: LanguageHypothesis
    package let score: Double
}

package struct DecisionEvidence: Sendable {
    package let original: String
    package let decision: LanguageDecision
    package let confidence: Double
    package let winnerMargin: Double
    package let primaryCandidate: DecisionEvidenceCandidate
    package let secondaryCandidate: DecisionEvidenceCandidate?
    package let tokenKind: DecisionTokenKind
    package let convertedText: String
    package let sourceLayout: Language?
    package let targetLanguage: Language
    package let isCorrection: Bool
    package let isWhitelistedShort: Bool
}

/// User-adjustable limits for automatic (as opposed to hotkey) correction.
package struct AutoCorrectionLimits: Sendable, Equatable {
    /// Words with fewer letters are left to the manual hotkey.
    package var minimumWordLength: Int
    /// Base confidence for apps whose text can't be read back (preset-adjusted).
    package var blindConfidence: Double

    package init(minimumWordLength: Int, blindConfidence: Double) {
        self.minimumWordLength = minimumWordLength
        self.blindConfidence = blindConfidence
    }

    package static let `default` = AutoCorrectionLimits(minimumWordLength: 2, blindConfidence: 0.88)
}

private struct PolicyThresholds {
    let axAuto: Double
    let axMargin: Double
    let axShortAuto: Double
    let axShortMargin: Double
    let axHint: Double
    let nonAXAuto: Double
    let nonAXMargin: Double
    let nonAXHint: Double
    let whitelistAuto: Double
    let whitelistHint: Double

    static func forPreset(
        _ preset: SettingsManager.BehaviorPreset,
        blindConfidence: Double = AutoCorrectionLimits.default.blindConfidence
    ) -> PolicyThresholds {
        let base = PolicyThresholds(
            axAuto: 0.78,
            axMargin: 0.12,
            axShortAuto: 0.90,
            axShortMargin: 0.16,
            axHint: 0.70,
            nonAXAuto: blindConfidence,
            nonAXMargin: 0.16,
            nonAXHint: 0.74,
            whitelistAuto: 0.90,
            whitelistHint: 0.65
        )

        switch preset {
        case .conservative:
            return PolicyThresholds(
                axAuto: min(1.0, base.axAuto + 0.06),
                axMargin: base.axMargin + 0.02,
                axShortAuto: min(1.0, base.axShortAuto + 0.06),
                axShortMargin: base.axShortMargin + 0.02,
                axHint: min(1.0, base.axHint + 0.04),
                nonAXAuto: min(1.0, base.nonAXAuto + 0.06),
                nonAXMargin: base.nonAXMargin + 0.02,
                nonAXHint: min(1.0, base.nonAXHint + 0.04),
                whitelistAuto: min(1.0, base.whitelistAuto + 0.06),
                whitelistHint: min(1.0, base.whitelistHint + 0.04)
            )
        case .balanced:
            return base
        case .aggressive:
            return PolicyThresholds(
                axAuto: max(0.0, base.axAuto - 0.06),
                axMargin: max(0.08, base.axMargin - 0.02),
                axShortAuto: max(0.0, base.axShortAuto - 0.06),
                axShortMargin: max(0.14, base.axShortMargin - 0.02),
                axHint: max(0.0, base.axHint - 0.05),
                nonAXAuto: max(0.5, base.nonAXAuto - 0.06),
                nonAXMargin: max(0.16, base.nonAXMargin - 0.02),
                nonAXHint: max(0.0, base.nonAXHint - 0.05),
                whitelistAuto: max(0.0, base.whitelistAuto - 0.06),
                whitelistHint: max(0.0, base.whitelistHint - 0.05)
            )
        }
    }
}

package enum CorrectionDecisionPolicy {
    /// Sentence punctuation that can stick to a word without being part of it.
    private static let edgePunctuation: Set<Character> = [
        "!", "?", ".", ",", ":", ";", "\"", "'", "(", ")", "«", "»", "…"
    ]

    /// Keys typed on a Latin layout that are sentence punctuation on the Russian PC
    /// layout: "/" is the period, "&" the question mark, "^" the colon ("Lf/" → "Да.").
    private static let wrongLayoutEdgePunctuation: Set<Character> = edgePunctuation.union(["/", "&", "^"])

    /// The letters of `text` without punctuation stuck to its edges ("Вщту!" → "Вщту"),
    /// or nil if anything other than letters is left.
    ///
    /// With `typedInWrongLayout`, keys that become sentence punctuation in the other
    /// layout also count as edge punctuation ("Lf/" → "Lf").
    package static func letterCore(of text: String, typedInWrongLayout: Bool = false) -> Substring? {
        let edges = typedInWrongLayout ? wrongLayoutEdgePunctuation : edgePunctuation
        guard let first = text.firstIndex(where: { !edges.contains($0) }),
              let last = text.lastIndex(where: { !edges.contains($0) }) else {
            return nil
        }
        let core = text[first...last]
        return core.allSatisfy(\.isLetter) ? core : nil
    }

    /// Whether `original` is a word with punctuation only at its edges, and that
    /// punctuation is still punctuation after conversion: "Вщту!" → "Done!" and
    /// "Lf/" → "Да." are, while "ghbdtn." → "приветю" (the period is a letter key in
    /// Russian) is not.
    package static func isWordWithEdgePunctuation(original: String, converted: String) -> Bool {
        guard let core = letterCore(of: original, typedInWrongLayout: true),
              core.count < original.count,
              let convertedCore = letterCore(of: converted) else {
            return false
        }
        return convertedCore.count == core.count
            && original.distance(from: original.startIndex, to: core.startIndex)
                == converted.distance(from: converted.startIndex, to: convertedCore.startIndex)
            && original.count == converted.count
    }

    /// Confidence an automatic correction needs in apps without readable text.
    package static func blindAutoApplyThreshold(
        preset: SettingsManager.BehaviorPreset,
        limits: AutoCorrectionLimits
    ) -> Double {
        PolicyThresholds.forPreset(preset, blindConfidence: limits.blindConfidence).nonAXAuto
    }

    package static func evaluate(
        evidence: DecisionEvidence,
        environment: EditingEnvironment,
        preset: SettingsManager.BehaviorPreset,
        limits: AutoCorrectionLimits = .default
    ) -> CorrectionDisposition {
        let thresholds = PolicyThresholds.forPreset(preset, blindConfidence: limits.blindConfidence)
        let minimumLetters = max(1, limits.minimumWordLength)

        guard evidence.isCorrection else {
            return .reject
        }

        guard evidence.convertedText != evidence.original else {
            return .reject
        }

        let letterCount = evidence.original.filter(\.isLetter).count
        // A lone punctuation mark (a "." after a word or a mention) is not a word typed
        // in the wrong layout, though its key is a letter in the other one ("." is "ю").
        if evidence.original.count == 1, !evidence.original.contains(where: { $0.isLetter || $0.isNumber }) {
            return .reject
        }
        if letterCount < minimumLetters {
            return .manualOnly
        }

        switch evidence.tokenKind {
        case .technical, .mixed:
            return .reject
        case .punctuated:
            // Keys that are punctuation on one layout and letters on the other: a
            // Russian word with "ж", "х", "э", "б" or "ю" typed on the English layout
            // ("Yf;fk" is "Нажал").
            let convertsToWord = letterCount >= 2
                && evidence.convertedText.allSatisfy({ $0.isLetter || $0.isWhitespace || $0 == "«" || $0 == "»" || $0 == "\"" || $0 == "'" })
            switch environment {
            case .accessibility:
                if convertsToWord,
                   evidence.confidence >= thresholds.axAuto,
                   evidence.winnerMargin >= thresholds.axMargin {
                    return .autoApply
                }
            case .nonAccessibility:
                // Decided like a plain word: such words were never corrected in apps
                // whose text can't be read back (Claude, Electron apps).
                if convertsToWord,
                   letterCount <= 18,
                   evidence.confidence >= thresholds.nonAXAuto,
                   evidence.winnerMargin >= thresholds.nonAXMargin {
                    return .autoApply
                }
            case .secureReadBlind:
                break
            }
            return evaluateAmbiguous(
                confidence: evidence.confidence,
                environment: environment,
                thresholds: thresholds
            )
        case .short:
            if evidence.isWhitelistedShort {
                // Short words are retyped whole either way, so the same bar applies
                // whether or not the host exposes its text.
                if environment != .secureReadBlind,
                   evidence.confidence >= thresholds.whitelistAuto,
                   evidence.winnerMargin >= thresholds.axShortMargin {
                    return .autoApply
                }
                if evidence.confidence >= thresholds.whitelistHint {
                    return .hint
                }
                return .manualOnly
            }

            switch environment {
            case .accessibility:
                if evidence.confidence >= thresholds.axShortAuto,
                   evidence.winnerMargin >= thresholds.axShortMargin {
                    return .autoApply
                }
                if evidence.confidence >= thresholds.axHint {
                    return .hint
                }
                return .manualOnly
            case .nonAccessibility:
                if evidence.confidence >= max(thresholds.axShortAuto, thresholds.nonAXAuto),
                   evidence.winnerMargin >= thresholds.axShortMargin {
                    return .autoApply
                }
                if evidence.confidence >= thresholds.nonAXHint {
                    return .hint
                }
                return .manualOnly
            case .secureReadBlind:
                return .manualOnly
            }
        case .plain:
            switch environment {
            case .accessibility:
                guard letterCount <= 18 else {
                    return .manualOnly
                }
                if evidence.confidence >= thresholds.axAuto && evidence.winnerMargin >= thresholds.axMargin {
                    return .autoApply
                }
                if evidence.confidence >= thresholds.axHint {
                    return .hint
                }
                return .manualOnly
            case .nonAccessibility:
                guard letterCount <= 18 else {
                    return .manualOnly
                }
                if evidence.confidence >= thresholds.nonAXAuto && evidence.winnerMargin >= thresholds.nonAXMargin {
                    return .autoApply
                }
                if evidence.confidence >= thresholds.nonAXHint {
                    return .hint
                }
                return .manualOnly
            case .secureReadBlind:
                return .manualOnly
            }
        }
    }

    private static func evaluateAmbiguous(
        confidence: Double,
        environment: EditingEnvironment,
        thresholds: PolicyThresholds
    ) -> CorrectionDisposition {
        switch environment {
        case .accessibility:
            return confidence >= thresholds.axHint ? .hint : .manualOnly
        case .nonAccessibility:
            return confidence >= thresholds.nonAXHint ? .hint : .manualOnly
        case .secureReadBlind:
            return .manualOnly
        }
    }
}
