import Foundation

/// Whether the Algorithm page's test field has the keyboard focus. That field checks
/// what is typed into it itself; correcting it as you type would change the very word
/// being looked at, so the event monitor leaves it alone.
@MainActor
enum DecisionPlaygroundFocus {
    static var isFocused = false
}

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

/// The kind of app the test field pretends to type into. It decides how a correction
/// is put into the text (see `HostRuntimeProfile` and `SelectionReplacementService`).
enum PlaygroundApp: String, CaseIterable, Identifiable, Sendable {
    /// TextEdit, Notes, Mail: the text is read and written through Accessibility.
    case readsText
    /// Slack: shows its text, but ignores writes through Accessibility.
    case slack
    /// Claude, VS Code, terminals: hide their text, known to take retyping.
    case hidesText
    /// An app that hides its text and isn't known to take retyping.
    case unknownHidden

    var id: String { rawValue }

    var environment: EditingEnvironment {
        switch self {
        case .readsText, .slack: return .accessibility
        case .hidesText, .unknownHidden: return .nonAccessibility
        }
    }
}

/// The settings that decide how a correction is put into the text.
struct PlaygroundApplySettings: Sendable {
    var holdsEnter = true
    var switchesLayout = true
    var soundName: String?
    var blindConfidence = AutoCorrectionLimits.default.blindConfidence
    var minimumWordLength = AutoCorrectionLimits.default.minimumWordLength
}

