import Foundation

/// A stage of the word check on the Algorithm page. A typed word goes through the
/// stages top to bottom; the knowledge sources feed all of them.
struct AlgorithmStage: Identifiable {
    let id: String
    let title: String
    let detail: String
    let nodes: [AlgorithmNode]
}

/// A part of the word check, drawn as one block of its stage.
struct AlgorithmNode: Identifiable {
    /// What turns the part on and off.
    enum Switch {
        case component(DecisionComponent)
        case setting(SettingSwitch)
        /// The part keeps the decision safe and can't be turned off.
        case alwaysOn
    }

    /// Parts that have had a setting of their own since before the Algorithm page.
    enum SettingSwitch {
        case holdEnter
        case foundationModel
        case verifier
        case learning
        case transliterationHints
    }

    /// A value of the part that can be changed.
    enum Control: Hashable {
        case parameter(DecisionParameter)
        case fastPathThreshold
        case standardPathThreshold
        case behaviorPreset
        case minimumWordLength
        case blindConfidence
        case blindReplayDelay
    }

    let id: String
    let title: String
    /// One line on the block.
    let summary: String
    /// What the part does, shown when the block is selected.
    let detail: String
    let systemImage: String
    let toggle: Switch
    var controls: [Control] = []
    /// The part can settle the decision by itself, and the rest of the check is skipped.
    var decidesAlone = false
}

enum AlgorithmDiagram {
    /// What every stage looks words up in.
    static let knowledgeSources = AlgorithmStage(
        id: "knowledge",
        title: "Knowledge sources",
        detail: "Every stage asks them whether a string is a real word of a language. Turning one off makes all stages work without it.",
        nodes: [
            AlgorithmNode(
                id: "builtinLexicon",
                title: "Built-in lexicon",
                summary: "Hand-picked words, the most trusted signal",
                detail: "Curated word lists of each language, including the short words the frequency lists leave out. A conversion that lands in the lexicon wins over all others. Turned off, short words are decided by the spell checker alone.",
                systemImage: "book.closed",
                toggle: .component(.builtinLexicon)
            ),
            AlgorithmNode(
                id: "frequencyDictionaries",
                title: "Frequency dictionaries",
                summary: "200,000 words per language, with how often each is used",
                detail: "Tells whether a word exists and how common it is. Common words win with a wide margin, rare forms are still recognized as words. Words shorter than three letters are left out.",
                systemImage: "chart.bar",
                toggle: .component(.frequencyDictionaries)
            ),
            AlgorithmNode(
                id: "systemSpellChecker",
                title: "macOS spell checker",
                summary: "The system dictionaries of each language",
                detail: "Checks the spelling of a word with the dictionaries macOS has. A dictionary that accepts obvious gibberish is not used.",
                systemImage: "text.badge.checkmark",
                toggle: .component(.systemSpellChecker)
            ),
            AlgorithmNode(
                id: "trigramModel",
                title: "Letter trigrams",
                summary: "How much a string sounds like a language",
                detail: "Probabilities of three letters in a row. Judges strings that are in no dictionary, such as names and new words. Turned off, every string sounds equally foreign.",
                systemImage: "waveform",
                toggle: .component(.trigramModel)
            )
        ]
    )

