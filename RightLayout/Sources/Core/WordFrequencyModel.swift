import Foundation

/// Compact word frequency model loaded from bundled resources.
/// File format: `word<TAB>count` (sorted by descending count).
struct WordFrequencyModel: Sendable {
    private let logCountByWord: [String: Float]
    private let invMaxLogCount: Float

    static let minimumWordLength = 3

    /// Returns the bundled model for `lang` ("en", "ru", "he"), parsing it at most once per process.
    /// The lists are ~200k lines each and several components consult them, so they share one copy.
    static func shared(_ lang: String) -> WordFrequencyModel? {
        cache.model(for: lang)
    }

    private static let cache = Cache()

    private final class Cache: @unchecked Sendable {
        private let lock = NSLock()
        private var models: [String: WordFrequencyModel?] = [:]

        func model(for lang: String) -> WordFrequencyModel? {
            lock.lock()
            defer { lock.unlock() }
            if let cached = models[lang] { return cached }
            let model = try? WordFrequencyModel.loadLanguage(lang)
            models[lang] = .some(model)
            return model
        }
    }

    private static func resourceURL(_ lang: String) -> URL? {
        #if SWIFT_PACKAGE
        let bundle = Bundle.module
        #else
        let bundle = Bundle.main
        #endif
        // SwiftPM's `.process` rule flattens Resources/LanguageModels into the bundle root,
        // while an Xcode folder reference would keep the subdirectory, so try both.
        return bundle.url(forResource: "\(lang)_unigrams", withExtension: "tsv")
            ?? bundle.url(forResource: "\(lang)_unigrams", withExtension: "tsv", subdirectory: "LanguageModels")
    }

    static func loadLanguage(_ lang: String) throws -> WordFrequencyModel {
        guard let url = resourceURL(lang) else {
            throw LexiconError.resourceNotFound(lang)
        }

        let data = try Data(contentsOf: url)
        guard let text = String(data: data, encoding: .utf8) else {
            throw LexiconError.invalidFormat("Non-UTF8 TSV for \(lang)")
        }

        var out: [String: Float] = [:]
        out.reserveCapacity(200_000)

        var maxLog: Float = 0.0
        var hasMax = false
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let parts = line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: true)
            guard parts.count == 2 else { continue }
            let wordRaw = parts[0]
            let countRaw = parts[1]
            guard !wordRaw.isEmpty, let count = Float(countRaw) else { continue }

            let word = wordRaw.lowercased()
            // Log-scale frequencies to preserve big differences among the top words.
            let logCount = log1p(count)

            if !hasMax {
                maxLog = logCount
                hasMax = true
            }

            // One- and two-letter entries are mostly abbreviations and noise ("пп", "gg", "cj"),
            // and short tokens are exactly where layouts collide, so leave them to the curated
            // lexicon in language_data.json.
            guard word.count >= minimumWordLength else { continue }

            // Keep the first (highest-frequency) occurrence in case of duplicates.
            if out[word] == nil {
                out[word] = logCount
            }
        }

        let invMax = maxLog > 0 ? (1.0 / maxLog) : 1.0
        return WordFrequencyModel(logCountByWord: out, invMaxLogCount: invMax)
    }

    /// Score in [0, 1]. Unknown words score 0.
    func score(_ word: String) -> Double {
        let key = word.lowercased()
        guard let v = logCountByWord[key] else { return 0.0 }
        return Double(v * invMaxLogCount)
    }

    func contains(_ word: String) -> Bool {
        logCountByWord[word.lowercased()] != nil
    }
}

enum LexiconError: Error {
    case resourceNotFound(String)
    case invalidFormat(String)
}