/// Checks the text of the Algorithm page's test field word by word, the way the event
/// monitor does while you type, and records what every block did with each word,
/// including how the correction would be put into the app.
enum DecisionPlayground {
    static func check(
        _ text: String,
        engine: CorrectionEngine,
        knowledge: KnowledgeLookup,
        app: PlaygroundApp,
        endsWithEnter: Bool,
        settings: PlaygroundApplySettings
    ) async -> [PlaygroundWord] {
        let tokens = text.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !tokens.isEmpty else { return [] }

        let environment = app.environment
        await engine.startDryRun()
        var words: [PlaygroundWord] = []

        for (index, token) in tokens.enumerated() {
            let isLast = index == tokens.count - 1
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
            let holdsEnter = isLast && endsWithEnter && settings.holdsEnter
            if holdsEnter {
                if case .hint = planned.plan,
                   let forced = await engine.applyPendingSuggestion(),
                   let corrected = forced.corrected {
                    probe.append(step: .holdEnter, effect: .decided, note: .appliedBeforeSending, arguments: [corrected])
                    shown = corrected
                    outcome = .replace
                    proposed = nil
                } else if outcome != .replace {
                    probe.append(step: .holdEnter, effect: .checked, note: .nothingBeforeSending, arguments: [])
                }
            }

            // A word corrected afterwards, once this one confirmed its language.
            var previousChange: (typed: String, shown: String)?
            if let pendingOriginal = planned.result.pendingOriginal,
               let pendingCorrection = planned.result.pendingCorrection,
               let previous = words.indices.last,
               words[previous].typed == pendingOriginal {
                previousChange = (pendingOriginal, pendingCorrection)
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
                    previousChange = (typed, cascaded)
                } else {
                    probe.append(step: .previousWordCascade, effect: .checked, note: .previousWordStays, arguments: [])
                }
            }

            if outcome == .replace {
                // Held, the Enter isn't typed yet; otherwise it already ended the line.
                let separator = isLast && endsWithEnter ? (holdsEnter ? "" : "\n") : " "
                let applied = describeReplacing(
                    typed: token,
                    replacement: shown,
                    separator: separator,
                    previousChange: previousChange,
                    confidence: planned.result.confidence,
                    targetLanguage: planned.result.targetLanguage,
                    app: app,
                    settings: settings,
                    probe: probe
                )
                if !applied {
                    // The word stays as typed; the hotkey can still correct it.
                    proposed = shown
                    shown = token
                    outcome = .hotkeyOnly
                    previousChange = nil
                    if holdsEnter {
                        probe.append(step: .holdEnter, effect: .checked, note: .enterSentUnchanged, arguments: [])
                    }
                }
            }
            if let previousChange, let previous = words.indices.last {
                words[previous].shown = previousChange.shown
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

    /// Tells the probe how the event monitor would put `replacement` in place of `typed`
    /// (`EventMonitor.processCommittedBoundary`), and whether it would at all.
    static func describeReplacing(
        typed: String,
        replacement: String,
        separator: String,
        previousChange: (typed: String, shown: String)?,
        confidence: Double?,
        targetLanguage: Language?,
        app: PlaygroundApp,
        settings: PlaygroundApplySettings,
        probe: DecisionProbe
    ) -> Bool {
        let original = (previousChange.map { $0.typed + " " } ?? "") + typed + separator
        let inserted = (previousChange.map { $0.shown + " " } ?? "") + replacement + separator
        probe.append(step: .heldKeys, effect: .checked, note: .keysWait, arguments: [])

        var applied = true
        switch app {
        case .readsText:
            probe.append(step: .appKind, effect: .contributed, note: .appReadsText, arguments: [])
            probe.append(step: .fieldCheck, effect: .contributed, note: .fieldChecked, arguments: [visible(original)])
            probe.append(step: .accessibilityWrite, effect: .decided, note: .writtenInPlace, arguments: [visible(inserted), visible(original)])
        case .slack:
            probe.append(step: .appKind, effect: .contributed, note: .appIgnoresWrites, arguments: [])
            probe.append(step: .fieldCheck, effect: .contributed, note: .fieldChecked, arguments: [visible(original)])
            probe.append(step: .accessibilityWrite, effect: .rejected, note: .writeIgnored, arguments: [])
            probe.append(step: .verifiedRetype, effect: .decided, note: .retypedVerified, arguments: [String(original.count), visible(inserted)])
        case .hidesText:
            probe.append(step: .appKind, effect: .contributed, note: .appTakesRetyping, arguments: [])
            probe.append(step: .fieldCheck, effect: .checked, note: .fieldUnreadable, arguments: [])
            // The same checks as EventMonitor.automaticReplayFallbackRefusal.
            let word = EventMonitor.blindReplayWord(original: original, replacement: replacement)
            let minimum = word.map { EventMonitor.isOneLetterRussianWord(original: $0, replacement: replacement) } == true
                ? 1
                : max(1, settings.minimumWordLength)
            let letters = word?.count ?? 0
            if separator.contains(where: \.isNewline) {
                probe.append(step: .blindRetype, effect: .rejected, note: .notRetypedNewline, arguments: [])
                applied = false
            } else if !(minimum...18).contains(letters) {
                probe.append(step: .blindRetype, effect: .rejected, note: .notRetypedLength, arguments: [String(letters), String(minimum)])
                applied = false
            } else if (confidence ?? 0) < settings.blindConfidence {
                probe.append(step: .blindRetype, effect: .rejected, note: .notRetypedConfidence, arguments: [
                    DecisionProbe.percent(confidence ?? 0),
                    DecisionProbe.percent(settings.blindConfidence)
                ])
                applied = false
            } else {
                probe.append(step: .blindRetype, effect: .decided, note: .retypedBlind, arguments: [String(original.count), visible(inserted)])
            }
        case .unknownHidden:
            probe.append(step: .appKind, effect: .contributed, note: .appUnknownHidden, arguments: [])
            probe.append(step: .fieldCheck, effect: .checked, note: .fieldUnreadable, arguments: [])
            probe.append(step: .blindRetype, effect: .rejected, note: .notRetypedUnknownApp, arguments: [])
            applied = false
        }

        if settings.switchesLayout {
            if !applied {
                probe.append(step: .layoutSwitch, effect: .checked, note: .layoutStays, arguments: [])
            } else if let targetLanguage {
                let note: ProbeNote = app.environment == .accessibility ? .switchesBefore : .switchesAfterRetype
                probe.append(step: .layoutSwitch, effect: .contributed, note: note, arguments: [DecisionProbe.name(targetLanguage)])
            } else {
                probe.append(step: .layoutSwitch, effect: .checked, note: .layoutStaysEmoticon, arguments: [])
            }
        }
        if applied, let soundName = settings.soundName {
            probe.append(step: .correctionSound, effect: .contributed, note: .playsSound, arguments: [soundName])
        }
        return applied
    }

    /// Spaces and line breaks made visible: "привет␣".
    static func visible(_ text: String) -> String {
        text.replacingOccurrences(of: " ", with: "␣").replacingOccurrences(of: "\n", with: "⏎")
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
