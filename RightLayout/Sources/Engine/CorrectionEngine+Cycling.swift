import Foundation
import AppKit

// MARK: - Hotkey Cycling & Manual Correction

extension CorrectionEngine {

    // MARK: - Hotkey Entry Point

    /// Called by EventMonitor when hotkey is pressed to prepare cycling state
    func processHotkeyCorrection(text: String, bundleId: String) async {
        logger.info("🎯 processHotkeyCorrection called for '\(DecisionLogger.tokenSummary(text), privacy: .public)'")
        // `correctLastWord` advances to the first visible alternative. The
        // event-monitor/manual tests expect `processHotkeyCorrection` to only
        // prepare state, leaving the first `cycleCorrection()` call to surface
        // the first candidate.
        _ = await correctLastWord(text, bundleId: bundleId)
        if var state = cyclingState, state.isValid {
            state.currentIndex = 0
            cyclingState = state
        }
    }

    // MARK: - Build Cycling Alternatives

    func correctLastWord(_ text: String, bundleId: String? = nil) async -> String? {
        logger.info("🔥 === MANUAL CORRECTION (HOTKEY) ===")
        logger.info("Input: \(DecisionLogger.tokenSummary(text), privacy: .public)")
        
        guard !text.isEmpty else {
            logger.warning("❌ Empty text provided")
            return nil
        }
        
        // Note: cycling is now managed by EventMonitor, not here
        // This function always creates fresh alternatives
        
        let activeLayouts = await settings.activeLayouts
        
        // Try smart per-segment correction first
        let smartCorrected = await correctPerSegment(text, activeLayouts: activeLayouts)
        
        // Build alternatives with "undo-first" semantics:
        // [0] = original (undo target)
        // [1] = primary whole-text correction for dominant hypothesis (if available)
        // [2] = smart per-segment correction (if available)
        // [3+] = other whole-text conversions
        
        var alternatives: [CyclingContext.Alternative] = []
        
        // Detect what the text likely is (for whole-text fallback)
        let decision = await router.route(token: text, context: DetectorContext(lastLanguage: nil), mode: .manual)
        
        // [0] Original text (undo target)
        alternatives.append(CyclingContext.Alternative(text: text, hypothesis: decision.layoutHypothesis))

        // Generate whole-text conversions. We'll pick the most plausible one as the primary correction
        // for the first hotkey press (round 1), then keep the rest for cycling.
        let conversions = LanguageMappingsConfig.shared.languageConversions

        var candidates: [(text: String, hyp: LanguageHypothesis, quality: Double, bonus: Double)] = []
        candidates.reserveCapacity(conversions.count)
        
        // Smart correction (per-segment) integration
        if let smart = smartCorrected, smart != text {
             // Treat smart correction as a high-quality candidate
             candidates.append((text: smart, hyp: decision.layoutHypothesis, quality: 1.0, bonus: 0.5))
        }

        var seen = Set<String>()
        seen.insert(text)
        if let smart = smartCorrected { seen.insert(smart) }

        let enabled = await settings.enabledLanguages
        for (from, to) in conversions where enabled.contains(from) && enabled.contains(to) {
            let hyp = hypothesisFor(source: from, target: to)
            let converted: String
            if let mixed = convertWrongLayoutPart(of: text, from: from, to: to, activeLayouts: activeLayouts) {
                guard mixed != text, seen.insert(mixed).inserted else { continue }
                converted = mixed
            } else {
                let variants = LayoutMapper.shared.convertAllVariants(text, from: from, to: to, activeLayouts: activeLayouts)
                guard let whole = variants.lazy.map(\.result).first(where: { candidate in
                    candidate != text && seen.insert(candidate).inserted
                }) else {
                    continue
                }
                converted = whole
            }

            // Pick best-looking output by lightweight scoring. This strongly prefers real words
            // like "привет" over script-consistent but meaningless strings like "עינגאמ".
            let quality = fastTextScore(converted)
            let bonus = (hyp == decision.layoutHypothesis) ? 0.20 : 0.0
            candidates.append((text: converted, hyp: hyp, quality: quality, bonus: bonus))
        }

        // MANUAL FLOW: User pressed Alt. They want a correction.
        // We want the unified order: [Original, Best Candidate, 2nd Best...]
        
        var finalCandidates: [CyclingContext.Alternative] = []
        
        // 0. Original
        finalCandidates.append(CyclingContext.Alternative(text: text, hypothesis: nil))

        // An abbreviation or emoticon in the wrong layout ("n/r/", "Ж-)") is what was meant.
        if let shorthand = WrongLayoutShorthand.match(text, enabledLanguages: enabled, activeLayouts: activeLayouts) {
            let hypothesis = WrongLayoutShorthand.isEmoticon(shorthand.text)
                ? nil
                : hypothesisFor(source: shorthand.from, target: shorthand.to)
            finalCandidates.append(CyclingContext.Alternative(text: shorthand.text, hypothesis: hypothesis))
        }

        // 1. Add Smart Correction if available (High confidence)
        if let smart = smartCorrected, smart != text {
            finalCandidates.append(CyclingContext.Alternative(text: smart, hypothesis: decision.layoutHypothesis))
        }
        
        // 2. Add Whole-text conversions (High quality first)
        let sortedCandidates = candidates.sorted(by: { ($0.quality + $0.bonus) > ($1.quality + $1.bonus) })
        for cand in sortedCandidates {
            // Avoid duplicates
            if !finalCandidates.contains(where: { $0.text == cand.text }) && cand.text != text {
                finalCandidates.append(CyclingContext.Alternative(text: cand.text, hypothesis: cand.hyp))
            }
        }
        
        if finalCandidates.count <= 1 {
            logger.warning("❌ No conversions possible for: \(text)")
            return nil
        }
        
        // Initial state logic:
        // Start at 0, first cycleCorrection() will bump to 1 (Best)
        
        cyclingState = CyclingContext(
            originalText: text,
            alternatives: finalCandidates,
            currentIndex: 0, 
            wasAutomatic: false, 
            autoHypothesis: decision.layoutHypothesis,
            timestamp: Date(),
            trailingSeparator: "",
            visibleAlternativesCount: min(finalCandidates.count, ThresholdsConfig.shared.correction.visibleAlternativesRound1),
            cycleCount: 0
        )
        
        logger.info("🔄 Built \(finalCandidates.count) alternatives for Manual Cycle (Best -> Others -> Original)")
        
        return await cycleCorrection(bundleId: bundleId)
    }