    static let stages: [AlgorithmStage] = [
        AlgorithmStage(
            id: "boundary",
            title: "End of a word",
            detail: "The word is checked when a space or Enter ends it. Punctuation stays part of the word.",
            nodes: [
                AlgorithmNode(
                    id: "holdEnter",
                    title: "Hold Enter",
                    summary: "Don't send a message with a wrong-layout word",
                    detail: "When Enter ends a word, it is held while the word is checked. If the word gets fixed, that Enter is not sent: check the text and press Enter again.",
                    systemImage: "return",
                    toggle: .setting(.holdEnter)
                )
            ]
        ),
        AlgorithmStage(
            id: "prechecks",
            title: "Before routing",
            detail: "Quick checks for tokens the language models can't judge.",
            nodes: [
                AlgorithmNode(
                    id: "zeroInterference",
                    title: "International terms",
                    summary: "Terms that are never touched",
                    detail: "Words from the list of international terms are always left as typed.",
                    systemImage: "globe",
                    toggle: .component(.zeroInterference),
                    decidesAlone: true
                ),
                AlgorithmNode(
                    id: "abbreviations",
                    title: "Russian abbreviations",
                    summary: "\"n/r/\" → \"т.к.\"",
                    detail: "Russian abbreviations typed on the English layout (т.е., т.к., т.д., и.о. and others) are fixed at once by an exact match with a short list.",
                    systemImage: "textformat.abc",
                    toggle: .component(.abbreviations),
                    decidesAlone: true
                ),
                AlgorithmNode(
                    id: "emoticons",
                    title: "Emoticons",
                    summary: "\"Ж-)\" → \":-)\"",
                    detail: "Emoticons typed on the Russian or Hebrew layout are fixed at once. The layout is not switched: an emoticon belongs to no language.",
                    systemImage: "face.smiling",
                    toggle: .component(.emoticons),
                    decidesAlone: true
                ),
                AlgorithmNode(
                    id: "singleRussianLetter",
                    title: "One-letter Russian words",
                    summary: "\"Прочитай b\" → \"Прочитай и\"",
                    detail: "A Latin letter that is a one-letter Russian word is fixed at once after a Russian word, or as a capital starting a sentence after one. A capital inside a sentence (\"план B\") is left alone.",
                    systemImage: "character",
                    toggle: .component(.singleRussianLetter),
                    decidesAlone: true
                ),
                AlgorithmNode(
                    id: "intentDetector",
                    title: "Code and links",
                    summary: "Code, URLs and commands are left as typed",
                    detail: "Recognizes code, links, paths and terminal commands, and leaves them as typed. A word with slashes only at its end (\"Lf/\") is not a path.",
                    systemImage: "chevron.left.forwardslash.chevron.right",
                    toggle: .component(.intentDetector),
                    decidesAlone: true
                )
            ]
        ),
        AlgorithmStage(
            id: "rules",
            title: "Router: firm rules",
            detail: "The first rule that applies decides; the weighing below is skipped.",
            nodes: [
                AlgorithmNode(
                    id: "userDictionary",
                    title: "Your rules",
                    summary: "\"Keep as typed\" and \"prefer a layout\"",
                    detail: "The rules from the Adaptation page: a word you keep as typed is never changed automatically, a word with a preferred layout is converted to it.",
                    systemImage: "person.crop.square",
                    toggle: .component(.userDictionary),
                    decidesAlone: true
                ),
                AlgorithmNode(
                    id: "singleLetterSafety",
                    title: "Single letters",
                    summary: "A lone letter stays as typed",
                    detail: "A single Cyrillic or Hebrew letter is kept. A single Latin letter is kept unless it is a Russian preposition typed on the English layout (\"y\" → \"н\").",
                    systemImage: "1.circle",
                    toggle: .component(.singleLetterSafety),
                    decidesAlone: true
                ),
                AlgorithmNode(
                    id: "mixedScriptGuard",
                    title: "Mixed alphabets",
                    summary: "Latin and Cyrillic in one word: left as typed",
                    detail: "A word with letters of several alphabets was typed that way on purpose and is not converted.",
                    systemImage: "textformat",
                    toggle: .component(.mixedScriptGuard),
                    decidesAlone: true
                ),
                AlgorithmNode(
                    id: "technicalTokenGuard",
                    title: "Technical tokens",
                    summary: "File names, UUIDs, versions",
                    detail: "File names with common extensions, UUIDs, version numbers and numeric labels are never converted.",
                    systemImage: "number",
                    toggle: .component(.technicalTokenGuard),
                    decidesAlone: true
                ),
                AlgorithmNode(
                    id: "whitelist",
                    title: "Whitelist",
                    summary: "Common words and slang of each language",
                    detail: "Words from the whitelist are recognized as words of their language and kept.",
                    systemImage: "checkmark.seal",
                    toggle: .component(.whitelist),
                    decidesAlone: true
                ),
                AlgorithmNode(
                    id: "russianProtection",
                    title: "Russian word protection",
                    summary: "A known Russian word is never converted",
                    detail: "A Cyrillic word that the knowledge sources know as Russian is kept as typed.",
                    systemImage: "shield",
                    toggle: .component(.russianProtection),
                    controls: [.parameter(.russianProtectionMin)],
                    decidesAlone: true
                )
            ]
        ),
        AlgorithmStage(
            id: "weighing",
            title: "Router: weighing the layouts",
            detail: "Each way the word could have been typed is scored. The first confident answer is taken.",
            nodes: [
                AlgorithmNode(
                    id: "scoredDecision",
                    title: "Scored decision",
                    summary: "Every conversion against the word as typed",
                    detail: "Converts the word through every layout of every language and scores each result by the dictionaries, the frequency lists and the trigrams. A result wins if it is a word and beats the word as typed by the margin.",
                    systemImage: "list.number",
                    toggle: .component(.scoredDecision),
                    controls: [
                        .parameter(.scoredShortMargin),
                        .parameter(.scoredLongMargin),
                        .parameter(.scoredTargetWordMin),
                        .parameter(.scoredOverrideConfidence)
                    ],
                    decidesAlone: true
                ),
                AlgorithmNode(
                    id: "fastPath",
                    title: "Fast path",
                    summary: "Trigrams confirm a word typed correctly",
                    detail: "For words of four letters or more: if the trigrams of three languages clearly pick the word's own alphabet and the word is known, it was typed correctly.",
                    systemImage: "hare",
                    toggle: .component(.fastPath),
                    controls: [.fastPathThreshold]
                ),
                AlgorithmNode(
                    id: "ensemble",
                    title: "Language ensemble",
                    summary: "N-grams, NaturalLanguage and dictionaries together",
                    detail: "Combines several detectors into the baseline answer: which language the word is in, and how sure that is. Turned off, the baseline is the word as typed.",
                    systemImage: "square.stack.3d.up",
                    toggle: .component(.ensemble),
                    controls: [.standardPathThreshold]
                ),
                AlgorithmNode(
                    id: "coreML",
                    title: "CoreML classifier",
                    summary: "A trained model of layout mistakes",
                    detail: "Predicts whether the word was typed in another layout. Its proposal is accepted only if the conversion is a real word, and replaced by a clearly better conversion of the same keys.",
                    systemImage: "cpu",
                    toggle: .component(.coreML),
                    controls: [
                        .parameter(.coreMLMinConfidence),
                        .parameter(.coreMLOverrideMargin),
                        .parameter(.coreMLAsTypedMin)
                    ]
                ),
                AlgorithmNode(
                    id: "foundationModel",
                    title: "Foundation Model",
                    summary: "Apple's on-device model, for doubtful words",
                    detail: "On macOS 26, asked when the baseline answer is unsure (40–70%). Its proposal is checked like CoreML's.",
                    systemImage: "sparkles",
                    toggle: .setting(.foundationModel)
                ),
                AlgorithmNode(
                    id: "heuristic",
                    title: "Heuristic",
                    summary: "Gibberish in its own alphabet: try the others",
                    detail: "If the word is not a word in its own alphabet, it is converted to the other languages. A conversion found in the dictionaries is accepted when it is the only one.",
                    systemImage: "lightbulb",
                    toggle: .component(.heuristic),
                    controls: [.parameter(.heuristicSourceWordMax)]
                ),
                AlgorithmNode(
                    id: "rearrangedLayoutFilter",
                    title: "Only your layouts",
                    summary: "Phonetic, Dvorak and Colemak only if enabled",
                    detail: "Layouts that put letters on other keys are tried only when they are enabled in macOS. Otherwise ordinary words turn into transliteration (\"privet\" → \"привет\"). Turned off, every known layout is tried.",
                    systemImage: "keyboard",
                    toggle: .component(.rearrangedLayoutFilter)
                )
            ]
        ),
        AlgorithmStage(
            id: "finalChecks",
            title: "Router: last checks",
            detail: "Applied to the router's answer before the policy sees it.",
            nodes: [
                AlgorithmNode(
                    id: "capitalizedShortWords",
                    title: "Capitalized short words",
                    summary: "\"Yj\" is decided like \"yj\" → \"Но\"",
                    detail: "macOS's spell checker takes any capitalized short word for English. A word of two or three letters with a capital is therefore decided like the same word in lowercase; the capital is kept.",
                    systemImage: "textformat.size",
                    toggle: .component(.capitalizedShortWords)
                ),
                AlgorithmNode(
                    id: "wrongLayoutPunctuation",
                    title: "Russian punctuation at the end",
                    summary: "\"Lf/\" → \"Да.\"",
                    detail: "A Latin word ending in a key that is punctuation on the Russian layout (\"/\" is the period, \"&\" the question mark) and that is a Russian word without it was typed in the wrong layout.",
                    systemImage: "quote.bubble",
                    toggle: .component(.wrongLayoutPunctuation)
                ),
                AlgorithmNode(
                    id: "languageFilter",
                    title: "Working languages",
                    summary: "Nothing is converted into a language you don't use",
                    detail: "A decision that involves a language without a working layout is turned into \"leave as typed\". The languages are chosen on the Languages page.",
                    systemImage: "line.3.horizontal.decrease.circle",
                    toggle: .alwaysOn
                )
            ]
        ),
        AlgorithmStage(
            id: "policy",
            title: "Policy",
            detail: "Decides from the confidence, the margin over the runner-up and the kind of word whether to replace it, suggest it, or leave it to the hotkey.",
            nodes: [
                AlgorithmNode(
                    id: "policy",
                    title: "Correction policy",
                    summary: "Replace, suggest, or wait for the hotkey",
                    detail: "The thresholds below are those of the balanced style; the safe style raises them and the aggressive one lowers them. Words too long, too short or mixed are only fixed by the hotkey.",
                    systemImage: "slider.horizontal.3",
                    toggle: .alwaysOn,
                    controls: [
                        .behaviorPreset,
                        .parameter(.policyAutoConfidence),
                        .parameter(.policyAutoMargin),
                        .parameter(.policyHintConfidence),
                        .parameter(.policyShortAutoConfidence),
                        .parameter(.policyShortAutoMargin),
                        .minimumWordLength,
                        .blindConfidence,
                        .parameter(.policyBlindHintConfidence),
                        .blindReplayDelay
                    ]
                ),
                AlgorithmNode(
                    id: "learning",
                    title: "Learning",
                    summary: "Caution where corrections get undone",
                    detail: "Remembers, per app, kind of text and time of day, how often corrections were kept. Where they are mostly undone, corrections become suggestions, then hotkey-only. Learning never makes corrections bolder.",
                    systemImage: "brain",
                    toggle: .setting(.learning),
                    controls: [
                        .parameter(.learningAutoDemoteBelow),
                        .parameter(.learningHintDemoteBelow)
                    ]
                )
            ]
        ),
        AlgorithmStage(
            id: "engine",
            title: "After routing",
            detail: "How the chosen conversion is checked, applied or kept for later.",
            nodes: [
                AlgorithmNode(
                    id: "punctuationKeyWords",
                    title: "Words with ж, х, э, б, ю",
                    summary: "\"Yf;fk\" → \"Нажал\" as a whole",
                    detail: "A word whose punctuation keys are Russian letters is converted as a whole if the result is a known word, also in apps whose text can't be read back.",
                    systemImage: "a.magnify",
                    toggle: .component(.punctuationKeyWords)
                ),
                AlgorithmNode(
                    id: "smartSplit",
                    title: "Splitting at punctuation",
                    summary: "\"ghbdtn.rfr\" → \"привет.как\"",
                    detail: "A word with punctuation inside is converted both as a whole and in pieces split at the punctuation; the better result wins. Turned off, such words are converted only as a whole.",
                    systemImage: "scissors",
                    toggle: .component(.smartSplit)
                ),
                AlgorithmNode(
                    id: "verifier",
                    title: "Verifier",
                    summary: "A second opinion before replacing",
                    detail: "Checks a conversion before it is applied: converting it back must give the typed word, the typed word must not be a real word, the result must not be gibberish and should match the language of the sentence.",
                    systemImage: "checkmark.shield",
                    toggle: .setting(.verifier)
                ),
                AlgorithmNode(
                    id: "hebrewShortWords",
                    title: "Short Hebrew words",
                    summary: "\"kt\" → \"לא\" with a lower bar",
                    detail: "Common short Hebrew words typed on another layout are corrected even with low confidence.",
                    systemImage: "textbubble",
                    toggle: .component(.hebrewShortWords)
                ),
                AlgorithmNode(
                    id: "sentenceContextOverride",
                    title: "Sentence language",
                    summary: "\"vs\" in a Russian sentence → \"мы\"",
                    detail: "A word of one or two letters that is valid as typed is still converted when the two words before it are in another language and the conversion is a common word there.",
                    systemImage: "text.alignleft",
                    toggle: .component(.sentenceContextOverride)
                ),
                AlgorithmNode(
                    id: "deferredWords",
                    title: "Deferred words",
                    summary: "A doubtful word waits for the next one",
                    detail: "A word without enough confidence is remembered and fixed afterwards if the next word confirms its language. Short words valid in several languages are remembered too.",
                    systemImage: "clock.arrow.circlepath",
                    toggle: .component(.deferredWords),
                    controls: [
                        .parameter(.shortWordThreshold),
                        .parameter(.deferredMinConfidence),
                        .parameter(.deferredTimeout)
                    ]
                ),
                AlgorithmNode(
                    id: "previousWordCascade",
                    title: "Previous short word",
                    summary: "Converted together with the next word",
                    detail: "When a word is replaced automatically and the word before it had one or two letters, that word is converted too if it becomes a word of the same language.",
                    systemImage: "arrow.uturn.backward",
                    toggle: .component(.previousWordCascade)
                ),
                AlgorithmNode(
                    id: "transliterationHints",
                    title: "Transliteration hints",
                    summary: "\"privet\" → a hint \"привет\"",
                    detail: "A Latin word that looks like transliterated Russian gets a hint you can apply with the hotkey. Never applied automatically.",
                    systemImage: "character.book.closed",
                    toggle: .setting(.transliterationHints)
                )
            ]
        )
    ]

