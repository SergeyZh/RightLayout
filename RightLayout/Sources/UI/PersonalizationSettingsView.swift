import SwiftUI
import AppKit

struct PersonalizationSettingsView: View {
    @ObservedObject var settings: SettingsManager
    @State private var snapshot = AdaptationSnapshot.empty
    @State private var showingResetAlert = false

    var body: some View {
        WorkbenchPage(
            title: "Adaptation",
            subtitle: "Keep learning conservative, visible, and reversible. This area is for demotion and explicit rules, not hidden cleverness.",
            issues: []
        ) {
            WorkbenchSection(title: "Adaptive behavior", detail: "These settings should only make the engine safer, never more aggressive.") {
                SettingsToggleRow(
                    title: "Enable conservative adaptation",
                    detail: "Locally remembers risky contexts and demotes future auto-corrections instead of promoting them.",
                    isOn: $settings.isLearningEnabled
                )

                Divider()

                SettingsToggleRow(
                    title: "Enable transliteration suggestions",
                    detail: "Shows a bounded hint for transliterated Latin input, but never auto-applies it.",
                    isOn: $settings.transliterationHintsEnabled
                )
            }

            WorkbenchSection(title: "State and reset", detail: "Adaptation should be auditable and easy to clear when behavior drifts.") {
                HStack(spacing: Theme.Spacing.md) {
                    MetricTile(label: "Active contexts", value: "\(snapshot.demotions.count + snapshot.layoutPreferences.count)")
                    MetricTile(label: "Learning events", value: "\(snapshot.learningEvents)")
                    MetricTile(
                        label: "Demoting contexts",
                        value: "\(snapshot.demotions.filter(\.demotes).count)",
                        detail: settings.isLearningEnabled ? "Demotion only" : "Disabled"
                    )
                }

                SummaryRow(title: "Learned data files", detail: "Everything adaptation keeps is stored locally in these files.") {
                    Button {
                        NSWorkspace.shared.open(AdaptationInspector.storageDirectory)
                    } label: {
                        Text("Show in Finder", bundle: settings.resourceBundle)
                    }
                    .buttonStyle(.plain)
                    .secondaryActionButton()
                }

                SummaryRow(title: "Reset personalization", detail: "Deletes everything adaptation has learned: kept and undone corrections, layout preferences and sentence patterns. Manual rules remain separate below.") {
                    Button(role: .destructive) {
                        showingResetAlert = true
                    } label: {
                        Text("Reset adaptation", bundle: settings.resourceBundle)
                    }
                    .buttonStyle(.plain)
                    .secondaryActionButton()
                    .disabled(snapshot.isEmpty)
                }
            }

            WorkbenchSection(
                title: "What adaptation has learned",
                detail: "Read from the stored data. Learning only makes corrections more cautious: where they were often undone, they become suggestions, and then hotkey-only.",
                accessory: AnyView(
                    Button {
                        Task { await refresh() }
                    } label: {
                        Text("Refresh", bundle: settings.resourceBundle)
                    }
                    .buttonStyle(.plain)
                    .secondaryActionButton()
                )
            ) {
                AdaptationDataView(snapshot: snapshot)
            }

            WorkbenchSection(title: "Manual rules", detail: "Explicit dictionary rules are the only durable way to force behavior for specific words or phrases.") {
                UserDictionaryView()
                    .frame(minHeight: 320)
            }
        }
        .task {
            await refresh()
        }
        .alert(Text("Reset personalization?", bundle: settings.resourceBundle), isPresented: $showingResetAlert) {
            Button(role: .cancel) { } label: {
                Text("Cancel", bundle: settings.resourceBundle)
            }
            Button(role: .destructive) {
                Task {
                    await AdaptationInspector.reset()
                    await refresh()
                }
            } label: {
                Text("Reset", bundle: settings.resourceBundle)
            }
        } message: {
            Text("This clears local learned habits and conservative adaptation data. Manual dictionary rules remain managed separately.", bundle: settings.resourceBundle)
        }
    }

    private func refresh() async {
        snapshot = await AdaptationInspector.snapshot()
    }
}

/// The learned data itself: per app, how corrections fared and what that does now.
private struct AdaptationDataView: View {
    let snapshot: AdaptationSnapshot

