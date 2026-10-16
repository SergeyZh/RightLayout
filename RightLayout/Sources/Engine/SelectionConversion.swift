import Foundation

/// The last manual conversion of selected text. Converting the text it produced again
/// (the user re-selects it and presses the hotkey) gives back exactly what was there,
/// instead of a fresh word-by-word guess that can leave some words converted
/// ("byathtyc b j,cke;bdfnm" → "byathtyc b обслуживать").
package struct SelectionConversion: Equatable, Sendable {
    package let original: String
    package let replacement: String

    package init(original: String, replacement: String) {
        self.original = original
        self.replacement = replacement
    }

    /// The text that converting `selected` should restore, if `selected` is what this
    /// conversion produced. Whitespace around the selection is kept as selected.
    package func reverting(_ selected: String) -> String? {
        let core = Self.trimmed(selected)
        guard !core.isEmpty,
              FocusedTextContextService.comparable(core) == FocusedTextContextService.comparable(Self.trimmed(replacement)) else {
            return nil
        }
        let leading = selected.prefix(while: { $0.isWhitespace || $0.isNewline })
        let trailing = String(selected.reversed().prefix(while: { $0.isWhitespace || $0.isNewline }).reversed())
        return leading + Self.trimmed(original) + trailing
    }

    /// The language whose script dominates `text`.
    package static func dominantLanguage(of text: String) -> Language? {
        var latin = 0, cyrillic = 0, hebrew = 0
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x0041...0x005A, 0x0061...0x007A: latin += 1
            case 0x0400...0x04FF: cyrillic += 1
            case 0x0590...0x05FF: hebrew += 1
            default: continue
            }
        }
        let best = max(latin, cyrillic, hebrew)
        guard best > 0 else { return nil }
        if best == cyrillic { return .russian }
        if best == hebrew { return .hebrew }
        return .english
    }

    private static func trimmed(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
