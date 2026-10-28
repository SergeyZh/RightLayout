import Foundation

/// A block of the Algorithm page, as the word check reports what it did.
/// The raw values are the blocks' ids (`AlgorithmNode.id`).
enum DecisionStep: String, CaseIterable, Sendable {
    case builtinLexicon
    case frequencyDictionaries
    case systemSpellChecker
    case trigramModel
    case holdEnter
    case zeroInterference
    case abbreviations
    case emoticons
    case singleRussianLetter
    case intentDetector
    case userDictionary
    case singleLetterSafety
    case mixedScriptGuard
    case technicalTokenGuard
    case whitelist
    case russianProtection
    case scoredDecision
    case fastPath
    case ensemble
    case coreML
    case foundationModel
    case heuristic
    case rearrangedLayoutFilter
    case capitalizedShortWords
    case wrongLayoutPunctuation
    case languageFilter
    case policy
    case learning
    case punctuationKeyWords
    case smartSplit
    case verifier
    case hebrewShortWords
    case sentenceContextOverride
    case deferredWords
    case previousWordCascade
    case transliterationHints
    case appKind
    case fieldCheck
    case accessibilityWrite
    case verifiedRetype
    case blindRetype
    case heldKeys
    case layoutSwitch
    case correctionSound
}

/// What a block did with the word.
enum DecisionEffect: Int, Comparable, Sendable {
    /// Looked at the word and let it through.
    case checked
    /// Gave a signal or a candidate that later blocks used.
    case contributed
    /// Proposed a correction that was not taken.
    case rejected
    /// Settled the decision; the blocks after it were skipped.
    case decided

    static func < (lhs: DecisionEffect, rhs: DecisionEffect) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// What a block says about the word. The raw values are English format strings
/// (localized keys) whose `%@` take the event's arguments.
enum ProbeNote: String, CaseIterable, Sendable {
    case doesNotApply = "Doesn't apply"

    // Before routing
    case internationalTerm = "An international term: left as typed"
    case exactMatch = "Exact match: \"%@\""
    case noMatch = "No match"
    case oneLetterRussianWord = "\"%@\" → \"%@\": a one-letter Russian word"
    case looksLikeCode = "Looks like code: left as typed"
    case looksLikeLink = "Looks like a link or a command: left as typed"
    case ordinaryText = "Ordinary text"

    // Router: firm rules
    case ruleKeep = "Your rule: keep as typed"
    case rulePrefer = "Your rule: convert as %@"
    case noRule = "No rule for this word"
    case singleLetterKept = "A single letter: kept as typed"
    case singleLetterPreposition = "\"%@\" is a Russian preposition: checked further"
    case notSingleLetter = "Not a single letter"
    case mixedAlphabetsKept = "Letters of several alphabets: kept as typed"
    case oneAlphabet = "One alphabet"
    case technicalKept = "A technical token: kept as typed"
    case notTechnical = "Not a technical token"
    case whitelisted = "In the %@ whitelist: kept as typed"
    case notWhitelisted = "Not in the whitelist"
    case knownRussian = "A known Russian word (%@): kept as typed"
    case notKnownRussian = "Not known as Russian (%@, needs %@)"
    case notCyrillic = "Not a Cyrillic word"

    // Router: weighing
    case scoredBest = "Best: \"%@\" (%@) scores %@, as typed %@, margin %@"
    case scoredHebrewKeys = "Hebrew keys: \"%@\" (%@) is the likelier word"
    case scoredNothing = "Nothing to convert"
    case scoredNotEnough = "Best: \"%@\" (%@) scores %@, needs %@"
    case scoredNotAWord = "Best: \"%@\" is not a known word (%@, needs %@)"
    case confidentDecided = "Confident (%@): decided"
    case belowThreshold = "Confidence %@ below %@: checked further"
    case overridesTypedCorrectly = "Overrides \"typed correctly\": %@ (%@)"
    case shorterThanFour = "Shorter than four letters"
    case trigramsUnsure = "The trigrams are not sure, or the word is unknown"
    case typedCorrectlyIn = "Typed correctly in %@ (%@)"
    case answerBelow = "%@ (%@) below %@"
    case baseline = "Baseline: %@ (%@)"
    case baselineConfirmed = "Baseline correction confirmed: %@ (%@)"
    case modelAccepted = "%@ (%@) → \"%@\": accepted"
    case modelWrongAlphabet = "%@ (%@) rejected: the word is in another alphabet"
    case modelNoWord = "%@ (%@) rejected: no conversion is a word"
    case modelIgnored = "%@ (%@) below %@: ignored"
    case modelTypedCorrectly = "Typed correctly: %@ (%@)"
    case modelAgrees = "%@ (%@): the baseline stands"
    case noAnswer = "No answer"
    case noCorrection = "No correction"
    case onlyWordConversion = "The only conversion that is a word: %@"
    case typedWordIsWord = "The typed word is a word (%@)"
    case noSingleConversion = "No single conversion is a word"
    case layoutSkipped = "Skipped %@: not enabled in macOS"

    // Router: last checks
    case decidedAsLowercase = "Decided like \"%@\": %@"
    case lowercaseTypedCorrectly = "\"%@\" is typed correctly too"
    case russianPunctuationAtEnd = "\"%@\": Russian punctuation at the end"
    case languageOff = "%@ involves a language that is off: kept as typed"
    case workingLanguagesOnly = "Only working languages"