    /// A word typed partly in each layout ("Эmain\"": the quote key on Russian, then
    /// `main"` on English) already has letters of `to`'s alphabet. Those letters are
    /// right, and so is every mark typed after them before a letter of another alphabet:
    /// only the rest is converted, so the hotkey gives `"main"`, not `"main@`. A mark
    /// before the first letter goes with that letter. Returns nil when the word has no
    /// letters of `to`'s alphabet, and the whole word is converted as before.
    func convertWrongLayoutPart(
        of text: String,
        from: Language,
        to: Language,
        activeLayouts: [String: String]
    ) -> String? {
        func alphabet(_ ch: Character) -> Language? {
            guard ch.isLetter else { return nil }
            switch ch.unicodeScalars.first?.value ?? 0 {
            case 0x0400...0x04FF: return .russian
            case 0x0590...0x05FF: return .hebrew
            default: return .english
            }
        }

        let chars = Array(text)
        let letters = chars.map(alphabet)
        guard letters.contains(to), letters.contains(where: { $0 != nil && $0 != to }) else { return nil }

        // Whether each character is already in `to`'s layout: a letter by its alphabet,
        // a mark by the letter before it, or after it at the start.
        var isRight = [Bool](repeating: false, count: chars.count)
        var previous = letters.first(where: { $0 != nil }) ?? nil
        for i in chars.indices {
            if let letter = letters[i] { previous = letter }
            isRight[i] = previous == to
        }

        var out = ""
        var i = 0
        while i < chars.count {
            var j = i
            while j < chars.count, isRight[j] == isRight[i] { j += 1 }
            let run = String(chars[i..<j])
            if isRight[i] {
                out += run
            } else {
                out += LayoutMapper.shared.convertAllVariants(run, from: from, to: to, activeLayouts: activeLayouts)
                    .first?.result ?? run
            }
            i = j
        }
        return out
    }

    // MARK: - Cycle Through Alternatives

    /// Cycle to next alternative on repeated hotkey press
    /// For auto-correction: first press = undo (go to original)
    /// For manual: cycles through alternatives
    func cycleCorrection(bundleId: String? = nil) async -> String? {
        guard var state = cyclingState, state.isValid else {
            logger.warning("❌ No cycling state or expired")
            return nil
        }
        
        // For auto-correction, first hotkey press should UNDO (go to index 0)
        let alt: CyclingContext.Alternative
        
        if state.wasAutomatic && state.currentIndex == 1 && !state.hasReturnedToOriginal {
            // First press after auto-correction: go to original (undo)
            state.currentIndex = 0
            state.hasReturnedToOriginal = true
            alt = state.alternatives[0]
            logger.info("🔄 UNDO auto-correction → original")
        } else {
            // Check if we need to expand rounds
            let nextIndex = state.currentIndex + 1
            
            if nextIndex >= state.visibleAlternativesCount {
                // We are about to wrap.
                if state.roundNumber == 1 {
                    if state.cycleCount >= 1 {
                        // We have already wrapped at least once (0 -> 1 -> 0 -> 1 -> [here])
                        // Time to expand to Round 2
                        if state.alternatives.count > state.visibleAlternativesCount {
                            state.roundNumber = 2
                            state.visibleAlternativesCount = min(state.alternatives.count, ThresholdsConfig.shared.correction.visibleAlternativesRound2)
                            logger.info("🔄 Entering Round 2: Visible alternatives increased to \(state.visibleAlternativesCount)")
                        }
                    }
                    
                    // Increment cycle count on wrap (or failed expansion)
                    // Note: If we expanded, nextIndex (2) is < 3, so we might NOT wrap in next().
                    // But if we expanded, we don't increment cycleCount?
                    // Let's increment cycleCount only when we actually WRAP (go to 0).
                    
                    if nextIndex >= state.visibleAlternativesCount {
                        state.cycleCount += 1
                    }
                }
            }
            
            alt = state.next()
        }
        cyclingState = state
        
        logger.info("🔄 Cycling to: \(DecisionLogger.tokenSummary(alt.text), privacy: .public) (index \(state.currentIndex)/\(state.alternatives.count), round \(state.roundNumber))")
        
        // Log the correction for UI/history inspection
        CorrectionLogger.shared.log(
            original: state.originalText,
            final: alt.text,
            autoAttempted: state.autoHypothesis,
            userSelected: alt.hypothesis,
            app: bundleId
        )
        
        return alt.text
    }

    // MARK: - Reset Cycling

    /// Reset cycling state (called when new text is typed)
    func resetCycling() {
        cyclingState = nil
    }
}