    var body: some View {
        if snapshot.isEmpty {
            Text(UIStrings.text("Nothing learned yet."))
                .font(Theme.Typography.body())
                .foregroundStyle(Theme.Color.textSecondary)
        } else {
            VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                if !snapshot.demotions.isEmpty {
                    group(
                        title: "Corrections kept and undone",
                        detail: "By app, kind of text and time of day. A context starts trusted; corrections undone there make it cautious."
                    ) {
                        ForEach(snapshot.demotions) { demotion in
                            demotionRow(demotion)
                        }
                    }
                }

                if !snapshot.layoutPreferences.isEmpty {
                    group(
                        title: "Layout scores by app",
                        detail: "Raised when a correction to a layout is kept, lowered when it is undone. At −3 or below, corrections to that layout become suggestions in that app."
                    ) {
                        ForEach(snapshot.layoutPreferences) { preference in
                            preferenceRow(preference)
                        }
                    }
                }

                if !snapshot.sentencePatterns.isEmpty {
                    group(
                        title: "Sentence patterns by app",
                        detail: "Which language usually follows which in a sentence. A pattern seen often makes the next word's language more certain."
                    ) {
                        ForEach(snapshot.sentencePatterns) { app in
                            patternsRow(app)
                        }
                    }
                }
            }
        }
    }

    private func group<Content: View>(title: String, detail: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            Text(UIStrings.text(title))
                .font(Theme.Typography.bodyStrong())
                .foregroundStyle(Theme.Color.textPrimary)
            Text(UIStrings.text(detail))
                .font(Theme.Typography.meta())
                .foregroundStyle(Theme.Color.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                content()
            }
        }
    }

    private func demotionRow(_ demotion: AdaptationSnapshot.Demotion) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.md) {
            VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                Text(demotion.app)
                    .font(Theme.Typography.label())
                    .foregroundStyle(Theme.Color.textPrimary)
                Text(contextLine(demotion))
                    .font(Theme.Typography.meta())
                    .foregroundStyle(Theme.Color.textSecondary)
            }
            Spacer()
            Text(UIStrings.format("kept %@ · undone %@", Self.amount(demotion.kept), Self.amount(demotion.undone)))
                .font(Theme.Typography.mono())
                .foregroundStyle(Theme.Color.textSecondary)
            StatusChip(title: effect(demotion), severity: demotion.demotes ? .warning : .info)
        }
    }

    private func contextLine(_ demotion: AdaptationSnapshot.Demotion) -> String {
        var parts: [String] = []
        switch demotion.textKind {
        case "prose": parts.append(UIStrings.text("text"))
        case "code": parts.append(UIStrings.text("code"))
        case "url": parts.append(UIStrings.text("links and commands"))
        default: break
        }
        switch demotion.timeOfDay {
        case 0: parts.append(UIStrings.text("night (0–6)"))
        case 1: parts.append(UIStrings.text("day (7–18)"))
        case 2: parts.append(UIStrings.text("evening (19–23)"))
        default: break
        }
        parts.append(UIStrings.format("last change %@", demotion.lastUpdate.formatted(date: .abbreviated, time: .shortened)))
        return parts.joined(separator: " · ")
    }

    private func effect(_ demotion: AdaptationSnapshot.Demotion) -> String {
        if demotion.correctionBecomes != .autoApply {
            return demotion.suggestionBecomes == .holdForHotkey
                ? "Corrections become hotkey-only"
                : "Corrections become suggestions"
        }
        return "No effect"
    }

    private func preferenceRow(_ preference: AdaptationSnapshot.LayoutPreference) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.md) {
            Text(preference.app)
                .font(Theme.Typography.label())
                .foregroundStyle(Theme.Color.textPrimary)
            Spacer()
            Text(preference.scores.sorted { $0.key < $1.key }.map { "\($0.key) \(Self.signed($0.value))" }.joined(separator: "  "))
                .font(Theme.Typography.mono())
                .foregroundStyle(Theme.Color.textSecondary)
            StatusChip(
                title: preference.demotedLayouts.isEmpty ? "No effect" : "Corrections become suggestions",
                severity: preference.demotedLayouts.isEmpty ? .info : .warning
            )
        }
    }

    private func patternsRow(_ app: AdaptationSnapshot.SentencePatterns) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
            HStack {
                Text(app.app)
                    .font(Theme.Typography.label())
                    .foregroundStyle(Theme.Color.textPrimary)
                Spacer()
                Text(UIStrings.format("%d patterns", app.patterns.count))
                    .font(Theme.Typography.meta())
                    .foregroundStyle(Theme.Color.textSecondary)
            }
            Text(app.patterns.prefix(5).map { "\($0.text.replacingOccurrences(of: "->", with: " → ")) ×\($0.count)" }.joined(separator: "   "))
                .font(Theme.Typography.mono())
                .foregroundStyle(Theme.Color.textSecondary)
                .textSelection(.enabled)
        }
    }

    private static func amount(_ value: Double) -> String {
        String(format: "%.1f", value)
    }

    private static func signed(_ value: Double) -> String {
        String(format: "%+.1f", value)
    }
}