    // Policy
    case kindPlain = "A plain word"
    case kindShort = "A short word (up to three letters)"
    case kindPunctuated = "A word with punctuation inside"
    case kindMixed = "Mixed alphabets"
    case kindTechnical = "A technical token"
    case policyReplace = "Confidence %@, margin %@: replace"
    case policySuggest = "Confidence %@, margin %@: suggest"
    case policyHotkey = "Confidence %@, margin %@: hotkey only"
    case policyNotCorrection = "Not a correction"
    case shorterThanMinimum = "Shorter than %@ letters: hotkey only"
    case blindPunctuated = "Punctuated, and the app's text can't be read back: a suggestion at most"
    case learnedSuggestion = "Learned caution: a suggestion instead of a replacement"
    case learnedHotkey = "Learned caution: hotkey only"
    case nothingLearned = "Nothing learned against it"

    // After routing
    case convertedWhole = "\"%@\" is a word: converted as a whole"
    case smartResult = "\"%@\" (%@)"
    case noBetterSplit = "No better result"
    case verifierRejected = "Rejected: %@"
    case verifierApproved = "Approved (confidence %@)"
    case commonHebrewWord = "\"%@\" is a common Hebrew word"
    case sentenceLanguage = "In a %@ sentence: \"%@\""
    case remembered = "Remembered until the next word (confidence %@)"
    case previousWordChanged = "The previous word \"%@\" → \"%@\""
    case previousWordStays = "The previous word stays as typed"
    case hint = "Hint: \"%@\""
    case appliedBeforeSending = "Applied before sending: \"%@\""
    case nothingBeforeSending = "Nothing to fix before sending"

    // Replacing the word
    case appReadsText = "Reads its text through Accessibility"
    case appIgnoresWrites = "Shows its text, but ignores writes through Accessibility"
    case appTakesRetyping = "Hides its text; known to take retyping"
    case appUnknownHidden = "Hides its text and isn't known to take retyping"
    case fieldChecked = "Checks that \"%@\" is right before the caret"
    case fieldUnreadable = "The text can't be read: nothing to check"
    case writtenInPlace = "Puts \"%@\" in place of \"%@\"; the caret goes after it"
    case writeIgnored = "The app ignores this: retyped instead"
    case retypedVerified = "⌫ × %@, then types \"%@\"; reads the field back to confirm"
    case retypedBlind = "⌫ × %@, then types \"%@\" without seeing the result"
    case notRetypedNewline = "The word ends a line: not retyped blind"
    case notRetypedLength = "%@ letters: not retyped blind (needs %@ to 18)"
    case notRetypedConfidence = "Confidence %@ below %@: not retyped blind"
    case notRetypedUnknownApp = "An unknown app that hides its text: not retyped"
    case keysWait = "Keys typed meanwhile wait, then follow the replacement"
    case switchesBefore = "Switches to %@ before replacing, so the next keys land in it"
    case switchesAfterRetype = "Switches to %@: this app takes retyping"
    case layoutStaysEmoticon = "An emoticon: the layout stays"
    case layoutStays = "The word stays: so does the layout"
    case playsSound = "Plays \"%@\""
    case enterSentUnchanged = "The word stays, and Enter is sent"

    // Knowledge sources
    case knownIn = "\"%@\" (%@): yes"
    case unknownIn = "\"%@\" (%@): no"
    case scoreIn = "\"%@\" (%@): %@"
}

struct DecisionProbeEvent: Identifiable, Sendable, Equatable {
    let id: Int
    let step: DecisionStep
    let effect: DecisionEffect
    let note: ProbeNote
    let arguments: [String]
}

/// Collects what each block of the word check did with one word, for the Algorithm
/// page's test field. The check runs as usual; while no probe is set (always, outside
/// that field) recording costs nothing.
final class DecisionProbe: @unchecked Sendable {
    @TaskLocal static var current: DecisionProbe?

    private let lock = NSLock()
    private var recorded: [DecisionProbeEvent] = []
    private var finalRisk: RiskPolicy?

    var events: [DecisionProbeEvent] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    /// The risk policy the word ended up with: replace, suggest, or hotkey only.
    var riskPolicy: RiskPolicy? {
        lock.lock()
        defer { lock.unlock() }
        return finalRisk
    }

    /// Records what `step` did, if a probe is set. A repeated event (the router weighs a
    /// word more than once) is kept once.
    static func record(
        _ step: DecisionStep,
        _ effect: DecisionEffect,
        _ note: ProbeNote,
        _ arguments: @autoclosure () -> [String] = []
    ) {
        current?.append(step: step, effect: effect, note: note, arguments: arguments())
    }

    static func recordRiskPolicy(_ policy: RiskPolicy) {
        guard let probe = current else { return }
        probe.lock.lock()
        defer { probe.lock.unlock() }
        probe.finalRisk = policy
    }

    func append(step: DecisionStep, effect: DecisionEffect, note: ProbeNote, arguments: [String]) {
        lock.lock()
        defer { lock.unlock() }
        guard !recorded.contains(where: {
            $0.step == step && $0.effect == effect && $0.note == note && $0.arguments == arguments
        }) else { return }
        recorded.append(DecisionProbeEvent(id: recorded.count, step: step, effect: effect, note: note, arguments: arguments))
    }

    // MARK: Formatting

    static func percent(_ value: Double) -> String {
        "\(Int((value * 100).rounded()))%"
    }

    static func number(_ value: Double) -> String {
        String(format: "%.2f", value)
    }

    /// "EN→RU" for a correction, "RU" for a word typed correctly.
    static func name(_ hypothesis: LanguageHypothesis) -> String {
        let target = hypothesis.targetLanguage.rawValue.uppercased()
        guard let source = hypothesis.sourceLanguage, hypothesis.rawValue.contains("_from_") else {
            return target
        }
        return "\(source.rawValue.uppercased())→\(target)"
    }

    static func name(_ language: Language) -> String {
        language.rawValue.uppercased()
    }
}