    struct Outcome: Identifiable {
        let title: String
        let systemImage: String
        var id: String { title }
    }

    /// What the check can end with.
    static let outcomes: [Outcome] = [
        Outcome(title: "Replace", systemImage: "checkmark.circle"),
        Outcome(title: "Suggest", systemImage: "lightbulb"),
        Outcome(title: "Hotkey only", systemImage: "keyboard"),
        Outcome(title: "Leave as typed", systemImage: "minus.circle")
    ]

    static var allNodes: [AlgorithmNode] {
        ([knowledgeSources] + stages).flatMap(\.nodes)
    }
}

extension DecisionParameter {
    var title: String {
        switch self {
        case .russianProtectionMin: return "Known Russian word"
        case .scoredShortMargin: return "Margin for short words"
        case .scoredLongMargin: return "Margin for long words"
        case .scoredTargetWordMin: return "Result must be a word"
        case .scoredOverrideConfidence: return "Override of \"typed correctly\""
        case .coreMLMinConfidence: return "Model confidence"
        case .coreMLOverrideMargin: return "Better conversion margin"
        case .coreMLAsTypedMin: return "Model's \"typed correctly\""
        case .heuristicSourceWordMax: return "Typed word is a word"
        case .policyAutoConfidence: return "Replace: confidence"
        case .policyAutoMargin: return "Replace: margin"
        case .policyHintConfidence: return "Suggest: confidence"
        case .policyShortAutoConfidence: return "Short word: confidence"
        case .policyShortAutoMargin: return "Short word: margin"
        case .policyBlindHintConfidence: return "Suggest in apps without Accessibility"
        case .shortWordThreshold: return "Short word threshold"
        case .deferredMinConfidence: return "Remember from"
        case .deferredTimeout: return "Wait for the next word"
        case .learningAutoDemoteBelow: return "Suggest instead of replacing below"
        case .learningHintDemoteBelow: return "Hotkey only below"
        }
    }

