import Foundation
import os.log

enum DetectionMode: Sendable {
    /// Used for background/automatic corrections. Prefer precision; avoid risky corrections.
    case automatic
    /// Used for user-invoked hotkey corrections. Prefer recall; ambiguity is acceptable.
    case manual
}

/// Known short Russian function words that are safe to auto-accept from a single Latin key.
/// Deliberately excludes pronouns like "я": they stay deferred/pending to avoid aggressive auto-fixes.
private let knownRussianPrepositions: Set<String> = ["а", "в", "и", "к", "о", "с", "у", "об"]

/// Orchestrates language detection by routing requests through Fast (N-gram) and Standard (Ensemble) paths
/// based on confidence thresholds.
actor ConfidenceRouter {
    private let ensemble: LanguageEnsemble
    // N-gram detectors are also loaded inside Ensemble, but for the "Fast Path" 
    // we might want direct access or just rely on Ensemble's underlying models.
    // For V1, we'll route everything through Ensemble but check its confidence 
    // to decide whether to stop or proceed to deeper analysis (if we had a separate deep model).
    // Actually, per spec, Fast Path should be N-gram only. 
    // To do this cleanly without duplicating model loading, we can expose N-gram scoring from Ensemble 
    // or instantiate lightweight checkers here.
    // simpler approach for now: The Ensemble ALREADY computes N-gram scores. 
    // We can refactor Ensemble to separate the signals, or just use Ensemble for everything 
    // but check "Fast Path" criteria on the result.
    // BETTER APPROACH: Let ConfidenceRouter own the components.
    // But refactoring Ensemble completely is risky. 
    // HYBRID APPROACH: Router wraps Ensemble. 
    // "Fast Path" logic: If text length >= 4 and N-gram check (via static lightweight instance or efficient call) is high confidence.
    
    // For this implementation, we will trust the plan:
    // 1. Fast Path: N-gram only.
    // 2. Standard Path: Ensemble.
    
    private var ruModel: NgramLanguageModel?
    private var enModel: NgramLanguageModel?
    private var heModel: NgramLanguageModel?
    private let coreML: CoreMLLayoutClassifier
    private let wordValidator: WordValidator
    private var unigramCache: [Language: WordFrequencyModel] = [:]
    private let builtinValidator: BuiltinWordValidator = BuiltinWordValidator()
    
    private let logger = Logger.detection
    private let settings: SettingsManager
    
    init(settings: SettingsManager) {
        self.settings = settings
        self.wordValidator = HybridWordValidator()
        self.ensemble = LanguageEnsemble()
        self.ruModel = try? NgramLanguageModel.loadLanguage("ru")
        self.enModel = try? NgramLanguageModel.loadLanguage("en")
        self.heModel = try? NgramLanguageModel.loadLanguage("he")
        self.coreML = CoreMLLayoutClassifier()

        // Ticket 72: Foundation Model classifier (macOS 26+)
        #if canImport(FoundationModels)
        if #available(macOS 26, *) {
            self._foundationModelStorage = FoundationModelClassifier()
        }
        #endif
    }

    // Ticket 72: Type-erased storage (Swift doesn't allow @available on stored properties)
    #if canImport(FoundationModels)
    private var _foundationModelStorage: Any? = nil
    #endif
    
    private let languageData = LanguageDataConfig.shared
    private let thresholds = ThresholdsConfig.shared

    func decisionEvidence(
        token: String,
        context: DetectorContext,
        mode: DetectionMode = .automatic
    ) async -> DecisionEvidence {
        let activeLayouts = await settings.activeLayouts
        let enabledLanguages = await settings.enabledLanguages
        var decision = await route(token: token, context: context, mode: mode)

        // A short word starting a sentence is decided like the same word in lowercase:
        // macOS's spell checker takes any capitalized short word for English ("Yj", "Lf"),
        // so "yj" became "но" while "Yj" was kept. The conversion keeps the capital
        // ("Yj" → "Но").
        if mode == .automatic,
           DecisionPipeline.isEnabled(.capitalizedShortWords),
           decision.layoutHypothesis.rawValue.contains("_from_") || Self.lowercasedCapitalizedShortWord(token) == nil {
            // Only a word the router took as typed correctly needs another look.
            Self.probeLastCheckNotNeeded(.capitalizedShortWords, decision: decision, token: token)
        }
        if mode == .automatic,
           DecisionPipeline.isEnabled(.capitalizedShortWords),
           !decision.layoutHypothesis.rawValue.contains("_from_"),
           let lowercased = Self.lowercasedCapitalizedShortWord(token) {
            let lowered = await route(token: lowercased, context: context, mode: mode)
            if lowered.layoutHypothesis.rawValue.contains("_from_") {
                DecisionLogger.shared.logDecision(token: token, path: "CAPITALIZED_AS_LOWERCASE", result: lowered)
                DecisionProbe.record(.capitalizedShortWords, .decided, .decidedAsLowercase, [lowercased, DecisionProbe.name(lowered.layoutHypothesis)])
                decision = lowered
            } else {
                DecisionProbe.record(.capitalizedShortWords, .checked, .lowercaseTypedCorrectly, [lowercased])
            }
        }

        var kind = tokenKind(for: token)
        let fallbackCandidate = scoredDecision(
            token: token,
            activeLayouts: activeLayouts,
            mode: mode,
            enabledLanguages: enabledLanguages
        )
        if kind == .plain,
           !decision.layoutHypothesis.rawValue.contains("_from_"),
           let fallbackCandidate,
           fallbackCandidate.layoutHypothesis.rawValue.contains("_from_"),
           fallbackCandidate.confidence >= DecisionPipeline.value(.scoredOverrideConfidence) {
            DecisionProbe.record(.scoredDecision, .decided, .overridesTypedCorrectly, [
                DecisionProbe.name(fallbackCandidate.layoutHypothesis),
                DecisionProbe.percent(fallbackCandidate.confidence)
            ])
            decision = fallbackCandidate
        }

        if mode == .automatic,
           DecisionPipeline.isEnabled(.wrongLayoutPunctuation),
           !decision.layoutHypothesis.rawValue.contains("_from_"),
           let punctuated = wrongLayoutPunctuationDecision(
               token: token,
               activeLayouts: activeLayouts,
               enabledLanguages: enabledLanguages
           ) {
            decision = punctuated
        } else if mode == .automatic, DecisionPipeline.isEnabled(.wrongLayoutPunctuation) {
            Self.probeLastCheckNotNeeded(.wrongLayoutPunctuation, decision: decision)
        }

        let convertedText = convertedText(for: token, decision: decision, activeLayouts: activeLayouts)
        // A word with sentence punctuation stuck to it ("Вщту!" → "Done!") is decided
        // like the word itself.
        if kind == .punctuated,
           CorrectionDecisionPolicy.isWordWithEdgePunctuation(original: token, converted: convertedText) {
            kind = token.filter(\.isLetter).count <= 3 ? .short : .plain
        }
        let rankedCandidates = rankedEvidenceCandidates(for: decision)
        let primaryCandidate = rankedCandidates.first ?? DecisionEvidenceCandidate(
            hypothesis: decision.layoutHypothesis,
            score: decision.confidence
        )
        let secondaryCandidate = rankedCandidates.dropFirst().first
        let winnerMargin = max(0.0, primaryCandidate.score - (secondaryCandidate?.score ?? 0.0))
        let lettersOnly = token.filter(\.isLetter)
        let isWhitelistedShort =
            lettersOnly.count <= 3 &&
            decision.layoutHypothesis.rawValue.contains("_from_") &&
            languageData.whitelistedLanguage(convertedText) == decision.language

        return DecisionEvidence(
            original: token,
            decision: decision,
            confidence: decision.confidence,
            winnerMargin: winnerMargin,
            primaryCandidate: primaryCandidate,
            secondaryCandidate: secondaryCandidate,
            tokenKind: kind,
            convertedText: convertedText,
            sourceLayout: sourceLayout(for: decision.layoutHypothesis),
            targetLanguage: decision.language,
            isCorrection: decision.layoutHypothesis.rawValue.contains("_from_"),
            isWhitelistedShort: isWhitelistedShort
        )
    }

    /// Tells the test field's probe why a last check left the decision alone: the router
    /// had already found a correction ("Ghbdtn/" is "Привет." without it), or the check
    /// doesn't fit the word.
    private static func probeLastCheckNotNeeded(_ step: DecisionStep, decision: LanguageDecision, token: String = "") {
        if decision.layoutHypothesis.rawValue.contains("_from_") {
            DecisionProbe.record(step, .checked, .alreadyCorrection, [DecisionProbe.name(decision.layoutHypothesis)])
        } else if step == .capitalizedShortWords,
                  let core = CorrectionDecisionPolicy.letterCore(of: token, typedInWrongLayout: true),
                  core.count < token.count,
                  lowercasedCapitalizedShortWord(String(core)) != nil {
            // "Lf/": the punctuation keeps this check out; the next one may still help.
            DecisionProbe.record(step, .checked, .capitalizedWithPunctuation, [token])
        } else {
            DecisionProbe.record(step, .checked, .doesNotApply)
        }
    }

    /// `token` in lowercase if it is a word of two or three letters with only its first
    /// one a capital ("Yj", not "YJ" or "yJ"), otherwise nil.
    static func lowercasedCapitalizedShortWord(_ token: String) -> String? {
        guard (2...3).contains(token.count),
              token.allSatisfy(\.isLetter),
              let first = token.first, first.isUppercase,
              token.dropFirst().allSatisfy(\.isLowercase) else {
            return nil
        }
        return token.lowercased()
    }

    /// A Latin word ending in a key that is sentence punctuation only on the Russian
    /// layout ("Lf/" → "Да.", "Lf&" → "Да?") was typed in the wrong layout, even when
    /// the bare word is also an English abbreviation: nobody ends an English word
    /// with "/" or "&".
    ///
    /// Other sentence punctuation ("Lf?" → "Да,") ends the sentence too, so no later
    /// word will settle it; there the bare word must be a common Russian word and not
    /// a common English one.
    private func wrongLayoutPunctuationDecision(
        token: String,
        activeLayouts: [String: String],
        enabledLanguages: Set<Language>
    ) -> LanguageDecision? {
        let russianOnlyPunctuation: Set<Character> = ["/", "&", "^"]
        guard LanguageHypothesis.ruFromEnLayout.isAllowed(in: enabledLanguages),
              dominantScriptLanguage(token) == .english,
              let converted = LayoutMapper.shared.convert(token, from: .english, to: .russian, activeLayouts: activeLayouts),
              CorrectionDecisionPolicy.isWordWithEdgePunctuation(original: token, converted: converted),
              let core = CorrectionDecisionPolicy.letterCore(of: converted),
              wordValidator.confidence(for: String(core), language: .russian) >= thresholds.targetWordMin else {
            return nil
        }
        if !token.contains(where: { russianOnlyPunctuation.contains($0) }) {
            guard let typedCore = CorrectionDecisionPolicy.letterCore(of: token, typedInWrongLayout: true),
                  BuiltinLexicon.contains(core.lowercased(), language: .russian),
                  !BuiltinLexicon.contains(typedCore.lowercased(), language: .english) else {
                return nil
            }
        }
        let decision = LanguageDecision(language: .russian, layoutHypothesis: .ruFromEnLayout, confidence: 0.95, scores: [:])
        DecisionLogger.shared.logDecision(token: token, path: "WRONG_LAYOUT_PUNCTUATION", result: decision)
        DecisionProbe.record(.wrongLayoutPunctuation, .decided, .russianPunctuationAtEnd, [converted])
        return decision
    }

    private func rankedEvidenceCandidates(for decision: LanguageDecision) -> [DecisionEvidenceCandidate] {
        if !decision.scores.isEmpty {
            return decision.scores
                .map { DecisionEvidenceCandidate(hypothesis: $0.key, score: $0.value) }
                .sorted { lhs, rhs in
                    if lhs.score == rhs.score {
                        return lhs.hypothesis.rawValue < rhs.hypothesis.rawValue
                    }
                    return lhs.score > rhs.score
                }
        }

        return [
            DecisionEvidenceCandidate(
                hypothesis: decision.layoutHypothesis,
                score: decision.confidence
            )
        ]
    }
    
    /// Main entry point for detection
    /// 
    /// NEW LOGIC (v2):
    /// - N-gram/Ensemble detect the SCRIPT of the text (Cyrillic -> "Russian").
    /// - CoreML detects LAYOUT MISMATCH ("this Cyrillic is gibberish Russian, but valid Hebrew from RU layout").
    /// - We ALWAYS invoke CoreML to check for `_from_` hypotheses, even if Fast/Standard is confident.
    func route(token: String, context: DetectorContext, mode: DetectionMode = .automatic) async -> LanguageDecision {
        let enabledLanguages = await settings.enabledLanguages
        let decision = await routeUnrestricted(
            token: token,
            context: context,
            mode: mode,
            enabledLanguages: enabledLanguages
        )
        return restrict(decision, token: token, to: enabledLanguages)
    }

    /// Last line of defence: a decision that involves a language the user doesn't work
    /// with never turns into a correction; the token is kept as typed.
    private func restrict(_ decision: LanguageDecision, token: String, to enabledLanguages: Set<Language>) -> LanguageDecision {
        let allowedScores = decision.scores.filter { $0.key.isAllowed(in: enabledLanguages) }
        guard !decision.layoutHypothesis.isAllowed(in: enabledLanguages) else {
            DecisionProbe.record(.languageFilter, .checked, .workingLanguagesOnly)
            return allowedScores.count == decision.scores.count
                ? decision
                : LanguageDecision(
                    language: decision.language,
                    layoutHypothesis: decision.layoutHypothesis,
                    confidence: decision.confidence,
                    scores: allowedScores
                )
        }

        let language = dominantScriptLanguage(token) ?? decision.layoutHypothesis.sourceLanguage ?? .english
        DecisionLogger.shared.log("LANGUAGE_FILTER: \(decision.layoutHypothesis.rawValue) involves a disabled language, keeping as-is")
        DecisionProbe.record(.languageFilter, .decided, .languageOff, [DecisionProbe.name(decision.layoutHypothesis)])
        return LanguageDecision(
            language: language,
            layoutHypothesis: language.asHypothesis,
            confidence: decision.confidence,
            scores: allowedScores
        )
    }

    private func routeUnrestricted(
        token: String,
        context: DetectorContext,
        mode: DetectionMode,
        enabledLanguages: Set<Language>
    ) async -> LanguageDecision {
        // NEW: User Dictionary Lookup
        if DecisionPipeline.isEnabled(.userDictionary),
           let rule = await UserDictionary.shared.lookup(token) {
            switch rule.action {
            case .keepAsIs:
                if mode == .manual {
                     // Unlearning Flow A: User forces correction on a "keep as-is" token
                     await UserDictionary.shared.recordOverride(token: token)
                     // Proceed with detection (ignore the rule)
                } else {
                     // Automatic mode: Respect the rule (do NOT correct)
                     let dominant = dominantScriptLanguage(token)
                     let lang = dominant ?? .english
                     let hyp: LanguageHypothesis = (lang == .russian) ? .ru : ((lang == .hebrew) ? .he : .en)
                     
                     let decision = LanguageDecision(language: lang, layoutHypothesis: hyp, confidence: 1.0, scores: [:])
                     DecisionLogger.shared.logDecision(token: token, path: "USER_DICT_KEEP", result: decision)
                     DecisionProbe.record(.userDictionary, .decided, .ruleKeep)
                     return decision
                }
            case .preferHypothesis(let hypStr):
                 // Check if we can map string to hypothesis
                 if let hyp = LanguageHypothesis(rawValue: hypStr) {
                      // User explicitly wants this conversion - apply it without strict validation
                      let activeLayouts = await settings.activeLayouts
                      let target = hyp.targetLanguage
                      
                      // Determine source language from hypothesis
                      let source: Language
                      switch hyp {
                      case .ruFromEnLayout, .heFromEnLayout: source = .english
                      case .enFromRuLayout, .heFromRuLayout: source = .russian
                      case .enFromHeLayout, .ruFromHeLayout: source = .hebrew
                      default: source = .english // as-is hypotheses don't need conversion
                      }
                      
                      // Try to convert using the preferred hypothesis
                      if let converted = LayoutMapper.shared.convertBest(token, from: source, to: target, activeLayouts: activeLayouts),
                         converted != token {
                           let decision = LanguageDecision(
                               language: target,
                               layoutHypothesis: hyp,
                               confidence: 1.0,
                               scores: [:]
                           )
                           DecisionLogger.shared.logDecision(token: token, path: "USER_DICT_PREFER", result: decision)
                           DecisionProbe.record(.userDictionary, .decided, .rulePrefer, [DecisionProbe.name(hyp)])
                           return decision
                      }
                 }
            case .none:
                 break
            default:
                 break
            }
        } else if DecisionPipeline.isEnabled(.userDictionary) {
            DecisionProbe.record(.userDictionary, .checked, .noRule)
        }

        // Mixed-script guard (automatic + manual):
        // If the token contains letters from multiple scripts (Latin/Cyrillic/Hebrew),
        // do NOT attempt layout correction. Treat it as intended and keep as-is.
        // This prevents false positives like "hello мир" becoming "hello vbh".
        do {
            var latin = 0
            var cyr = 0
            var heb = 0
            for scalar in token.unicodeScalars {
                switch scalar.value {
                case 0x0041...0x005A, 0x0061...0x007A:
                    latin += 1
                case 0x0400...0x04FF:
                    cyr += 1
                case 0x0590...0x05FF:
                    heb += 1
                default:
                    continue
                }
            }
            
            // Ticket 47: Single-letter Safety Policy
            // Rules:
            // 1. Single Cyrillic/Hebrew letter -> FORCE KEEP (don't convert to Latin/Other).
            //    Reason: almost never accidental.
            // 2. Single Latin letter -> FORCE KEEP (don't convert to Cyrillic/Hebrew).
            //    Reason: variables (x, y, z), abbreviations, and false-positive ping-pong risk.
            //    Exception: Manual mode (hotkey) can override this.
            //    Exception (Ticket 59): Known prepositions (y -> н) are allowed if active layout checks pass.
            if mode == .automatic, DecisionPipeline.isEnabled(.singleLetterSafety) {
                let letterCount = latin + cyr + heb
                if letterCount == 1 {
                    // Determine which script the single letter belongs to
                    let lang: Language = (cyr > 0) ? .russian : ((heb > 0) ? .hebrew : .english)
                    
                    // Allow conversion IF: it's English -> Russian AND result is a known preposition
                    if lang == .english {
                        // Check if it maps to a Russian preposition
                        let activeLayouts = await settings.activeLayouts
                        if let converted = LayoutMapper.shared.convertBest(token, from: .english, to: .russian, activeLayouts: activeLayouts),
                           knownRussianPrepositions.contains(converted) {
                            DecisionProbe.record(.singleLetterSafety, .checked, .singleLetterPreposition, [converted])
                            // It's a valid preposition (e.g. y -> н), allow normal processing
                            // We do NOT return 'decision' here, we let it fall through to detection logic
                             // But we must Break out of this if/return block.
                             // Since we are in an 'if', we just don't return.
                        } else {
                            // Default safety: Keep as English
                            let decision = LanguageDecision(
                                language: .english,
                                layoutHypothesis: .en,
                                confidence: 1.0,
                                scores: [:]
                            )
                            DecisionLogger.shared.logDecision(token: token, path: "SINGLE_LETTER_SAFETY_EN", result: decision)
                            DecisionProbe.record(.singleLetterSafety, .decided, .singleLetterKept)
                            return decision
                        }
                    } else {
                        // For Cyrillic/Hebrew single letters, assume correct (don't convert to English)
                        let hyp: LanguageHypothesis = (lang == .russian) ? .ru : .he
                        let decision = LanguageDecision(
                            language: lang,
                            layoutHypothesis: hyp,
                            confidence: 1.0, 
                            scores: [:]
                        )
                        DecisionLogger.shared.logDecision(token: token, path: "SINGLE_LETTER_SAFETY_OTHER", result: decision)
                        DecisionProbe.record(.singleLetterSafety, .decided, .singleLetterKept)
                        return decision
                    }
                } else {
                    DecisionProbe.record(.singleLetterSafety, .checked, .notSingleLetter)
                }
            }

            let scriptCount = (latin > 0 ? 1 : 0) + (cyr > 0 ? 1 : 0) + (heb > 0 ? 1 : 0)
            if scriptCount >= 2, DecisionPipeline.isEnabled(.mixedScriptGuard) {
                let lang: Language
                if cyr >= latin && cyr >= heb {
                    lang = .russian
                } else if heb >= latin && heb >= cyr {
                    lang = .hebrew
                } else {
                    lang = .english
                }
                let decision = LanguageDecision(language: lang, layoutHypothesis: lang.asHypothesis, confidence: 1.0, scores: [:])
                DecisionLogger.shared.logDecision(token: token, path: "MIXED_SCRIPT_KEEP", result: decision)
                DecisionProbe.record(.mixedScriptGuard, .decided, .mixedAlphabetsKept)
                return decision
            } else if DecisionPipeline.isEnabled(.mixedScriptGuard) {
                DecisionProbe.record(.mixedScriptGuard, .checked, .oneAlphabet)
            }
        }

        // Technical token guard (automatic mode):
        // Prevent accidental conversion of file paths, UUIDs, semver, etc.
        if mode == .automatic, isTechnicalToken(token) {
            let decision = LanguageDecision(language: .english, layoutHypothesis: .en, confidence: 1.0, scores: [:])
            DecisionLogger.shared.logDecision(token: token, path: "TECHNICAL_KEEP", result: decision)
            DecisionProbe.record(.technicalTokenGuard, .decided, .technicalKept)
            return decision
        } else if mode == .automatic, DecisionPipeline.isEnabled(.technicalTokenGuard) {
            DecisionProbe.record(.technicalTokenGuard, .checked, .notTechnical)
        }

        // Whitelist check - don't convert common words/slang
        if DecisionPipeline.isEnabled(.whitelist),
           let lang = languageData.whitelistedLanguage(token) {
            let hyp: LanguageHypothesis = lang == .english ? .en : (lang == .russian ? .ru : .he)
            let decision = LanguageDecision(language: lang, layoutHypothesis: hyp, confidence: 1.0, scores: [:])
            DecisionLogger.shared.logDecision(token: token, path: "WHITELIST", result: decision)
            DecisionProbe.record(.whitelist, .decided, .whitelisted, [DecisionProbe.name(lang)])
            return decision
        } else if DecisionPipeline.isEnabled(.whitelist) {
            DecisionProbe.record(.whitelist, .checked, .notWhitelisted)
        }

        // Strong-script sanity (automatic mode):
        // If the token is dominantly Cyrillic and looks like a valid Russian word/phrase,
        // do NOT attempt layout corrections away from Russian. This prevents false positives like
        // "люблю" being treated as `en_from_ru` and entering an auto-reject learning loop.
        if mode == .automatic,
           DecisionPipeline.isEnabled(.russianProtection),
           dominantScriptLanguage(token) == .russian {
            let ruWord = wordValidator.confidence(for: token, language: .russian)
            if ruWord >= DecisionPipeline.value(.russianProtectionMin) {
                let decision = LanguageDecision(language: .russian, layoutHypothesis: .ru, confidence: 1.0, scores: [:])
                DecisionLogger.shared.logDecision(token: token, path: "SCRIPT_LOCK_RU", result: decision)
                DecisionProbe.record(.russianProtection, .decided, .knownRussian, [DecisionProbe.percent(ruWord)])
                return decision
            }
            DecisionProbe.record(.russianProtection, .checked, .notKnownRussian, [
                DecisionProbe.percent(ruWord),
                DecisionProbe.percent(DecisionPipeline.value(.russianProtectionMin))
            ])
        } else if mode == .automatic, DecisionPipeline.isEnabled(.russianProtection) {
            DecisionProbe.record(.russianProtection, .checked, .notCyrillic)
        }
        
        let startTime = CFAbsoluteTimeGetCurrent()
        defer {
             let duration = CFAbsoluteTimeGetCurrent() - startTime
             if duration > 0.05 {
                 logger.warning("⚠️ Slow detection: \(String(format: "%.1f", duration * 1000))ms for \(DecisionLogger.tokenSummary(token), privacy: .public)")
             }
        }

        let activeLayouts = await settings.activeLayouts

        // -- STEP 0: Score-based decision (layout + language via conversions + n-grams + lexicon) --
        // This is deterministic and fixes cases where CoreML/NL miss the layout mismatch.
        if let scored = scoredDecision(
            token: token,
            activeLayouts: activeLayouts,
            mode: mode,
            enabledLanguages: enabledLanguages
        ) {
            let stdThreshold = await settings.standardPathThreshold
            if scored.confidence >= stdThreshold {
                DecisionLogger.shared.logDecision(token: token, path: "SCORE", result: scored)
                DecisionProbe.record(.scoredDecision, .decided, .confidentDecided, [DecisionProbe.percent(scored.confidence)])
                return scored
            }
            DecisionProbe.record(.scoredDecision, .contributed, .belowThreshold, [
                DecisionProbe.percent(scored.confidence),
                DecisionProbe.percent(stdThreshold)
            ])
        }
        
        // -- STEP 1: Get a baseline decision via Fast or Standard path --
        var baselineDecision: LanguageDecision?
        var baselinePath = "STANDARD"
        
        // 1a. FAST PATH: N-gram Only
        if token.count < 4, DecisionPipeline.isEnabled(.fastPath) {
            DecisionProbe.record(.fastPath, .checked, .shorterThanFour)
        }
        if token.count >= 4, DecisionPipeline.isEnabled(.fastPath) {
            if let fastDecision = checkFastPath(token) {
                let threshold = await settings.fastPathThreshold
                if fastDecision.confidence < threshold {
                    DecisionProbe.record(.fastPath, .checked, .answerBelow, [
                        DecisionProbe.name(fastDecision.layoutHypothesis),
                        DecisionProbe.percent(fastDecision.confidence),
                        DecisionProbe.percent(threshold)
                    ])
                }
                if fastDecision.confidence >= threshold {
                    DecisionProbe.record(.fastPath, .contributed, .typedCorrectlyIn, [
                        DecisionProbe.name(fastDecision.language),
                        DecisionProbe.percent(fastDecision.confidence)
                    ])
                    logger.info("🚀 Fast Path (N-gram) candidate: \(fastDecision.language.rawValue, privacy: .public) (conf: \(fastDecision.confidence))")
                    baselineDecision = fastDecision
                    baselinePath = "FAST"
                }
            } else {
                DecisionProbe.record(.fastPath, .checked, .trigramsUnsure)
            }
        }
        
        // 1b. STANDARD PATH: Ensemble (if Fast Path didn't produce high-confidence result)
        if baselineDecision == nil, !DecisionPipeline.isEnabled(.ensemble) {
            // Without the ensemble the baseline is the word as typed, with no confidence
            // to speak of: only the checks below can find a correction.
            let language = dominantScriptLanguage(token) ?? .english
            baselineDecision = LanguageDecision(
                language: language,
                layoutHypothesis: language.asHypothesis,
                confidence: thresholds.fallbackConfidence,
                scores: [:]
            )
            baselinePath = "FALLBACK"
        }

        if baselineDecision == nil {
            let ensembleContext = EnsembleContext(lastLanguage: context.lastLanguage, activeLayouts: activeLayouts)
            let decision = await ensemble.classify(token, context: ensembleContext)
            DecisionProbe.record(.ensemble, .contributed, .baseline, [
                DecisionProbe.name(decision.layoutHypothesis),
                DecisionProbe.percent(decision.confidence)
            ])
            let stdThreshold = await settings.standardPathThreshold
            if decision.confidence >= stdThreshold {
                logger.info("🛡️ Standard Path (Ensemble) candidate: \(decision.language.rawValue, privacy: .public) (conf: \(decision.confidence))")
                baselineDecision = decision
                baselinePath = "STANDARD"
            } else {
                // Even low confidence is better than nothing for fallback
                baselineDecision = decision
                baselinePath = "FALLBACK"
            }
        }
        
        guard let baseline = baselineDecision else {
            let fallback = LanguageDecision(language: .english, layoutHypothesis: .en, confidence: thresholds.fallbackConfidence, scores: [:])
            DecisionLogger.shared.logDecision(token: token, path: "ERROR", result: fallback)
            return fallback
        }

        // If baseline already suggests a correction, validate it before involving CoreML.
        if baseline.layoutHypothesis.rawValue.contains("_from_") {
            if let validated = validateCorrection(
                token: token,
                hypothesis: baseline.layoutHypothesis,
                confidence: baseline.confidence,
                activeLayouts: activeLayouts
            ) {
                DecisionLogger.shared.logDecision(token: token, path: "BASELINE_CORRECTION", result: validated)
                DecisionProbe.record(baselinePath == "FAST" ? .fastPath : .ensemble, .decided, .baselineConfirmed, [
                    DecisionProbe.name(validated.layoutHypothesis),
                    DecisionProbe.percent(validated.confidence)
                ])
                return validated
            }
        }

        // -- STEP 2: ALWAYS invoke CoreML to check for layout mismatch --
        // CoreML can detect "_from_" hypotheses that contradict the baseline.
        logger.info("🧠 Deep Path (CoreML) checking for layout mismatch: \(DecisionLogger.tokenSummary(token), privacy: .public)")
        
        let prediction = DecisionPipeline.isEnabled(.coreML) ? coreML.predict(token) : nil
        if DecisionPipeline.isEnabled(.coreML), prediction == nil {
            DecisionProbe.record(.coreML, .checked, .noAnswer)
        }
        if let (deepHypothesis, deepConf) = prediction {
            logger.info("🧠 Deep Path result: \(deepHypothesis.rawValue, privacy: .public) (conf: \(deepConf))")
            
            let isCorrection = deepHypothesis.rawValue.contains("_from_")
            
            if isCorrection {
                // CoreML thinks this is a layout mismatch (e.g. "en_from_ru").
                // VALIDATION: Before accepting, convert the text and verify the result
                // is actually valid in the target language using N-gram scoring.
                if deepConf > DecisionPipeline.value(.coreMLMinConfidence) {
                    // Determine source and target layouts
                    let sourceLayout: Language
                    let targetLanguage = deepHypothesis.targetLanguage
                    
                    switch deepHypothesis {
                    case .ruFromEnLayout, .heFromEnLayout: sourceLayout = .english
                    case .enFromRuLayout, .heFromRuLayout: sourceLayout = .russian
                    case .enFromHeLayout, .ruFromHeLayout: sourceLayout = .hebrew
                    default: sourceLayout = .english
                    }

                    // Reject corrections where the token's dominant script doesn't match the hypothesis source.
                    if let dominant = dominantScriptLanguage(token), dominant != sourceLayout {
                        let rejectedMsg = "REJECTED_SCRIPT: \(deepHypothesis.rawValue) | dominant=\(dominant.rawValue) source=\(sourceLayout.rawValue)"
                        DecisionLogger.shared.log(rejectedMsg)
                        DecisionLogger.shared.logDecision(token: token, path: "DEEP", result: baseline)
                        DecisionProbe.record(.coreML, .rejected, .modelWrongAlphabet, [
                            DecisionProbe.name(deepHypothesis),
                            DecisionProbe.percent(deepConf)
                        ])
                        return baseline
                    }
                    
                    let sourceScore = scoreWithNgram(token, language: sourceLayout)
                    let sourceNorm = scoreWithNgramNormalized(token, language: sourceLayout)

                    let sourceWordConfidence = wordValidator.confidence(for: token, language: sourceLayout)
                    let sourceFreq = frequencyScore(token, language: sourceLayout)

                    func isValidConversion(_ converted: String, targetLanguage: Language) -> Bool {
                        // Known Russian prepositions are always valid
                        if targetLanguage == .russian && knownRussianPrepositions.contains(converted.lowercased()) {
                            return true
                        }
                        
                        let targetWordConfidence = wordValidator.confidence(for: converted, language: targetLanguage)
                        let targetFreq = frequencyScore(converted, language: targetLanguage)
                        let shortLetters = converted.filter { $0.isLetter }.count <= 3
                        if shortLetters {
                            return targetWordConfidence >= thresholds.targetWordMin && targetFreq >= sourceFreq + thresholds.targetFreqMargin
                        }

                        let targetNorm = scoreWithNgramNormalized(converted, language: targetLanguage)

                        DecisionLogger.shared.log("VALID_CHECK: \(converted) wordConf=\(String(format: "%.2f", targetWordConfidence)) srcWordConf=\(String(format: "%.2f", sourceWordConfidence)) tgtNorm=\(String(format: "%.2f", targetNorm)) srcNorm=\(String(format: "%.2f", sourceNorm))")

                        if targetWordConfidence >= thresholds.targetWordMin && targetWordConfidence >= sourceWordConfidence + thresholds.targetWordMargin {
                            return true
                        }

                        if targetFreq >= sourceFreq + thresholds.targetFreqMargin && targetWordConfidence >= thresholds.shortWordFreqMin {
                            return true
                        }

                        // N-grams alone also "like" letter soup; require the target to be a word we
                        // know of at all (0 >= 0 would otherwise pass for unknown source words).
                        return targetNorm >= thresholds.targetNormMin && targetNorm >= sourceNorm + thresholds.targetNormMargin && ((targetFreq > 0 && targetFreq >= sourceFreq) || targetWordConfidence >= thresholds.shortWordFreqMin)
                    }

                    func correctionHypotheses(for sourceLayout: Language) -> [LanguageHypothesis] {
                        let all: [LanguageHypothesis]
                        switch sourceLayout {
                        case .english: all = [.ruFromEnLayout, .heFromEnLayout]
                        case .russian: all = [.enFromRuLayout, .heFromRuLayout]
                        case .hebrew: all = [.enFromHeLayout, .ruFromHeLayout]
                        }
                        return all.filter { $0.isAllowed(in: enabledLanguages) }
                    }

                    struct ValidatedCandidate {
                        let hypothesis: LanguageHypothesis
                        let targetLanguage: Language
                        let converted: String
                        let quality: Double
                    }

                    func bestValidatedCandidate(hypothesis: LanguageHypothesis) -> ValidatedCandidate? {
                        let src: Language
                        let tgt = hypothesis.targetLanguage
                        switch hypothesis {
                        case .ruFromEnLayout, .heFromEnLayout: src = .english
                        case .enFromRuLayout, .heFromRuLayout: src = .russian
                        case .enFromHeLayout, .ruFromHeLayout: src = .hebrew
                        default: return nil
                        }

                        guard let dominant = dominantScriptLanguage(token), dominant == src else { return nil }

                        func consider(_ converted: String) -> ValidatedCandidate? {
                            guard converted != token else { return nil }
                            guard isValidConversion(converted, targetLanguage: tgt) else { return nil }
                            return ValidatedCandidate(
                                hypothesis: hypothesis,
                                targetLanguage: tgt,
                                converted: converted,
                                quality: qualityScore(converted, lang: tgt) + correctionPriorBonus(for: hypothesis)
                            )
                        }

                        // Always check ALL layout variants and pick the best one
                        // This handles cases like Hebrew QWERTY user typing Mac Hebrew patterns
                        let variants = LayoutMapper.shared.convertAllVariants(token, from: src, to: tgt, activeLayouts: activeLayouts)
                        var best: ValidatedCandidate? = nil
                        for (_, converted) in variants {
                            if let cand = consider(converted), (best == nil || cand.quality > best!.quality) {
                                best = cand
                            }
                        }
                        return best
                    }

                    // Cross-check competing correction hypotheses for the same source script.
                    // This reduces cases like RU→EN being mistaken as RU→HE when both conversions look plausible.
                    let correctionCandidates = correctionHypotheses(for: sourceLayout)
                    var validated: [ValidatedCandidate] = []
                    validated.reserveCapacity(correctionCandidates.count)
                    for hyp in correctionCandidates {
                        if let cand = bestValidatedCandidate(hypothesis: hyp) { validated.append(cand) }
                    }

                    if !validated.isEmpty {
                        let bestOverall = validated.max(by: { $0.quality < $1.quality })!
                        let bestIsModel = bestOverall.hypothesis == deepHypothesis

                        // Only override CoreML when the alternative is clearly better.
                        if !bestIsModel {
                            if let modelCand = validated.first(where: { $0.hypothesis == deepHypothesis }) {
                                if bestOverall.quality < modelCand.quality + DecisionPipeline.value(.coreMLOverrideMargin) {
                                    // Not a strong enough reason to override; keep CoreML's choice.
                                    validated = [modelCand]
                                }
                            }
                        }

                        let chosen = validated.max(by: { $0.quality < $1.quality })!
                        let chosenConf = max(deepConf, 0.90)
                        let deepResult = LanguageDecision(
                            language: chosen.targetLanguage,
                            layoutHypothesis: chosen.hypothesis,
                            confidence: chosenConf,
                            scores: [:]
                        )
                        DecisionLogger.shared.log("DEEP_BEST: \(chosen.hypothesis.rawValue) via len=\(chosen.converted.count)")
                        DecisionProbe.record(.coreML, .decided, .modelAccepted, [
                            DecisionProbe.name(chosen.hypothesis),
                            DecisionProbe.percent(chosenConf),
                            chosen.converted
                        ])
                        DecisionLogger.shared.logDecision(token: token, path: "DEEP_CORRECTION", result: deepResult)
                        return deepResult
                    }

                    // Prefer conversion using the user-selected/detected active layouts first.
                    if let primary = LayoutMapper.shared.convertBest(token, from: sourceLayout, to: targetLanguage, activeLayouts: activeLayouts),
                       primary != token,
                       isValidConversion(primary, targetLanguage: targetLanguage) {
                        let deepResult = LanguageDecision(
                            language: targetLanguage,
                            layoutHypothesis: deepHypothesis,
                            confidence: max(deepConf, 0.90),
                            scores: [:]
                        )
                        DecisionLogger.shared.log("VALIDATED_PRIMARY: \(DecisionLogger.tokenSummary(token)) → len=\(primary.count)")
                        DecisionProbe.record(.coreML, .decided, .modelAccepted, [
                            DecisionProbe.name(deepHypothesis),
                            DecisionProbe.percent(deepResult.confidence),
                            primary
                        ])
                        DecisionLogger.shared.logDecision(token: token, path: "DEEP_CORRECTION", result: deepResult)
                        return deepResult
                    }

                    // Fall back to trying ALL source layout variants (handles unknown source variants).
                    let variants = LayoutMapper.shared.convertAllVariants(token, from: sourceLayout, to: targetLanguage, activeLayouts: activeLayouts)
                    var bestConversion: (converted: String, score: Double)? = nil

                    for (layoutId, converted) in variants {
                        let targetScore = scoreWithNgram(converted, language: targetLanguage)
                        let targetNorm = scoreWithNgramNormalized(converted, language: targetLanguage)
                        DecisionLogger.shared.log("VARIANT[\(layoutId)]: \(DecisionLogger.tokenSummary(token)) → len=\(converted.count) | src=\(String(format: "%.2f", sourceScore)) tgt=\(String(format: "%.2f", targetScore)) tgtN=\(String(format: "%.2f", targetNorm))")

                        if isValidConversion(converted, targetLanguage: targetLanguage) {
                            if bestConversion == nil || targetNorm > bestConversion!.score {
                                bestConversion = (converted, targetNorm)
                            }
                        }
                    }
                    
                    if let bestConversion {
                        DecisionProbe.record(.coreML, .decided, .modelAccepted, [
                            DecisionProbe.name(deepHypothesis),
                            DecisionProbe.percent(max(deepConf, 0.85)),
                            bestConversion.converted
                        ])
                        let deepResult = LanguageDecision(
                            language: targetLanguage, 
                            layoutHypothesis: deepHypothesis,
                            confidence: max(deepConf, 0.85),
                            scores: [:] 
                        )
                        DecisionLogger.shared.logDecision(token: token, path: "DEEP_CORRECTION", result: deepResult)
                        return deepResult
                    } else {
                        let rejectedMsg = "REJECTED_VALIDATION: \(deepHypothesis.rawValue) | no valid conversion found from \(variants.count) variants"
                        DecisionLogger.shared.log(rejectedMsg)
                        DecisionProbe.record(.coreML, .rejected, .modelNoWord, [
                            DecisionProbe.name(deepHypothesis),
                            DecisionProbe.percent(deepConf)
                        ])
                    }
                } else {
                    let rejectedMsg = "REJECTED_DEEP_CORRECTION: \(deepHypothesis.rawValue) (\(String(format: "%.2f", deepConf))) < \(DecisionPipeline.value(.coreMLMinConfidence))"
                    DecisionLogger.shared.log(rejectedMsg)
                    DecisionProbe.record(.coreML, .rejected, .modelIgnored, [
                        DecisionProbe.name(deepHypothesis),
                        DecisionProbe.percent(deepConf),
                        DecisionProbe.percent(DecisionPipeline.value(.coreMLMinConfidence))
                    ])
                }
            } else {
                // CoreML just confirms the script (e.g. "ru" for Cyrillic).
                // Only prefer CoreML if it's more confident than baseline.
                if deepConf > baseline.confidence && deepConf > DecisionPipeline.value(.coreMLAsTypedMin) {
                    let deepResult = LanguageDecision(
                        language: deepHypothesis.targetLanguage, 
                        layoutHypothesis: deepHypothesis,
                        confidence: deepConf,
                        scores: [:] 
                    )
                    DecisionLogger.shared.logDecision(token: token, path: "DEEP", result: deepResult)
                    DecisionProbe.record(.coreML, .decided, .modelTypedCorrectly, [
                        DecisionProbe.name(deepHypothesis),
                        DecisionProbe.percent(deepConf)
                    ])
                    return deepResult
                }
                DecisionProbe.record(.coreML, .checked, .modelAgrees, [
                    DecisionProbe.name(deepHypothesis),
                    DecisionProbe.percent(deepConf)
                ])
            }
        }
        
        // -- STEP 2.5: Foundation Model tiebreaker (Ticket 72) --
        // When CoreML didn't find a correction AND baseline confidence is ambiguous,
        // consult Foundation Models as a supplementary signal.
        #if canImport(FoundationModels)
        if #available(macOS 26, *),
           await settings.isFoundationModelEnabled,
           let fm = _foundationModelStorage as? FoundationModelClassifier,
           fm.modelAvailable,
           baseline.confidence < 0.70 && baseline.confidence >= 0.40 {
            logger.info("🤖 Foundation Model tiebreaker: baseline conf=\(baseline.confidence) in ambiguous range")
            DecisionProbe.record(.foundationModel, .checked, .noCorrection)
            if let (fmHyp, fmConf) = await fm.predict(token, context: "") {
                let isCorrection = fmHyp.rawValue.contains("From")
                if isCorrection && fmConf > thresholds.correctionThreshold {
                    // FM proposes a layout correction — validate it like we do for CoreML
                    let sourceLayout: Language
                    let targetLanguage = fmHyp.targetLanguage
                    switch fmHyp {
                    case .ruFromEnLayout, .heFromEnLayout: sourceLayout = .english
                    case .enFromRuLayout, .heFromRuLayout: sourceLayout = .russian
                    case .enFromHeLayout, .ruFromHeLayout: sourceLayout = .hebrew
                    default: sourceLayout = .english
                    }

                    let activeLayouts = await settings.activeLayouts
                    if let converted = LayoutMapper.shared.convertBest(token, from: sourceLayout, to: targetLanguage, activeLayouts: activeLayouts),
                       converted != token {
                        // Quick validation: target must score well
                        let targetWordConf = wordValidator.confidence(for: converted, language: targetLanguage)
                        if targetWordConf >= thresholds.targetWordMin {
                            let fmResult = LanguageDecision(
                                language: targetLanguage,
                                layoutHypothesis: fmHyp,
                                confidence: min(fmConf, 0.85), // Cap FM confidence slightly
                                scores: [:]
                            )
                            DecisionLogger.shared.log("FM_TIEBREAKER: \(fmHyp.rawValue) conf=\(String(format: "%.2f", fmConf)) → \(DecisionLogger.tokenSummary(converted))")
                            DecisionLogger.shared.logDecision(token: token, path: "FM_CORRECTION", result: fmResult)
                            DecisionProbe.record(.foundationModel, .decided, .modelAccepted, [
                                DecisionProbe.name(fmHyp),
                                DecisionProbe.percent(fmResult.confidence),
                                converted
                            ])
                            return fmResult
                        }
                    }
                }
            }
        }
        #endif

        // -- STEP 3: Fall back to baseline --
        // Heuristic correction: if the token looks like gibberish in its dominant script,
        // try layout conversions even when CoreML doesn't propose a `_from_` hypothesis.
        if let heuristic = heuristicCorrection(
            token: token,
            baseline: baseline,
            activeLayouts: activeLayouts,
            enabledLanguages: enabledLanguages
        ) {
            DecisionLogger.shared.logDecision(token: token, path: "HEURISTIC", result: heuristic)
            return heuristic
        }

        DecisionLogger.shared.logDecision(token: token, path: baselinePath, result: baseline)
        return baseline
    }
    
    func checkEarlySwitch(token: String) async -> LanguageDecision? {
        // Ticket 34: Early Layout Switching
        // Only run on tokens of sufficient length
        guard token.count >= thresholds.correction.earlySwitchMinLength else { return nil }
        
        // Only consider if we can clearly identify the dominant script
        guard let dominant = dominantScriptLanguage(token) else { return nil }
        if dominant == .hebrew { return nil } // Skip hebrew for now (complex vowel handling)
        
        // 1. Check if the current script's language model thinks this is garbage
        let currentScore = scoreWithNgramNormalized(token, language: dominant)
        
        // strict "garbage" threshold for established words, but for prefixes we need to be careful
        // A low score on a prefix might just mean it's a rare prefix.
        // However, if it's REALLY low (like consonant cluster 'ghb'), it's a good signal.
        // Update: "ghb" scores 0.76 in English! So we can't be too strict here.
        // We will rely on the MARGIN check later.
        
        // 2. Check alternative hypotheses
        // We only care about layout switching (e.g. ruFromEnLayout)
        let candidates: [LanguageHypothesis]
        switch dominant {
        case .english: candidates = [.ruFromEnLayout, .heFromEnLayout]
        case .russian: candidates = [.enFromRuLayout] // skip hebrew target for safety
        default: return nil
        }
        
        let activeLayouts = await settings.activeLayouts
        let enabledLanguages = await settings.enabledLanguages
        
        for hyp in candidates where hyp.isAllowed(in: enabledLanguages) {
             let target = hyp.targetLanguage
             let source = dominant
             
             // Convert
             guard let converted = LayoutMapper.shared.convertBest(token, from: source, to: target, activeLayouts: activeLayouts),
                   converted != token else { continue }
                   
             // Validate target
             let targetScore = scoreWithNgramNormalized(converted, language: target)
             
             // Dynamic Threshold Logic for Early Switching:
             // 1. If target is VERY confident (>0.95), we accept a smaller improvement over source (margin 0.15).
             //    This captures cases like "ghb" -> "при" (0.95 vs 0.76).
             // 2. If target is CONFIDENT (>0.90), we need a strong improvement (margin 0.30).
             //    This captures "ghbdtn" -> "привет" (0.92 vs 0.48).
             
             var shouldSwitch = false
             if targetScore >= 0.95 {
                 if targetScore > currentScore + 0.15 { shouldSwitch = true }
             } else if targetScore >= 0.90 {
                 if targetScore > currentScore + 0.30 { shouldSwitch = true }
             }
             
             if shouldSwitch {
                  logger.info("🚀 EARLY SWITCH: \(token) -> \(converted) (\(hyp.rawValue)) (src=\(currentScore), tgt=\(targetScore))")
                  DecisionLogger.shared.logDecision(token: token, path: "EARLY_SWITCH", result: LanguageDecision(
                      language: target,
                      layoutHypothesis: hyp,
                      confidence: 1.0,
                      scores: [:]
                  ))
                  return LanguageDecision(
                      language: target,
                      layoutHypothesis: hyp,
                      confidence: 1.0, // Force accept
                      scores: [:]
                  )
             }
         }
        
        return nil
    }

    private func checkFastPath(_ text: String) -> LanguageDecision? {
        // Avoid Fast Path if script is mixed (fast path is only for "already-correct" text).
        guard let dominant = dominantScriptLanguage(text) else { return nil }
        if dominant == .hebrew { return nil }

        // Quick scoring against 3 languages
        let sRu = ruModel?.score(text) ?? -100
        let sEn = enModel?.score(text) ?? -100
        let sHe = heModel?.score(text) ?? -100
        
        // Convert log-probs to approximate confidence/probability
        // This is a simplified Softmax-like logic for 3 classes
        let scores = [sRu, sEn, sHe]
        let maxScore = scores.max() ?? -100
        
        // If max score is very low (garbage), ignore
        if maxScore < -8.0 { return nil }
        
        var bestLang: Language = .english
        var bestScore = sEn
        
        if sRu > bestScore { bestLang = .russian; bestScore = sRu }
        if sHe > bestScore { bestLang = .hebrew; bestScore = sHe }
        
        // Simple margin confidence
        // Find second best
        let sorted = scores.sorted(by: >)
        let margin = sorted[0] - sorted[1]
        
        // Heuristic mapping: margin 0.0 -> 0.5, margin 2.0 -> 0.9 approximately
        var confidence = min(1.0, 0.5 + Double(margin) * 0.2)

        // Only accept fast-path when the best language matches dominant script
        // AND the token looks like a real word/phrase in that language.
        if bestLang != dominant { return nil }
        let wordConf = wordValidator.confidence(for: text, language: bestLang)
        if wordConf < 0.80 {
            // Downweight and decline Fast Path; let Ensemble/CoreML handle it.
            confidence *= 0.5
            return nil
        }
        
        return LanguageDecision(
            language: bestLang,
            layoutHypothesis: bestLang.asHypothesis,
            confidence: confidence,
            scores: [
                .ru: Double(sRu),
                .en: Double(sEn),
                .he: Double(sHe)
            ]
        )
    }

    private func tokenKind(for token: String) -> DecisionTokenKind {
        if isTechnicalToken(token) {
            return .technical
        }

        var latin = false
        var cyrillic = false
        var hebrew = false
        for scalar in token.unicodeScalars {
            switch scalar.value {
            case 0x0041...0x005A, 0x0061...0x007A:
                latin = true
            case 0x0400...0x04FF:
                cyrillic = true
            case 0x0590...0x05FF:
                hebrew = true
            default:
                continue
            }
        }

        let scripts = [latin, cyrillic, hebrew].filter { $0 }.count
        if scripts >= 2 {
            return .mixed
        }

        let letters = token.filter(\.isLetter)
        if token.contains(where: { !$0.isLetter && !$0.isWhitespace }) {
            return .punctuated
        }

        if letters.count <= 3 {
            return .short
        }

        return .plain
    }

    private func convertedText(
        for token: String,
        decision: LanguageDecision,
        activeLayouts: [String: String]
    ) -> String {
        guard let source = sourceLayout(for: decision.layoutHypothesis) else {
            return token
        }

        return LayoutMapper.shared.convertBest(
            token,
            from: source,
            to: decision.language,
            activeLayouts: activeLayouts
        ) ?? token
    }

    private func sourceLayout(for hypothesis: LanguageHypothesis) -> Language? {
        switch hypothesis {
        case .ruFromEnLayout, .heFromEnLayout:
            return .english
        case .enFromRuLayout, .heFromRuLayout:
            return .russian
        case .enFromHeLayout, .ruFromHeLayout:
            return .hebrew
        case .ru, .en, .he:
            return nil
        }
    }
    
    /// Score text against a specific language's N-gram model
    private func scoreWithNgram(_ text: String, language: Language) -> Double {
        let model: NgramLanguageModel?
        switch language {
        case .russian: model = ruModel
        case .english: model = enModel
        case .hebrew: model = heModel
        }
        return Double(model?.score(text) ?? -100.0)
    }

    private func scoreWithNgramNormalized(_ text: String, language: Language) -> Double {
        let model: NgramLanguageModel?
        switch language {
        case .russian: model = ruModel
        case .english: model = enModel
        case .hebrew: model = heModel
        }
        return model?.normalizedScore(text) ?? 0.0
    }

    private func unigramModel(for language: Language) -> WordFrequencyModel? {
        if let cached = unigramCache[language] { return cached }
        let code: String
        switch language {
        case .english: code = "en"
        case .russian: code = "ru"
        case .hebrew: code = "he"
        }
        guard let model = WordFrequencyModel.shared(code) else { return nil }
        unigramCache[language] = model
        return model
    }

    private func frequencyScore(_ text: String, language: Language) -> Double {
        guard let model = unigramModel(for: language) else { return 0.0 }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return 0.0 }

        let words = trimmed
            .split(whereSeparator: { !$0.isLetter })
            .map { String($0).lowercased() }
            .filter { !$0.isEmpty }

        guard !words.isEmpty else { return 0.0 }
        let sum = words.reduce(0.0) { $0 + model.score($1) }
        return sum / Double(words.count)
    }

    private func dominantScriptLanguage(_ text: String) -> Language? {
        var latin = 0
        var cyr = 0
        var heb = 0

        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x0041...0x005A, 0x0061...0x007A:
                latin += 1
            case 0x0400...0x04FF:
                cyr += 1
            case 0x0590...0x05FF:
                heb += 1
            default:
                continue
            }
        }

        let total = latin + cyr + heb
        guard total > 0 else { return nil }

        let best = max(latin, cyr, heb)
        if Double(best) / Double(total) < 0.85 { return nil }

        if best == cyr { return .russian }
        if best == heb { return .hebrew }
        return .english
    }

    private func validateCorrection(
        token: String,
        hypothesis: LanguageHypothesis,
        confidence: Double,
        activeLayouts: [String: String]
    ) -> LanguageDecision? {
        guard hypothesis.rawValue.contains("_from_") else { return nil }

        let targetLanguage = hypothesis.targetLanguage
        let sourceLayout: Language
        switch hypothesis {
        case .ruFromEnLayout, .heFromEnLayout: sourceLayout = .english
        case .enFromRuLayout, .heFromRuLayout: sourceLayout = .russian
        case .enFromHeLayout, .ruFromHeLayout: sourceLayout = .hebrew
        default: sourceLayout = .english
        }

        // Script gate: if the token clearly belongs to a different script than the hypothesis source,
        // reject to avoid false positives (e.g. valid English with punctuation being "corrected" as en_from_he).
        if let dominant = dominantScriptLanguage(token), dominant != sourceLayout {
            return nil
        }

        // Check all layout variants to give the hypothesis the best chance of validation
        // (Ticket 64: Handles layout variants like RussianWin vs Russian Mac correctly)
        let variants = LayoutMapper.shared.convertAllVariants(token, from: sourceLayout, to: targetLanguage, activeLayouts: activeLayouts)
        
        var bestConverted: String? = nil
        var bestScore: Double = -1.0
        
        // Find best variant
        for (_, val) in variants {
             let hit = knownRussianPrepositions.contains(val.lowercased()) ? 1.0 : 0.0
             let builtin = builtinValidator.confidence(for: val, language: targetLanguage)
             let score = max(hit, builtin)
             if score > bestScore {
                 bestScore = score
                 bestConverted = val
             } else if score == bestScore && bestConverted == nil {
                 bestConverted = val
             }
        }
        
        guard let converted = bestConverted, converted != token else { return nil }

        // Known Russian prepositions are always valid
        if targetLanguage == .russian && knownRussianPrepositions.contains(converted.lowercased()) {
            return LanguageDecision(language: targetLanguage, layoutHypothesis: hypothesis, confidence: max(confidence, 0.90), scores: [:])
        }

        let sourceWord = wordValidator.confidence(for: token, language: sourceLayout)
        let targetWord = wordValidator.confidence(for: converted, language: targetLanguage)

        let sourceNorm = scoreWithNgramNormalized(token, language: sourceLayout)
        let targetNorm = scoreWithNgramNormalized(converted, language: targetLanguage)

        let sourceFreq = frequencyScore(token, language: sourceLayout)
        let targetFreq = frequencyScore(converted, language: targetLanguage)

        let letterCount = token.filter { $0.isLetter }.count
        let isShort = letterCount <= 3

        let sourceBuiltin = builtinValidator.confidence(for: token, language: sourceLayout)
        let targetBuiltin = builtinValidator.confidence(for: converted, language: targetLanguage)

        // Strong accept: target looks like real text and source looks like gibberish.
        if targetBuiltin >= 0.99 && sourceBuiltin <= 0.01 {
            return LanguageDecision(language: targetLanguage, layoutHypothesis: hypothesis, confidence: max(confidence, 0.90), scores: [:])
        }

        if targetWord >= thresholds.targetWordMin && (targetWord >= sourceWord + thresholds.targetWordMargin || targetFreq >= sourceFreq + thresholds.targetWordMargin) {
            return LanguageDecision(language: targetLanguage, layoutHypothesis: hypothesis, confidence: max(confidence, 0.85), scores: [:])
        }

        // For very short tokens, require a strong unigram-frequency improvement
        if isShort, targetFreq >= 0.45, targetFreq >= sourceFreq + thresholds.targetFreqMargin {
            return LanguageDecision(language: targetLanguage, layoutHypothesis: hypothesis, confidence: max(confidence, 0.85), scores: [:])
        }

        // Fallback: accept when n-gram quality improves significantly
        if targetNorm >= thresholds.targetNormMin && targetNorm >= sourceNorm + thresholds.targetNormMargin && ((targetFreq > 0 && targetFreq >= sourceFreq) || targetWord >= thresholds.shortWordFreqMin) {
            return LanguageDecision(language: targetLanguage, layoutHypothesis: hypothesis, confidence: max(confidence, 0.80), scores: [:])
        }

        return nil
    }

    private func heuristicCorrection(
        token: String,
        baseline: LanguageDecision,
        activeLayouts: [String: String],
        enabledLanguages: Set<Language>
    ) -> LanguageDecision? {
        guard DecisionPipeline.isEnabled(.heuristic),
              let dominant = dominantScriptLanguage(token) else { return nil }

        // If the token already looks like a valid word/phrase in its dominant script,
        // don't attempt layout correction (avoid false positives).
        let sourceWord = wordValidator.confidence(for: token, language: dominant)
        if sourceWord >= DecisionPipeline.value(.heuristicSourceWordMax) {
            DecisionProbe.record(.heuristic, .checked, .typedWordIsWord, [DecisionProbe.percent(sourceWord)])
            return nil
        }

        let candidates: [LanguageHypothesis]
        switch dominant {
        case .english:
            candidates = [.ruFromEnLayout, .heFromEnLayout]
        case .russian:
            // Prioritize en over he - typing Hebrew on Russian layout is very rare
            candidates = [.enFromRuLayout]
        case .hebrew:
            // Prioritize en over ru - typing Russian on Hebrew layout is rare
            candidates = [.enFromHeLayout, .ruFromHeLayout]
        }

        let baseConf = max(thresholds.baseConfMin, baseline.confidence)
        
        // FIX: Check ALL candidates.
        // If multiple candidates validate, falls back to `scoredDecision` (return nil)
        // to ensure we pick the best one using full quality scoring.
        // If only one validates, return it (Fast Path).
        var validDecisions: [LanguageDecision] = []

        for hyp in candidates where hyp.isAllowed(in: enabledLanguages) {
            if let validated = validateCorrection(token: token, hypothesis: hyp, confidence: baseConf, activeLayouts: activeLayouts) {
                validDecisions.append(validated)
            }
        }
        
        if validDecisions.count == 1, let only = validDecisions.first {
            DecisionProbe.record(.heuristic, .decided, .onlyWordConversion, [DecisionProbe.name(only.layoutHypothesis)])
            return only
        }
        DecisionProbe.record(.heuristic, .checked, .noSingleConversion)
        
        // If 0 or >1, let the standard path handle it (ambiguity resolution)
        return nil
    }

    private func qualityScore(_ text: String, lang: Language) -> Double {
        let letters = text.filter { $0.isLetter }
        let isShort = letters.count <= 3

        let w = wordValidator.confidence(for: text, language: lang)
        let n = isShort ? 0.0 : scoreWithNgramNormalized(text, language: lang)
        let f = frequencyScore(text, language: lang)

        return (isShort ? 1.6 : 1.2) * w + (isShort ? 1.6 : 1.0) * f + (isShort ? 0.0 : 0.6) * n
    }

    private func correctionPriorBonus(for hypothesis: LanguageHypothesis) -> Double {
        // Priors to reduce rare/undesired corrections in ambiguous cases.
        // These are deliberately small; they shouldn't override strong evidence.
        switch hypothesis {
        case .heFromRuLayout:
            return -0.28 // RU→HE is rarer than RU→EN for Cyrillic gibberish.
        case .ruFromHeLayout:
            return 0.06 // Encourage HE→RU when Russian looks strong.
        case .enFromHeLayout:
            return 0.08 // Hebrew-QWERTY collisions: prefer EN.
        default:
            return 0.0
        }
    }

    private func endsWithHebrewNonFinalForm(_ text: String) -> Bool {
        guard let last = text.trimmingCharacters(in: .whitespacesAndNewlines).last else { return false }
        // Final forms: ך ם ן ף ץ. If a word ends with the non-final form (כ מ נ פ צ),
        // it's often an artefact of layout mapping.
        return ["כ", "מ", "נ", "פ", "צ"].contains(String(last))
    }

    /// `converted` with every "." or "," that sits between two letters of `token` put back,
    /// or nil when there is no such separator (or the conversion changed the length).
    private func keepingSeparators(of token: String, in converted: String) -> String? {
        let original = Array(token)
        var result = Array(converted)
        guard original.count == result.count, original.count >= 3 else { return nil }
        var changed = false
        for i in 1..<(original.count - 1) where original[i] == "." || original[i] == "," {
            guard original[i - 1].isLetter, original[i + 1].isLetter, result[i] != original[i] else { continue }
            result[i] = original[i]
            changed = true
        }
        return changed ? String(result) : nil
    }

    private func scoredDecision(
        token: String,
        activeLayouts: [String: String],
        mode: DetectionMode,
        enabledLanguages: Set<Language>
    ) -> LanguageDecision? {
        guard DecisionPipeline.isEnabled(.scoredDecision) else { return nil }

        // Tuning constants for scored decision
        let correctionBias = 0.05         // Small bias against corrections to avoid false positives
        let russianPunctBoost = 0.35      // Boost for RU tokens containing comma/dot mapped as letters
        let hebrewCommonWordBoost = 0.45  // Boost for well-known Hebrew short words
        let ngramTiebreakMargin = 0.3     // N-gram difference required to override Q-score tie

        // Best "as-is" quality across languages.
        let asIsRu = qualityScore(token, lang: .russian)
        let asIsEn = qualityScore(token, lang: .english)
        let asIsHe = qualityScore(token, lang: .hebrew)
        let bestAsIs = max(asIsRu, asIsEn, asIsHe)

        struct Candidate {
            let hypothesis: LanguageHypothesis
            let target: Language
            let converted: String
            let targetWord: Double
            let targetFreq: Double
            let q: Double
            let n: Double // Normalized N-gram score
            let isWhitelisted: Bool
            let isStrongAccept: Bool
        }

        let mapped: [(LanguageHypothesis, Language, Language)] = [
            (.ruFromEnLayout, .english, .russian),
            (.heFromEnLayout, .english, .hebrew),
            (.enFromRuLayout, .russian, .english),
            (.heFromRuLayout, .russian, .hebrew),
            (.enFromHeLayout, .hebrew, .english),
            (.ruFromHeLayout, .hebrew, .russian),
        ]

        let dominant = dominantScriptLanguage(token)

        var best: Candidate? = nil
        for (hyp, source, target) in mapped where hyp.isAllowed(in: enabledLanguages) {
            // Script gate: don't consider hypotheses whose source script doesn't match the token.
            // This prevents false positives for already-correct text with punctuation (e.g. "how,what").
            if let dominant, dominant != source { continue }

            // Try ALL target layout variants to handle cases like Hebrew QWERTY user typing Mac Hebrew patterns
            let variants = LayoutMapper.shared.convertAllVariants(token, from: source, to: target, activeLayouts: activeLayouts)
            // "." and "," between two words may be separators rather than mapped letters
            // ("ghbdtn.rfr" is "привет.как", not "приветюкак"), so also score each
            // conversion with them kept as typed.
            var readings: [String] = []
            for variant in variants {
                for reading in [variant.result, keepingSeparators(of: token, in: variant.result)] {
                    if let reading, !readings.contains(reading) { readings.append(reading) }
                }
            }
            for converted in readings {
                guard converted != token else { continue }
                let targetWord = wordValidator.confidence(for: converted, language: target)
                let targetFreq = frequencyScore(converted, language: target)
                let targetN = scoreWithNgramNormalized(converted, language: target)
                
                let qRaw = qualityScore(converted, lang: target) - correctionBias + correctionPriorBonus(for: hyp)
                var q = qRaw

                // This handles cases like "hf,jnftn" -> "работает" where comma maps to 'б' or 'ю'.
                if target == .russian && (token.contains(",") || token.contains(".")) {
                    if targetWord >= thresholds.targetWordMin || targetFreq >= 0.1 {
                        q += russianPunctBoost
                    }
                }
                
                // FIX: Boost confidence for common Hebrew words to enable EN→HE/RU→HE detection.
                // This handles cases like "wloM" -> "שלום", "kt" -> "לא", "fi" -> "כן" etc.
                if target == .hebrew {
                    if languageData.hebrewCommonShortWords.contains(converted) {
                        q += hebrewCommonWordBoost
                    }
                }

                let whitelisted = languageData.isWhitelisted(converted, language: target)
                let sourceBuiltin = builtinValidator.confidence(for: token, language: source)
                let targetBuiltin = builtinValidator.confidence(for: converted, language: target)
                
                // Determine if this is a Strong Accept (e.g. system dictionary word)
                let strong = targetBuiltin >= 0.99 && sourceBuiltin <= 0.01
                
                let cand = Candidate(
                    hypothesis: hyp, target: target, converted: converted, 
                    targetWord: targetWord, targetFreq: targetFreq, q: q, 
                    n: targetN,
                    isWhitelisted: whitelisted, isStrongAccept: strong
                )
                
                
                if best == nil {
                    best = cand
                } else {
                    // Selection Logic:
                    // 1. Strong Accept beats non-Strong
                    if cand.isStrongAccept && !best!.isStrongAccept {
                        best = cand
                    } else if !cand.isStrongAccept && best!.isStrongAccept {
                        // keep best
                    } else if cand.isStrongAccept && best!.isStrongAccept {
                        // Both Strong: Tie-break with N-gram if Q is close.
                        if cand.n > best!.n + ngramTiebreakMargin {
                             best = cand
                        } else if best!.n > cand.n + ngramTiebreakMargin {
                             // keep best
                        } else {
                             // Fallback to Q (prior)
                             if cand.q > best!.q { best = cand }
                        }
                    } else {
                        // Both weak: use Quality Score
                        if cand.q > best!.q { best = cand }
                    }
                }
            }
        }

        guard let best else {
            DecisionProbe.record(.scoredDecision, .checked, .scoredNothing)
            return nil
        }

        // Collision handler for Hebrew-QWERTY: the typed Hebrew token can be a valid Hebrew word,
        // but the mapped EN/RU candidate is also a very plausible, high-frequency word.
        if dominant == .hebrew, best.hypothesis == .enFromHeLayout || best.hypothesis == .ruFromHeLayout {
            let srcWord = wordValidator.confidence(for: token, language: .hebrew)
            let srcFreq = frequencyScore(token, language: .hebrew)
            let srcBuiltin = builtinValidator.confidence(for: token, language: .hebrew)

            let letterCount = token.filter { $0.isLetter }.count
            let isShort = letterCount <= 4

            // If the mapped candidate is whitelisted in the target language, allow correction even when the
            // source is a valid Hebrew word (this captures a lot of slang/abbreviations).
            // In automatic mode, avoid overriding very common/strong Hebrew words to reduce false positives.
            if best.isWhitelisted {
                let strongHebrew = (srcBuiltin >= 0.99) || (srcWord >= 0.95 && srcFreq >= 0.55)
                if mode == .automatic, strongHebrew {
                    // Fall through to the regular margin-based logic.
                } else {
                    let conf: Double = mode == .manual ? 0.95 : 0.85
                    DecisionProbe.record(.scoredDecision, .contributed, .scoredHebrewKeys, [best.converted, DecisionProbe.name(best.hypothesis)])
                    return LanguageDecision(language: best.target, layoutHypothesis: best.hypothesis, confidence: conf, scores: [:])
                }
            }

            // For auto mode: require very strong target evidence + clear frequency advantage.
            // For manual mode: be a bit more permissive.
            let minTargetWord = mode == .manual ? 0.90 : 0.90
            let minTargetFreq = mode == .manual ? 0.25 : 0.25
            let minFreqGain = mode == .manual ? 0.08 : 0.10

            let sourceLooksIntentionallyHebrew = srcBuiltin >= 0.99 && srcWord >= 0.95

            // FIX: If target is Strong Accept (System Dictionary) and Source is Garbage,
            // we accept it regardless of Frequency Model (which might be sparse/missing).
            if best.isStrongAccept && !sourceLooksIntentionallyHebrew {
                 DecisionProbe.record(.scoredDecision, .contributed, .scoredHebrewKeys, [best.converted, DecisionProbe.name(best.hypothesis)])
                 return LanguageDecision(language: best.target, layoutHypothesis: best.hypothesis, confidence: 0.95, scores: [:])
            }
            let sourceHasFinalArtefact = endsWithHebrewNonFinalForm(token)

            if !sourceLooksIntentionallyHebrew,
               best.targetWord >= minTargetWord,
               best.targetFreq >= minTargetFreq,
               best.targetFreq >= srcFreq + minFreqGain,
               (isShort || sourceHasFinalArtefact || srcWord < 0.90) {
                let conf: Double = mode == .manual ? 0.90 : 0.82
                DecisionProbe.record(.scoredDecision, .contributed, .scoredHebrewKeys, [best.converted, DecisionProbe.name(best.hypothesis)])
                return LanguageDecision(language: best.target, layoutHypothesis: best.hypothesis, confidence: conf, scores: [:])
            }
        }

        // Only accept if the best mapped hypothesis is substantially better than any as-is option.
        let letterCount = token.filter { $0.isLetter }.count
        var requiredMargin = letterCount <= 3
            ? DecisionPipeline.value(.scoredShortMargin)
            : DecisionPipeline.value(.scoredLongMargin)
        if dominant == .hebrew {
            requiredMargin = letterCount <= 3 ? 0.10 : max(0.25, requiredMargin - 0.40)
        }
        if dominant == .hebrew, endsWithHebrewNonFinalForm(token) {
            // Reduce the barrier a bit: Hebrew words ending in non-final forms are often mapping artefacts.
            requiredMargin = max(0.10, requiredMargin - 0.10)
        }
        
        guard best.q >= bestAsIs + requiredMargin else {
            // Say what makes the word as typed score so high ("Lf" is an English word to
            // the spell checker), or the refusal can't be understood.
            let asIsLanguage = [(Language.russian, asIsRu), (.english, asIsEn), (.hebrew, asIsHe)]
                .max { $0.1 < $1.1 }?.0 ?? .english
            DecisionProbe.record(.scoredDecision, .checked, .scoredNotEnough, [
                best.converted,
                DecisionProbe.name(best.hypothesis),
                DecisionProbe.number(best.q),
                DecisionProbe.number(bestAsIs + requiredMargin),
                token,
                DecisionProbe.number(bestAsIs),
                DecisionProbe.name(asIsLanguage),
                DecisionProbe.percent(wordValidator.confidence(for: token, language: asIsLanguage))
            ])
            return nil
        }
        guard best.targetWord >= DecisionPipeline.value(.scoredTargetWordMin) else {
            DecisionProbe.record(.scoredDecision, .checked, .scoredNotAWord, [
                best.converted,
                DecisionProbe.percent(best.targetWord),
                DecisionProbe.percent(DecisionPipeline.value(.scoredTargetWordMin))
            ])
            return nil
        }
        DecisionProbe.record(.scoredDecision, .contributed, .scoredBest, [
            best.converted,
            DecisionProbe.name(best.hypothesis),
            DecisionProbe.number(best.q),
            DecisionProbe.number(bestAsIs),
            DecisionProbe.number(requiredMargin)
        ])

        logger.debug("📊 scoredDecision: '\(token)' → '\(best.converted)' [\(best.hypothesis.rawValue)] q=\(best.q, format: .fixed(precision: 2)) asIs=\(bestAsIs, format: .fixed(precision: 2)) margin=\(requiredMargin, format: .fixed(precision: 2)) strong=\(best.isStrongAccept)")

        return LanguageDecision(language: best.target, layoutHypothesis: best.hypothesis, confidence: 0.95, scores: [:])
    }

    nonisolated func isTechnicalToken(_ token: String) -> Bool {
        guard !token.isEmpty, DecisionPipeline.isEnabled(.technicalTokenGuard) else { return false }

        // Common file extensions (keep these tokens as-is in automatic mode).
        // This intentionally excludes arbitrary one-letter "extensions" to avoid blocking
        // punctuation-as-letter corrections like `epyf.n` → `узнают`.
        let commonExtensions: Set<String> = [
            // docs/config
            "md", "txt", "rtf", "pdf", "json", "yaml", "yml", "toml", "ini", "conf", "plist", "xml", "csv", "log",
            // source (excluding "kt" as it conflicts with Hebrew word לא)
            "swift", "m", "mm", "c", "h", "cpp", "hpp", "cc", "hh", "rs", "go", "java", "py", "js", "ts", "tsx", "jsx", "html", "css", "scss",
            // archives/binaries
            "zip", "gz", "bz2", "xz", "7z", "dmg", "pkg", "app"
        ]
        
        if commonExtensions.contains(token.lowercased()) {
             return true
        }

        // Unix-like paths
        if token.hasPrefix("/"), token.contains("/") {
            return true
        }

        // Windows paths: C:\... or C:/...
        if token.count >= 3 {
            let chars = Array(token)
            if chars[1] == ":", (chars[2] == "\\" || chars[2] == "/"), chars[0].isLetter {
                return true
            }
        }

        // UUID (xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx)
        if Self.isUUID(token) { return true }
        
        // Ticket 48: Dashless UUID (32 hex chars)
        if token.count == 32, token.allSatisfy({ $0.isHexDigit }) {
            // High chance of being a UUID/Hash if completely hex
            return true
        }
        
        // Ticket 48: Git Hash (7-40 hex chars)
        // Policy: Require at least one digit to distinguish from English words like "defaced".
        // Purely alphabetic hex strings are left to the language detection pipeline.
        if token.count >= 7 && token.count <= 40 && token.allSatisfy({ $0.isHexDigit }) {
             if token.rangeOfCharacter(from: .decimalDigits) != nil {
                 return true
             }
        }

        // Semver-like tokens: v1.2.3, 1.2.3, 1.2
        if Self.isSemver(token) { return true }
        
        // Ticket 48: Base64
        // Heuristic: Alphanumeric + "/" + "+" and ends with "=" (often).
        if token.hasSuffix("=") {
             let body = token.dropLast(token.hasSuffix("==") ? 2 : 1)
             // Check valid base64 chars
             if body.count > 6 && body.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "+" || $0 == "/" || $0 == "_" || $0 == "-" }) {
                 return true
             }
        }

        // Numeric tokens with punctuation (times/dates/percents/etc): 15:00, 2026-01-01, 99.9%, 1/2
        // Only protect if there are no letters at all.
        let digitCount = token.filter { $0.isNumber }.count
        if digitCount > 0 {
            let letterCount = token.filter { $0.isLetter }.count
            if letterCount == 0 {
                let allowed = Set("0123456789:+-/%.,")
                if token.allSatisfy({ ch in
                    ch.isNumber || allowed.contains(ch)
                }) {
                    // Require at least one non-digit separator, otherwise "12345" can still be handled normally.
                    if token.contains(where: { !$0.isNumber }) {
                        return true
                    }
                }
            }
        }

        // Simple filename.ext (no path separators)
        if !token.contains("/") && !token.contains("\\"),
           let dot = token.lastIndex(of: "."),
           dot != token.startIndex,
           dot != token.index(before: token.endIndex) {
            let ext = token[token.index(after: dot)...]
            let extLower = ext.lowercased()
            if extLower.count <= 8,
               extLower.allSatisfy({ $0.isLetter || $0.isNumber }),
               commonExtensions.contains(extLower) {
                let base = token[..<dot]
                if base.contains(where: { $0.isLetter }) {
                    return true
                }
            }
        }

        return false
    }

    nonisolated private static func isUUID(_ token: String) -> Bool {
        let chars = Array(token.lowercased())
        guard chars.count == 36 else { return false }
        let dashIdx: Set<Int> = [8, 13, 18, 23]
        for (i, ch) in chars.enumerated() {
            if dashIdx.contains(i) {
                if ch != "-" { return false }
                continue
            }
            let isHex = (ch >= "0" && ch <= "9") || (ch >= "a" && ch <= "f")
            if !isHex { return false }
        }
        return true
    }

    nonisolated private static func isSemver(_ token: String) -> Bool {
        var s = token
        if s.hasPrefix("v") || s.hasPrefix("V") {
            s.removeFirst()
        }
        let parts = s.split(separator: ".")
        guard parts.count >= 2, parts.count <= 4 else { return false }
        guard parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }) else { return false }
        return true
    }
}

// Helper types
extension Language {
    var asHypothesis: LanguageHypothesis {
        switch self {
        case .russian: return .ru
        case .english: return .en
        case .hebrew: return .he
        }
    }
}

/// Context passed to the router
struct DetectorContext: Sendable {
    let lastLanguage: Language?
}

/// Unified decision type (aliasing existing one or wrapping it)
/// For now, we reuse LanguageDecision from LanguageEnsemble.swift
// Note: LanguageDecision is defined there.
