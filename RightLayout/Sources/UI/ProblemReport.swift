import Foundation

/// A plain-text report of the last minutes: settings, decisions, and the detailed log.
@MainActor
enum ProblemReport {
    static let window: TimeInterval = 5 * 60

    static func make(now: Date = Date()) -> String {
        let settings = SettingsManager.shared
        let since = now.addingTimeInterval(-window)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        let time = { (date: Date) in formatter.string(from: date) }

        var lines: [String] = []
        lines.append("RightLayout problem report")
        lines.append("Created: \(time(now))")
        lines.append("Version: \(AppVersionResolver.current())")
        lines.append("Build: \(AppVersionResolver.buildCommit() ?? "unknown")")
        lines.append("macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)")
        lines.append("Working languages: \(settings.enabledLanguages.map(\.rawValue).sorted().joined(separator: ", "))")
        lines.append("Layouts: \(settings.activeLayouts.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ", "))")
        lines.append("Current input source: \(InputSourceManager.shared.currentLayoutId() ?? "unknown")")
        lines.append("Preset: \(settings.behaviorPreset.rawValue), manual trigger: \(settings.manualTriggerMode.rawValue), switch layout: \(settings.autoSwitchLayout), hold Enter: \(settings.holdEnterForCorrection)")
        lines.append("Detailed log: \(settings.isDetailedLogEnabled ? "on" : "off")")

        lines.append("")
        lines.append("Decisions, last \(Int(window / 60)) minutes, oldest first:")
        let decisions = DecisionLogStore.shared.entries.filter { $0.timestamp >= since }
        if decisions.isEmpty {
            lines.append("  (none)")
        }
        for entry in decisions {
            let confidence = entry.confidence.map { String(format: "%.0f%%", $0 * 100) } ?? "—"
            lines.append("[\(time(entry.timestamp))] \(entry.action) \(entry.token) conf=\(confidence) app=\(entry.appName ?? "—") hyp=\(entry.hypothesis ?? "—")")
        }

        lines.append("")
        lines.append("Detailed log, last \(Int(window / 60)) minutes, oldest first:")
        let journal = DiagnosticJournal.shared.entries(since: since)
        if journal.isEmpty {
            lines.append(settings.isDetailedLogEnabled
                ? "  (empty)"
                : "  (off: turn on Detailed log, repeat what went wrong, and copy the report again)")
        }
        for entry in journal {
            lines.append("[\(time(entry.timestamp))] \(entry.message)")
        }
        return lines.joined(separator: "\n")
    }
}
