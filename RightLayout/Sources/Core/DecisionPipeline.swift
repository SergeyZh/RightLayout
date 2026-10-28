import Foundation

/// A part of the decision whether a word was typed in the wrong layout that the
/// Algorithm page can turn off (docs/word-check-algorithm.ru.md describes each).
///
/// Parts that already have a setting of their own (the verifier, the Foundation Model,
/// learning, transliteration hints, holding Enter) keep it and are not listed here.
enum DecisionComponent: String, CaseIterable, Sendable {
    // Knowledge sources
    case builtinLexicon
    case frequencyDictionaries
    case systemSpellChecker
    case trigramModel

    // Before routing
    case zeroInterference
    case abbreviations
    case emoticons
    case singleRussianLetter
    case intentDetector

    // Router: rules that decide on their own
    case userDictionary
    case singleLetterSafety
    case mixedScriptGuard
    case technicalTokenGuard
    case whitelist
    case russianProtection

    // Router: weighing the hypotheses
    case scoredDecision
    case fastPath
    case ensemble
    case coreML
    case heuristic
    case rearrangedLayoutFilter

    // Router: final checks
    case capitalizedShortWords
    case wrongLayoutPunctuation

    // After routing
    case punctuationKeyWords
    case smartSplit
    case hebrewShortWords
    case sentenceContextOverride
    case deferredWords
    case previousWordCascade
}

/// A number the decision uses that the Algorithm page lets the user change.
enum DecisionParameter: String, CaseIterable, Sendable {
    case russianProtectionMin
    case scoredShortMargin
    case scoredLongMargin
    case scoredTargetWordMin
    case scoredOverrideConfidence
    case coreMLMinConfidence
    case coreMLOverrideMargin
    case coreMLAsTypedMin
    case heuristicSourceWordMax
    case policyAutoConfidence
    case policyAutoMargin
    case policyHintConfidence
    case policyShortAutoConfidence
    case policyShortAutoMargin
    case policyBlindHintConfidence
    case shortWordThreshold
    case deferredMinConfidence
    case deferredTimeout
    case learningAutoDemoteBelow
    case learningHintDemoteBelow

    enum Unit: Sendable {
        /// A share or confidence, shown in percent.
        case percent
        case seconds
    }

    var unit: Unit {
        self == .deferredTimeout ? .seconds : .percent
    }

    var range: ClosedRange<Double> {
        switch self {
        case .scoredShortMargin, .scoredLongMargin:
            return 0.0...1.5
        case .coreMLOverrideMargin, .policyAutoMargin, .policyShortAutoMargin:
            return 0.0...0.5
        case .deferredTimeout:
            return 1.0...15.0
        default:
            return 0.10...1.0
        }
    }

    var step: Double {
        self == .deferredTimeout ? 0.5 : 0.01
    }

    /// The value the code uses unless the user changes it.
    var defaultValue: Double {
        let thresholds = ThresholdsConfig.shared
        switch self {
        case .russianProtectionMin: return thresholds.sourceWordConfMax
        case .scoredShortMargin: return thresholds.shortWordMargin
        case .scoredLongMargin: return thresholds.longWordMargin
        case .scoredTargetWordMin: return thresholds.wordConfidenceMin
        case .scoredOverrideConfidence: return 0.78
        case .coreMLMinConfidence: return thresholds.correctionThreshold
        case .coreMLOverrideMargin: return 0.12
        case .coreMLAsTypedMin: return thresholds.deepConfidenceMin
        case .heuristicSourceWordMax: return thresholds.sourceWordConfMax
        case .policyAutoConfidence: return 0.78
        case .policyAutoMargin: return 0.12
        case .policyHintConfidence: return 0.70
        case .policyShortAutoConfidence: return 0.90
        case .policyShortAutoMargin: return 0.16
        case .policyBlindHintConfidence: return 0.74
        case .shortWordThreshold: return 0.58
        case .deferredMinConfidence: return thresholds.timing.pendingWordMinConfidence
        case .deferredTimeout: return thresholds.timing.pendingWordTimeout
        case .learningAutoDemoteBelow: return 0.70
        case .learningHintDemoteBelow: return 0.50
        }
    }

    func clamped(_ value: Double) -> Double {
        min(max(value, range.lowerBound), range.upperBound)
    }
}

/// Which parts of the decision are on and the values of its parameters.
struct DecisionPipelineSettings: Sendable, Equatable {
    var disabled: Set<DecisionComponent> = []
    /// Only the parameters the user changed; the rest keep their defaults.
    var values: [DecisionParameter: Double] = [:]

    static let `default` = DecisionPipelineSettings()

    func isEnabled(_ component: DecisionComponent) -> Bool {
        !disabled.contains(component)
    }

    func value(_ parameter: DecisionParameter) -> Double {
        values[parameter].map(parameter.clamped) ?? parameter.defaultValue
    }

    func isChanged(_ parameter: DecisionParameter) -> Bool {
        values[parameter] != nil
    }

    var isDefault: Bool {
        disabled.isEmpty && values.isEmpty
    }

    // MARK: Storage

    private static let disabledKey = "disabled"
    private static let valuesKey = "values"

    /// Reads what `stored` wrote; names it doesn't know (from another version) are skipped.
    init(stored: [String: Any]?) {
        let disabledNames = stored?[Self.disabledKey] as? [String] ?? []
        disabled = Set(disabledNames.compactMap(DecisionComponent.init(rawValue:)))
        let storedValues = stored?[Self.valuesKey] as? [String: Double] ?? [:]
        var values: [DecisionParameter: Double] = [:]
        for (name, value) in storedValues {
            if let parameter = DecisionParameter(rawValue: name) {
                values[parameter] = parameter.clamped(value)
            }
        }
        self.values = values
    }

    init() {}

    /// A property list for UserDefaults.
    var stored: [String: Any] {
        [
            Self.disabledKey: disabled.map(\.rawValue).sorted(),
            Self.valuesKey: Dictionary(uniqueKeysWithValues: values.map { ($0.key.rawValue, $0.value) })
        ]
    }
}

/// The settings every part of the decision reads, wherever it runs: the router and the
/// engine are actors, the word lists and the layout mapper are called synchronously.
/// `SettingsManager` keeps it up to date.
enum DecisionPipeline {
    private final class Storage: @unchecked Sendable {
        private let lock = NSLock()
        private var settings = DecisionPipelineSettings.default

        var current: DecisionPipelineSettings {
            lock.lock()
            defer { lock.unlock() }
            return settings
        }

        func update(_ newValue: DecisionPipelineSettings) {
            lock.lock()
            defer { lock.unlock() }
            settings = newValue
        }
    }

    private static let storage = Storage()

    static var current: DecisionPipelineSettings {
        storage.current
    }

    static func isEnabled(_ component: DecisionComponent) -> Bool {
        storage.current.isEnabled(component)
    }

    static func value(_ parameter: DecisionParameter) -> Double {
        storage.current.value(parameter)
    }

    static func update(_ settings: DecisionPipelineSettings) {
        storage.update(settings)
    }
}
