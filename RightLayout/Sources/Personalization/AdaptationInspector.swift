import Foundation
import AppKit

/// What adaptation has learned, in readable form: in which apps corrections were kept or
/// undone, and what that now does to new corrections there.
struct AdaptationSnapshot: Sendable {
    /// Corrections kept and undone in one app, kind of text and time of day
    /// (`RiskController`). This is what turns corrections into suggestions.
    struct Demotion: Identifiable, Sendable {
        let id: String
        let app: String
        let bundleId: String?
        /// "prose", "code" or "url"; nil if it couldn't be told.
        let textKind: String?
        /// 0 night (0–6), 1 day (7–18), 2 evening (19–23); nil if it couldn't be told.
        let timeOfDay: Int?
        let kept: Double
        let undone: Double
        let lastUpdate: Date
        /// What an automatic correction becomes here.
        let correctionBecomes: RiskPolicy
        /// What a suggestion becomes here.
        let suggestionBecomes: RiskPolicy

        var demotes: Bool {
            correctionBecomes != .autoApply || suggestionBecomes != .suggestHint
        }
    }

    /// Layout scores learned for one app (`PersonalizationStore`).
    struct LayoutPreference: Identifiable, Sendable {
        let id: Int
        let app: String
        let bundleId: String?
        /// Layout ("ru", "en", "he") → score; below −3 its corrections become suggestions.
        let scores: [String: Double]

        var demotedLayouts: [String] {
            scores.filter { $0.value <= -3.0 }.keys.sorted()
        }
    }

    /// How often one language followed others in a sentence in one app
    /// (`SentencePatternTracker`).
    struct SentencePatterns: Identifiable, Sendable {
        struct Pattern: Identifiable, Sendable {
            var id: String { text }
            let text: String
            let count: Int
        }

        var id: String { bundleId }
        let app: String
        let bundleId: String
        /// Most frequent first.
        let patterns: [Pattern]
    }

    let demotions: [Demotion]
    let layoutPreferences: [LayoutPreference]
    let sentencePatterns: [SentencePatterns]
    let learningEvents: Int

    var isEmpty: Bool {
        demotions.isEmpty && layoutPreferences.isEmpty && sentencePatterns.isEmpty && learningEvents == 0
    }

    static let empty = AdaptationSnapshot(demotions: [], layoutPreferences: [], sentencePatterns: [], learningEvents: 0)
}

enum AdaptationInspector {
    /// Where the learned data is kept.
    static var storageDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("com.sergeyzh.rightlayout")
    }

    /// Reads everything adaptation has learned. The data is stored under hashes of the
    /// app; they are matched against the apps installed or running here.
    static func snapshot() async -> AdaptationSnapshot {
        let risk = await RiskController.shared.allStates()
        let priors = await PersonalizationStore.shared.allPriors()
        let events = await PersonalizationStore.shared.getStats().events
        let patterns = await SentencePatternTracker.shared.allPatterns()

        let names = await knownApps()
        let extractor = FeatureExtractor()
        var hashes: [AppContextHashes] = []
        for bundleId in Set(names.keys).union(patterns.keys) {
            hashes.append(await extractor.contextHashes(forBundleId: bundleId))
        }
        return assemble(risk: risk, priors: priors, learningEvents: events, patterns: patterns, apps: hashes, names: names)
    }

    /// Forgets everything adaptation has learned.
    static func reset() async {
        await RiskController.shared.reset()
        await PersonalizationStore.shared.reset()
        await OnlineAdapter.shared.reset()
        await SentencePatternTracker.shared.reset()
    }

    static func assemble(
        risk: [ContextKey: RiskState],
        priors: [Int: [String: Double]],
        learningEvents: Int,
        patterns: [String: [String: Int]],
        apps: [AppContextHashes],
        names: [String: String]
    ) -> AdaptationSnapshot {
        var appByHash: [Int: String] = [:]
        var intentByHash: [Int: String] = [:]
        var timeByHash: [Int: Int] = [:]
        for app in apps {
            appByHash[app.app] = app.bundleId
            for (intent, hash) in app.intents { intentByHash[hash] = intent }
            for (bucket, hash) in app.timeBuckets { timeByHash[hash] = bucket }
        }
        func appName(_ bundleId: String?, hash: Int) -> String {
            guard let bundleId else {
                return "#" + String(UInt(bitPattern: hash), radix: 16).prefix(6)
            }
            return names[bundleId] ?? bundleId
        }

        let demotions = risk.map { key, state -> AdaptationSnapshot.Demotion in
            let bundleId = appByHash[key.app]
            return AdaptationSnapshot.Demotion(
                id: "\(key.app):\(key.appIntent):\(key.appTime)",
                app: appName(bundleId, hash: key.app),
                bundleId: bundleId,
                textKind: intentByHash[key.appIntent],
                timeOfDay: timeByHash[key.appTime],
                // Every context starts from one kept and one undone; an undo weighs 1.25.
                kept: max(0, state.alpha - 1.0),
                undone: max(0, (state.beta - 1.0) / 1.25),
                lastUpdate: state.lastUpdate,
                correctionBecomes: RiskController.demote(policy: .autoApply, state: state),
                suggestionBecomes: RiskController.demote(policy: .suggestHint, state: state)
            )
        }
        .sorted {
            if $0.demotes != $1.demotes { return $0.demotes }
            return $0.lastUpdate > $1.lastUpdate
        }

        let preferences = priors.map { hash, scores in
            let bundleId = appByHash[hash]
            return AdaptationSnapshot.LayoutPreference(
                id: hash,
                app: appName(bundleId, hash: hash),
                bundleId: bundleId,
                scores: scores
            )
        }
        .sorted { $0.app.localizedCaseInsensitiveCompare($1.app) == .orderedAscending }

        let sentencePatterns = patterns.compactMap { bundleId, counts -> AdaptationSnapshot.SentencePatterns? in
            guard !counts.isEmpty else { return nil }
            let sorted = counts
                .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
                .map { AdaptationSnapshot.SentencePatterns.Pattern(text: $0.key, count: $0.value) }
            return AdaptationSnapshot.SentencePatterns(app: names[bundleId] ?? bundleId, bundleId: bundleId, patterns: sorted)
        }
        .sorted { $0.app.localizedCaseInsensitiveCompare($1.app) == .orderedAscending }

        return AdaptationSnapshot(
            demotions: demotions,
            layoutPreferences: preferences,
            sentencePatterns: sentencePatterns,
            learningEvents: learningEvents
        )
    }

    /// Bundle identifier → name of the apps running or installed in the usual places.
    private static func knownApps() async -> [String: String] {
        var names: [String: String] = await MainActor.run {
            var running: [String: String] = [:]
            for app in NSWorkspace.shared.runningApplications {
                if let id = app.bundleIdentifier {
                    running[id] = app.localizedName ?? id
                }
            }
            return running
        }

        let fileManager = FileManager.default
        let folders = [
            URL(fileURLWithPath: "/Applications"),
            URL(fileURLWithPath: "/Applications/Utilities"),
            URL(fileURLWithPath: "/System/Applications"),
            URL(fileURLWithPath: "/System/Applications/Utilities"),
            fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Applications")
        ]
        for folder in folders {
            guard let items = try? fileManager.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else {
                continue
            }
            for item in items where item.pathExtension == "app" {
                guard let id = Bundle(url: item)?.bundleIdentifier, names[id] == nil else { continue }
                names[id] = item.deletingPathExtension().lastPathComponent
            }
        }
        return names
    }
}
