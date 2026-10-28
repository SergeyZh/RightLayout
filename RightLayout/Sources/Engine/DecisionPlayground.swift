import Foundation

/// A word of the text typed into the Algorithm page's test field, as the check decided it.
struct PlaygroundWord: Identifiable, Sendable {
    enum Outcome: Sendable {
        case replace
        case suggest
        case hotkeyOnly
        case leave
    }

    let id: Int
    let typed: String
    /// What the field would show after the check, including later words' corrections.
    var shown: String
    let outcome: Outcome
    /// The conversion a suggestion or the hotkey would put in.
    let proposed: String?
    let confidence: Double?
    var events: [DecisionProbeEvent]
}

/// Checks the text of the Algorithm page's test field word by word, the way the event
/// monitor does while you type, and records what every block did with each word.
enum DecisionPlayground {
    static func check(
        _ text: String,
        engine: CorrectionEngine,
        knowledge: KnowledgeLookup,
        environment: EditingEnvironment,
        endsWithEnter: Bool,
        holdsEnter: Bool
    ) async -> [PlaygroundWord] {
        let tokens = text.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !tokens.isEmpty else { return [] }

        await engine.startDryRun()
        var words: [PlaygroundWord] = []

        for (index, token) in tokens.enumerated() {
            let probe = DecisionProbe()
            let phrase = words.map(\.shown).joined(separator: " ")
            let planned = await DecisionProbe.$current.withValue(probe) {
                await engine.planCorrection(token, phraseBuffer: phrase, editingEnvironment: environment)
            }

            var shown = token
            var outcome: PlaygroundWord.Outcome
            switch planned.plan {
            case .autoReplace(let candidate):
                shown = candidate.replacement
                outcome = .replace
            case .hint:
                outcome = probe.riskPolicy == .holdForHotkey ? .hotkeyOnly : .suggest
            case .none, .manualCycle:
                outcome = .leave
            }
            let suggested = await engine.pendingSuggestionReplacement()
            var proposed = outcome == .replace ? nil : suggested

            // A held Enter applies a suggestion right away (EventMonitor.holdEnter).
            if index == tokens.count - 1, endsWithEnter, holdsEnter {
                if case .hint = planned.plan,
                   let forced = await engine.applyPendingSuggestion(),
                   let corrected = forced.corrected {
                    probe.append(step: .holdEnter, effect: .decided, note: .appliedBeforeSending, arguments: [corrected])
                    shown = corrected
                    outcome = .replace
                    proposed = nil
                } else {
                    probe.append(step: .holdEnter, effect: .checked, note: .nothingBeforeSending, arguments: [])
                }
            }

            // A word corrected afterwards, once this one confirmed its language.
            if let pendingOriginal = planned.result.pendingOriginal,
               let pendingCorrection = planned.result.pendingCorrection,
               let previous = words.indices.last,
               words[previous].typed == pendingOriginal {
                words[previous].shown = pendingCorrection
            } else if case .autoReplace = planned.plan,
                      environment == .accessibility,
                      let previous = words.indices.last,
                      words[previous].shown == words[previous].typed,
                      words[previous].typed.filter(\.isLetter).count <= 2,
                      let target = planned.result.targetLanguage,
                      DecisionPipeline.isEnabled(.previousWordCascade) {
                // The previous short word converted along with this one (EventMonitor).
                let typed = words[previous].typed
                if let cascaded = await engine.contextualCascadeCorrection(for: typed, targetLanguage: target) {
                    probe.append(step: .previousWordCascade, effect: .decided, note: .previousWordChanged, arguments: [typed, cascaded])
                    words[previous].shown = cascaded
                } else {
                    probe.append(step: .previousWordCascade, effect: .checked, note: .previousWordStays, arguments: [])
                }
            }

            knowledge.describe(token, in: KnowledgeLookup.scriptLanguage(of: token), probe: probe)
            let converted = outcome == .replace ? shown : proposed
            if let converted, converted != token {
                let target = planned.result.targetLanguage
                    ?? planned.result.evidence?.targetLanguage
                    ?? KnowledgeLookup.scriptLanguage(of: converted)
                knowledge.describe(converted, in: target, probe: probe)
            }

            words.append(
                PlaygroundWord(
                    id: index,
                    typed: token,
                    shown: shown,
                    outcome: outcome,
                    proposed: proposed,
                    confidence: planned.result.confidence ?? planned.result.evidence?.confidence,
                    events: probe.events
                )
            )
        }
        return words
    }
}

/// Looks a word up in the knowledge sources for the test field, so the diagram can show
/// what each source knows about the typed word and its conversion.
final class KnowledgeLookup: @unchecked Sendable {
    private let spellChecker = SystemWordValidator()
    private let lexicon = BuiltinWordValidator()
    private let trigrams: [Language: NgramLanguageModel]

    init() {
        var models: [Language: NgramLanguageModel] = [:]
        for language in Language.allCases {
            models[language] = try? NgramLanguageModel.loadLanguage(language.rawValue)
        }
        trigrams = models
    }

    /// The language of the alphabet `text` is written in.
    static func scriptLanguage(of text: String) -> Language {
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x0400...0x04FF: return .russian
            case 0x0590...0x05FF: return .hebrew
            default: continue
            }
        }
        return .english
    }

    func describe(_ text: String, in language: Language, probe: DecisionProbe) {
        let languageName = DecisionProbe.name(language)
        if DecisionPipeline.isEnabled(.builtinLexicon) {
            let known = lexicon.confidence(for: text, language: language) >= 0.99
            probe.append(step: .builtinLexicon, effect: .contributed, note: known ? .knownIn : .unknownIn, arguments: [text, languageName])
        }
        if DecisionPipeline.isEnabled(.frequencyDictionaries),
           let model = WordFrequencyModel.shared(language.rawValue) {
            let words = text.split(whereSeparator: { !$0.isLetter }).map(String.init)
            let score = words.isEmpty ? 0 : words.reduce(0.0) { $0 + model.score($1) } / Double(words.count)
            probe.append(step: .frequencyDictionaries, effect: .contributed, note: .scoreIn, arguments: [text, languageName, DecisionProbe.number(score)])
        }
        if DecisionPipeline.isEnabled(.systemSpellChecker) {
            let known = spellChecker.confidence(for: text, language: language) >= 0.99
            probe.append(step: .systemSpellChecker, effect: .contributed, note: known ? .knownIn : .unknownIn, arguments: [text, languageName])
        }
        if DecisionPipeline.isEnabled(.trigramModel), let model = trigrams[language] {
            probe.append(step: .trigramModel, effect: .contributed, note: .scoreIn, arguments: [text, languageName, DecisionProbe.percent(model.normalizedScore(text))])
        }
    }
}
