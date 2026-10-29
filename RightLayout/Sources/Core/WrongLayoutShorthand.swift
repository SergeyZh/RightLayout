import Foundation

/// Tokens typed in the wrong layout that are not words, so the language models can't
/// judge them: Russian abbreviations typed on the English layout ("n/r/" is "т.к." on
/// the Russian PC layout) and emoticons typed on the Russian one ("Ж-)" is ":-)").
/// Only exact matches against short lists count, so nothing else is touched.
enum WrongLayoutShorthand {
    struct Match: Equatable {
        let text: String
        let from: Language
        let to: Language
    }

    static let russianAbbreviations: Set<String> = [
        "т.е.", "т.к.", "т.д.", "т.п.", "т.н.", "т.ч.", "т.о.", "т.з.",
        "и.о.", "н.э.", "с.г.", "к.т.н.", "д.т.н."
    ]

    static let emoticons: Set<String> = [
        ":)", ":-)", ":))", ":-))", ":)))", ";)", ";-)", ":(", ":-(", ":((", ":'(",
        ":D", ":-D", ";D", ":P", ":-P", ":p", ":-p", ";P", ";-P",
        ":O", ":-O", ":o", ":-o", ":*", ":-*", ":|", ":-|", ":-/", ":-\\",
        ":]", ":-]", ":[", ":-["
    ]

    static func match(
        _ token: String,
        enabledLanguages: Set<Language>,
        activeLayouts: [String: String]
    ) -> Match? {
        guard token.count >= 2, token.count <= 12, token.contains(where: \.isLetter) else { return nil }

        if enabledLanguages.contains(.english), DecisionPipeline.isEnabled(.emoticons) {
            for source in [Language.russian, .hebrew] where enabledLanguages.contains(source) {
                for (_, converted) in LayoutMapper.shared.convertAllVariants(
                    token, from: source, to: .english, activeLayouts: activeLayouts
                ) where converted != token && emoticons.contains(converted) {
                    return Match(text: converted, from: source, to: .english)
                }
            }
        }

        // An abbreviation ends with its period: "n/r" without one may be English shorthand.
        if enabledLanguages.contains(.russian), enabledLanguages.contains(.english), token.contains("/"),
           DecisionPipeline.isEnabled(.abbreviations) {
            for (_, converted) in LayoutMapper.shared.convertAllVariants(
                token, from: .english, to: .russian, activeLayouts: activeLayouts
            ) where converted.hasSuffix(".") && russianAbbreviations.contains(converted.lowercased()) {
                return Match(text: converted, from: .english, to: .russian)
            }
        }
        return nil
    }

    /// Emoticons are not written in a language: correcting one keeps the current layout.
    static func isEmoticon(_ text: String) -> Bool {
        emoticons.contains(text)
    }
}