    var detail: String {
        switch self {
        case .russianProtectionMin:
            return "How sure the knowledge sources must be that a Cyrillic word is Russian for it to be kept."
        case .scoredShortMargin:
            return "How much better than the word as typed a conversion of up to three letters must score."
        case .scoredLongMargin:
            return "The same for longer words."
        case .scoredTargetWordMin:
            return "How sure the knowledge sources must be that the conversion is a word."
        case .scoredOverrideConfidence:
            return "A scored correction this confident replaces the router's \"typed correctly\"."
        case .coreMLMinConfidence:
            return "Below this the model's proposal of another layout is ignored."
        case .coreMLOverrideMargin:
            return "How much better another conversion must score to replace the model's choice."
        case .coreMLAsTypedMin:
            return "The model's \"typed correctly\" replaces the baseline when it is surer than this and than the baseline."
        case .heuristicSourceWordMax:
            return "The heuristic is not tried when the typed word is a word with at least this confidence."
        case .policyAutoConfidence:
            return "A word is replaced automatically from this confidence, where the app's text can be read."
        case .policyAutoMargin:
            return "And when the winner is this far ahead of the runner-up."
        case .policyHintConfidence:
            return "Below the replace bar but from this confidence, a suggestion is shown."
        case .policyShortAutoConfidence:
            return "Words of up to three letters are replaced from this confidence."
        case .policyShortAutoMargin:
            return "And with this margin over the runner-up."
        case .policyBlindHintConfidence:
            return "Where the text can't be read back, a suggestion is shown from this confidence."
        case .shortWordThreshold:
            return "Confidence a short correction needs on the standard lane; below it the word is deferred."
        case .deferredMinConfidence:
            return "A word below the threshold is remembered only from this confidence."
        case .deferredTimeout:
            return "A remembered word is forgotten after this time."
        case .learningAutoDemoteBelow:
            return "Corrections become suggestions in a context where even the hopeful estimate of kept corrections is below this."
        case .learningHintDemoteBelow:
            return "Suggestions become hotkey-only where it is below this."
        }
    }
}
