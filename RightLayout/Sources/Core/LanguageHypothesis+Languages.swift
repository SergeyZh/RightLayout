import Foundation

extension LanguageHypothesis {
    /// Layout the text was typed in, for hypotheses that describe a layout mistake.
    var sourceLanguage: Language? {
        switch self {
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

    /// Whether this hypothesis only involves languages the user works with.
    /// "As-is" hypotheses never change text and are always allowed.
    func isAllowed(in enabledLanguages: Set<Language>) -> Bool {
        guard let sourceLanguage else { return true }
        return enabledLanguages.contains(sourceLanguage) && enabledLanguages.contains(targetLanguage)
    }
}
