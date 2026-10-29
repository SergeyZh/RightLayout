import SwiftUI
import Combine

/// The Algorithm page: how a typed word is checked, drawn as a flow of stages. Every
/// part that takes part in the decision has a switch, and the parts with parameters
/// let you change them. A word typed into the test field at the top lights up the
/// blocks that took part in its decision.
struct AlgorithmSettingsView: View {
    @ObservedObject private var settings = SettingsManager.shared
    @StateObject private var playground = DecisionPlaygroundModel()
    @State private var selectedNodeId: String?

    /// What each block did with the word picked in the test field, or nil without one.
    private var trace: [DecisionStep: [DecisionProbeEvent]]? {
        playground.selectedWord.map { Dictionary(grouping: $0.events, by: \.step) }
    }

    private var offCount: Int {
        AlgorithmDiagram.allNodes.filter { !isOn($0) }.count
    }

    private var issues: [AppStatusIssue] {
        guard offCount > 0 else { return [] }
        return [
            AppStatusIssue(
                title: UIStrings.format("Parts of the check turned off: %d", offCount),
                message: UIStrings.text("Words are checked without them: more mistakes may stay uncorrected, or correct words may be changed."),
                severity: .warning
            )
        ]
    }

    var body: some View {
        WorkbenchPage(
            title: "Algorithm",
            subtitle: "How RightLayout decides whether a word was typed in the wrong layout. Click a block to see what it does and to tune it; the switch turns it off.",
            issues: issues,
            accessory: AnyView(
                Button {
                    settings.resetDecisionAlgorithm()
                } label: {
                    Label(UIStrings.text("Restore defaults"), systemImage: "arrow.uturn.backward")
                }
                .buttonStyle(.plain)
                .secondaryActionButton()
                .disabled(isDefault)
            )
        ) {
            PlaygroundPanel(model: playground)

            // Not a step of the flow: every stage looks words up in these.
            stageBox(AlgorithmDiagram.knowledgeSources, number: nil, isReference: true)

            VStack(spacing: 0) {
                TypedWordBadge(word: playground.selectedWord?.typed)

                FlowConnector()

                ForEach(Array(AlgorithmDiagram.stages.enumerated()), id: \.element.id) { index, stage in
                    stageBox(stage, number: index + 1)
                    FlowConnector()
                }

                OutcomesRow(word: playground.selectedWord)
            }

            AlgorithmLegend(showsTrace: trace != nil)
        }
        // A change of a switch or a parameter is seen at once in the test field.
        .onReceive(settings.objectWillChange) { _ in
            playground.schedule()
        }
    }

    private var isDefault: Bool {
        let (fast, standard) = settings.behaviorPreset.thresholds
        return settings.decisionPipeline.isDefault
            && settings.isEnabled
            && settings.isVerifierEnabled
            && settings.isFoundationModelEnabled
            && settings.isLearningEnabled
            && settings.holdEnterForCorrection
            && !settings.transliterationHintsEnabled
            && settings.autoSwitchLayout
            && settings.correctionSoundEnabled
            && abs(settings.fastPathThreshold - fast) < 0.001
            && abs(settings.standardPathThreshold - standard) < 0.001
    }

    @ViewBuilder
    private func stageBox(_ stage: AlgorithmStage, number: Int?, isReference: Bool = false) -> some View {
        let selected = stage.nodes.first { $0.id == selectedNodeId }
        StageBox(
            stage: stage,
            number: number,
            onCount: stage.nodes.filter(isOn).count,
            selectedNodeId: selectedNodeId,
            isOn: isOn,
            isTuned: isTuned,
            binding: { binding(for: $0) },
            onSelect: { node in
                withAnimation(Theme.Motion.fast) {
                    selectedNodeId = selectedNodeId == node.id ? nil : node.id
                }
            },
            trace: trace,
            isReference: isReference
        ) {
            if let selected {
                NodeInspector(
                    node: selected,
                    isOn: isOn(selected),
                    events: trace.map { trace in selected.step.flatMap { trace[$0] } ?? [] },
                    onClose: {
                        withAnimation(Theme.Motion.fast) { selectedNodeId = nil }
                    }
                )
            }
        }
    }

    // MARK: Switches

    private func isOn(_ node: AlgorithmNode) -> Bool {
        switch node.toggle {
        case .component(let component):
            return settings.decisionPipeline.isEnabled(component)
        case .setting(let setting):
            return value(of: setting)
        case .alwaysOn:
            return true
        }
    }

    /// Whether a parameter of the node differs from its default.
    private func isTuned(_ node: AlgorithmNode) -> Bool {
        node.controls.contains { control in
            if case .parameter(let parameter) = control {
                return settings.decisionPipeline.isChanged(parameter)
            }
            return false
        }
    }

    private func binding(for node: AlgorithmNode) -> Binding<Bool>? {
        switch node.toggle {
        case .component(let component):
            return Binding(
                get: { settings.decisionPipeline.isEnabled(component) },
                set: { settings.setDecisionComponent(component, enabled: $0) }
            )
        case .setting(let setting):
            return Binding(
                get: { value(of: setting) },
                set: { setValue($0, of: setting) }
            )
        case .alwaysOn:
            return nil
        }
    }

    private func value(of setting: AlgorithmNode.SettingSwitch) -> Bool {
        switch setting {
        case .autoCorrection: return settings.isEnabled
        case .holdEnter: return settings.holdEnterForCorrection
        case .foundationModel: return settings.isFoundationModelEnabled
        case .verifier: return settings.isVerifierEnabled
        case .learning: return settings.isLearningEnabled
        case .transliterationHints: return settings.transliterationHintsEnabled
        case .layoutSwitch: return settings.autoSwitchLayout
        case .correctionSound: return settings.correctionSoundEnabled
        }
    }

    private func setValue(_ value: Bool, of setting: AlgorithmNode.SettingSwitch) {
        switch setting {
        case .autoCorrection: settings.isEnabled = value
        case .holdEnter: settings.holdEnterForCorrection = value
        case .foundationModel: settings.isFoundationModelEnabled = value
        case .verifier: settings.isVerifierEnabled = value
        case .learning: settings.isLearningEnabled = value
        case .transliterationHints: settings.transliterationHintsEnabled = value
        case .layoutSwitch: settings.autoSwitchLayout = value
        case .correctionSound: settings.correctionSoundEnabled = value
        }
    }
}

// MARK: - Stage

private struct StageBox<Inspector: View>: View {
    let stage: AlgorithmStage
    let number: Int?
    let onCount: Int
    let selectedNodeId: String?
    let isOn: (AlgorithmNode) -> Bool
    let isTuned: (AlgorithmNode) -> Bool
    let binding: (AlgorithmNode) -> Binding<Bool>?
    let onSelect: (AlgorithmNode) -> Void
    var trace: [DecisionStep: [DecisionProbeEvent]]?
    /// Drawn apart from the flow, as something the stages consult rather than pass through.
    var isReference = false
    @ViewBuilder var inspector: Inspector

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: 196), spacing: Theme.Spacing.sm, alignment: .top)]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            HStack(alignment: .top, spacing: Theme.Spacing.md) {
                StageNumber(number: number)

                VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                    HStack(spacing: Theme.Spacing.sm) {
                        Text(UIStrings.text(stage.title))
                            .font(Theme.Typography.bodyStrong())
                            .foregroundStyle(Theme.Color.textPrimary)
                        if isReference {
                            StatusChip(title: "Used by every stage", severity: .info)
                        }
                    }
                    Text(UIStrings.text(stage.detail))
                        .font(Theme.Typography.meta())
                        .foregroundStyle(Theme.Color.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: Theme.Spacing.sm)

                Text(UIStrings.format("%d of %d on", onCount, stage.nodes.count))
                    .font(Theme.Typography.meta())
                    .monospacedDigit()
                    .foregroundStyle(onCount == stage.nodes.count ? Theme.Color.textMeta : Theme.Color.warning)
            }

            LazyVGrid(columns: columns, alignment: .leading, spacing: Theme.Spacing.sm) {
                ForEach(stage.nodes) { node in
                    NodeCard(
                        node: node,
                        isOn: isOn(node),
                        isTuned: isTuned(node),
                        isSelected: node.id == selectedNodeId,
                        binding: binding(node),
                        events: trace.map { trace in node.step.flatMap { trace[$0] } ?? [] },
                        onSelect: { onSelect(node) }
                    )
                }
            }

            inspector
        }
        .padding(Theme.Spacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            if isReference {
                RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous)
                    .fill(Theme.Color.pageBackgroundSecondary)
                    .overlay {
                        RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous)
                            .stroke(Theme.Color.borderStrong, style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
                    }
            } else {
                RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous)
                    .fill(Theme.Color.surfaceRaised)
                    .overlay {
                        RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous)
                            .stroke(Theme.Color.borderSubtle, lineWidth: 1)
                    }
            }
        }
    }
}

private struct StageNumber: View {
    let number: Int?

    var body: some View {
        ZStack {
            Circle()
                .fill(Theme.Color.accent.opacity(0.14))
            if let number {
                Text("\(number)")
                    .font(Theme.Typography.label())
                    .foregroundStyle(Theme.Color.accent)
            } else {
                Image(systemName: "books.vertical")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.Color.accent)
            }
        }
        .frame(width: 26, height: 26)
    }
}

// MARK: - Node

private struct NodeCard: View {
    let node: AlgorithmNode
    let isOn: Bool
    let isTuned: Bool
    let isSelected: Bool
    let binding: Binding<Bool>?
    /// What the block did with the test field's word; nil without one.
    let events: [DecisionProbeEvent]?
    let onSelect: () -> Void

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous)
    }

    private var headline: DecisionProbeEvent? {
        events.flatMap(TraceStyle.headline)
    }

    /// With a word in the test field, blocks it never reached fade out.
    private var opacity: Double {
        guard let events else { return isOn ? 1 : 0.75 }
        return events.isEmpty ? 0.45 : 1
    }

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Spacing.sm) {
            Button(action: onSelect) {
                HStack(alignment: .top, spacing: Theme.Spacing.sm) {
                    Image(systemName: node.systemImage)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(isOn ? Theme.Color.accent : Theme.Color.textMeta)
                        .frame(width: 18, height: 18)

                    VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                        HStack(spacing: Theme.Spacing.xs) {
                            Text(UIStrings.text(node.title))
                                .font(Theme.Typography.label())
                                .strikethrough(!isOn, color: Theme.Color.textMeta)
                                .foregroundStyle(isOn ? Theme.Color.textPrimary : Theme.Color.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                            if node.decidesAlone {
                                Image(systemName: "bolt.fill")
                                    .font(.system(size: 9))
                                    .foregroundStyle(Theme.Color.textMeta)
                                    .help(UIStrings.text("Can settle the decision on its own"))
                            }
                            if isTuned {
                                Image(systemName: "slider.horizontal.below.rectangle")
                                    .font(.system(size: 9))
                                    .foregroundStyle(Theme.Color.warning)
                                    .help(UIStrings.text("Parameters changed"))
                            }
                        }
                        Text(UIStrings.text(node.summary))
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.Color.textSecondary)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                        if let events {
                            // A knowledge source answers for the typed word and for its
                            // conversion: show both, or one looks like the other's answer.
                            if let step = node.step, TraceStyle.knowledgeSteps.contains(step), events.count > 1 {
                                ForEach(events) { event in
                                    TraceLine(event: event, isOn: isOn)
                                }
                            } else {
                                TraceLine(event: headline, isOn: isOn)
                            }
                        }
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if let binding {
                Toggle("", isOn: binding)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .help(UIStrings.text(isOn ? "Turn off" : "Turn on"))
            } else {
                Image(systemName: "lock.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.Color.textMeta)
                    .help(UIStrings.text("Always on"))
            }
        }
        .padding(Theme.Spacing.sm)
        .frame(maxWidth: .infinity, minHeight: 58, alignment: .topLeading)
        .background(isOn ? Theme.Color.surfaceRaised : Theme.Color.pageBackgroundSecondary, in: shape)
        .overlay {
            if isSelected {
                shape.stroke(Theme.Color.accent, lineWidth: 2)
            } else if let headline {
                shape.stroke(TraceStyle.color(headline.effect), lineWidth: headline.effect == .decided ? 2 : 1.5)
            } else if isOn {
                shape.stroke(Theme.Color.borderSubtle, lineWidth: 1)
            } else {
                shape.stroke(Theme.Color.borderStrong, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            }
        }
        .opacity(opacity)
    }
}

// MARK: - Inspector

private struct NodeInspector: View {
    let node: AlgorithmNode
    let isOn: Bool
    /// What the block did with the test field's word; nil without one.
    let events: [DecisionProbeEvent]?
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            HStack(spacing: Theme.Spacing.sm) {
                Image(systemName: node.systemImage)
                    .foregroundStyle(Theme.Color.accent)
                Text(UIStrings.text(node.title))
                    .font(Theme.Typography.bodyStrong())
                    .foregroundStyle(Theme.Color.textPrimary)
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(Theme.Color.textMeta)
                }
                .buttonStyle(.plain)
                .help(UIStrings.text("Close"))
            }

            Text(UIStrings.text(node.detail))
                .font(Theme.Typography.body())
                .foregroundStyle(Theme.Color.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            if node.decidesAlone {
                Label(UIStrings.text("Can settle the decision on its own: when it applies, the rest of the check is skipped."), systemImage: "bolt.fill")
                    .font(Theme.Typography.meta())
                    .foregroundStyle(Theme.Color.textMeta)
            }

            if !isOn {
                Label(UIStrings.text("Turned off: words are checked without this part."), systemImage: "exclamationmark.triangle.fill")
                    .font(Theme.Typography.meta())
                    .foregroundStyle(Theme.Color.warning)
            }

            if let events {
                VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                    Text(UIStrings.text("With the word from the test field"))
                        .font(Theme.Typography.label())
                        .foregroundStyle(Theme.Color.textPrimary)
                    if events.isEmpty {
                        Text(UIStrings.text(isOn ? "Not reached: an earlier block settled the decision, or the word didn't get here." : "Turned off"))
                            .font(Theme.Typography.meta())
                            .foregroundStyle(Theme.Color.textMeta)
                    }
                    ForEach(events) { event in
                        Label {
                            Text(TraceStyle.text(event))
                                .fixedSize(horizontal: false, vertical: true)
                        } icon: {
                            Image(systemName: TraceStyle.symbol(event.effect))
                        }
                        .font(Theme.Typography.meta())
                        .foregroundStyle(TraceStyle.color(event.effect))
                    }
                }
            }

            if node.controls.isEmpty {
                Text(UIStrings.text("This part has no parameters."))
                    .font(Theme.Typography.meta())
                    .foregroundStyle(Theme.Color.textMeta)
            } else {
                VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                    ForEach(node.controls, id: \.self) { control in
                        Divider()
                        ControlRow(control: control)
                    }
                }
                .disabled(!isOn)
            }
        }
        .padding(Theme.Spacing.md)
        .insetContainer()
    }
}

private struct ControlRow: View {
    @ObservedObject var settings = SettingsManager.shared
    let control: AlgorithmNode.Control

    var body: some View {
        switch control {
        case .parameter(let parameter):
            ParameterRow(parameter: parameter)
        case .fastPathThreshold:
            SummaryRow(
                title: "Fast path confidence",
                detail: "The trigrams' answer is taken from this confidence. Set by the correction style; changing it makes the style custom."
            ) {
                ValueSlider(
                    value: $settings.fastPathThreshold,
                    range: 0.50...1.0,
                    step: 0.01,
                    text: percent(settings.fastPathThreshold)
                )
            }
        case .standardPathThreshold:
            SummaryRow(
                title: "Standard path confidence",
                detail: "The ensemble's and the scored decision's answers are taken from this confidence, and corrections below it are deferred. Set by the correction style."
            ) {
                ValueSlider(
                    value: $settings.standardPathThreshold,
                    range: 0.30...1.0,
                    step: 0.01,
                    text: percent(settings.standardPathThreshold)
                )
            }
        case .behaviorPreset:
            SummaryRow(title: "Correction style", detail: settings.behaviorPreset.description) {
                Picker("", selection: $settings.behaviorPreset) {
                    ForEach(SettingsManager.BehaviorPreset.allCases) { preset in
                        Text(LocalizedStringKey(preset.displayName), bundle: settings.resourceBundle).tag(preset)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 180)
            }
        case .minimumWordLength:
            SummaryRow(
                title: "Minimum word length",
                detail: "Shorter words are only corrected with the hotkey. Short words are ambiguous, so they still need high confidence."
            ) {
                Stepper(
                    value: $settings.minAutoCorrectWordLength,
                    in: SettingsManager.autoCorrectWordLengthRange
                ) {
                    Text(UIStrings.format("Letters: %d", settings.minAutoCorrectWordLength))
                        .font(Theme.Typography.body())
                        .monospacedDigit()
                }
                .frame(width: 180, alignment: .trailing)
            }
        case .blindConfidence:
            SummaryRow(
                title: "Confidence in apps without Accessibility",
                detail: "Claude, Slack, VS Code and other Electron apps don't expose their text, so the word is retyped without checking it first. Lower means more corrections, higher means fewer mistakes. The correction style shifts this by ±6%."
            ) {
                ValueSlider(
                    value: $settings.blindAutoCorrectConfidence,
                    range: SettingsManager.blindAutoCorrectConfidenceRange,
                    step: 0.01,
                    text: percent(settings.blindAutoCorrectConfidence)
                )
            }
        case .blindReplayDelay:
            SummaryRow(
                title: "Maximum pause before retyping",
                detail: "In those apps a word isn't retyped if this much time has passed since the last keystroke, so the retype can't land somewhere you moved to."
            ) {
                ValueSlider(
                    value: $settings.blindReplayMaxDelay,
                    range: SettingsManager.blindReplayMaxDelayRange,
                    step: 0.05,
                    text: UIStrings.format("%.2f s", settings.blindReplayMaxDelay)
                )
            }
        }
    }

    private func percent(_ value: Double) -> String {
        "\(Int((value * 100).rounded()))%"
    }
}

private struct ParameterRow: View {
    @ObservedObject var settings = SettingsManager.shared
    let parameter: DecisionParameter

    private var value: Binding<Double> {
        Binding(
            get: { settings.decisionPipeline.value(parameter) },
            set: { newValue in
                // Back at the default, the parameter follows the default again.
                let isDefault = abs(newValue - parameter.defaultValue) < parameter.step / 2
                settings.setDecisionParameter(parameter, to: isDefault ? nil : newValue)
            }
        )
    }

    var body: some View {
        SummaryRow(title: parameter.title, detail: parameter.detail) {
            HStack(spacing: Theme.Spacing.xs) {
                ValueSlider(
                    value: value,
                    range: parameter.range,
                    step: parameter.step,
                    text: Self.format(settings.decisionPipeline.value(parameter), unit: parameter.unit)
                )
                Button {
                    settings.setDecisionParameter(parameter, to: nil)
                } label: {
                    Image(systemName: "arrow.uturn.backward.circle")
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.Color.textSecondary)
                .help(UIStrings.format("Default: %@", Self.format(parameter.defaultValue, unit: parameter.unit)))
                .opacity(settings.decisionPipeline.isChanged(parameter) ? 1 : 0)
                .disabled(!settings.decisionPipeline.isChanged(parameter))
            }
        }
    }

    static func format(_ value: Double, unit: DecisionParameter.Unit) -> String {
        switch unit {
        case .percent:
            return "\(Int((value * 100).rounded()))%"
        case .seconds:
            return UIStrings.format("%.1f s", value)
        }
    }
}

private struct ValueSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let text: String

    var body: some View {
        HStack(spacing: Theme.Spacing.sm) {
            Slider(value: $value, in: range, step: step)
                .frame(width: 150)
            Text(text)
                .font(Theme.Typography.body())
                .monospacedDigit()
                .frame(width: 52, alignment: .trailing)
        }
    }
}

// MARK: - Flow decorations

private struct TypedWordBadge: View {
    /// The test field's word, shown in place of the generic label.
    var word: String?

    var body: some View {
        Label(word.map { "\u{201C}\($0)\u{201D}" } ?? UIStrings.text("Typed word"), systemImage: "character.cursor.ibeam")
            .font(Theme.Typography.label())
            .foregroundStyle(Theme.Color.accent)
            .padding(.horizontal, Theme.Spacing.lg)
            .padding(.vertical, Theme.Spacing.sm)
            .background(Theme.Color.accent.opacity(0.12), in: Capsule())
            .overlay { Capsule().stroke(Theme.Color.accent.opacity(0.5), lineWidth: 1) }
    }
}

/// The arrow from one stage to the next.
private struct FlowConnector: View {
    var body: some View {
        VStack(spacing: 0) {
            Line()
                .stroke(Theme.Color.borderStrong, lineWidth: 2)
                .frame(width: 2, height: 16)
            Image(systemName: "arrowtriangle.down.fill")
                .font(.system(size: 9))
                .foregroundStyle(Theme.Color.borderStrong)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Theme.Spacing.xxs)
    }

    private struct Line: Shape {
        func path(in rect: CGRect) -> Path {
            var path = Path()
            path.move(to: CGPoint(x: rect.midX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
            return path
        }
    }
}

private struct OutcomesRow: View {
    /// The test field's word, whose outcome is lit.
    var word: PlaygroundWord?

    var body: some View {
        VStack(spacing: Theme.Spacing.sm) {
            HStack(spacing: Theme.Spacing.sm) {
                ForEach(AlgorithmDiagram.outcomes) { outcome in
                    let isResult = word.map { outcome.id == TraceStyle.outcomeTitle($0.outcome) } ?? false
                    Label(UIStrings.text(outcome.title), systemImage: outcome.systemImage)
                        .font(Theme.Typography.label())
                        .foregroundStyle(isResult ? SwiftUI.Color.white : Theme.Color.textPrimary)
                        .padding(.horizontal, Theme.Spacing.md)
                        .padding(.vertical, Theme.Spacing.sm)
                        .frame(maxWidth: .infinity)
                        .background(isResult ? Theme.Color.success : Theme.Color.surfaceRaised, in: Capsule())
                        .overlay { Capsule().stroke(isResult ? Theme.Color.success : Theme.Color.borderSubtle, lineWidth: 1) }
                        .opacity(word == nil || isResult ? 1 : 0.5)
                }
            }

            if let word {
                Text(TraceStyle.resultText(word))
                    .font(Theme.Typography.mono())
                    .foregroundStyle(Theme.Color.textPrimary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                if let how = TraceStyle.replacement(of: word) {
                    Text(TraceStyle.text(how))
                        .font(Theme.Typography.meta())
                        .foregroundStyle(TraceStyle.color(how.effect))
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                }
            }
        }
    }
}

private struct AlgorithmLegend: View {
    var showsTrace = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            symbols
            if showsTrace {
                HStack(spacing: Theme.Spacing.lg) {
                    ForEach([DecisionEffect.decided, .contributed, .rejected, .checked], id: \.self) { effect in
                        HStack(spacing: Theme.Spacing.xs) {
                            Image(systemName: TraceStyle.symbol(effect))
                                .font(.system(size: 10))
                                .foregroundStyle(TraceStyle.color(effect))
                            Text(UIStrings.text(TraceStyle.title(effect)))
                        }
                    }
                    HStack(spacing: Theme.Spacing.xs) {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Theme.Color.borderSubtle)
                            .frame(width: 16, height: 10)
                            .opacity(0.45)
                        Text(UIStrings.text("Not reached"))
                    }
                }
                .font(Theme.Typography.meta())
                .foregroundStyle(Theme.Color.textMeta)
            }
        }
    }

    private var symbols: some View {
        HStack(spacing: Theme.Spacing.lg) {
            legendItem("bolt.fill", "Can settle the decision on its own")
            legendItem("lock.fill", "Always on")
            legendItem("slider.horizontal.below.rectangle", "Parameters changed")
            HStack(spacing: Theme.Spacing.xs) {
                RoundedRectangle(cornerRadius: 3)
                    .stroke(Theme.Color.borderStrong, style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
                    .frame(width: 16, height: 10)
                Text(UIStrings.text("Turned off"))
            }
        }
        .font(Theme.Typography.meta())
        .foregroundStyle(Theme.Color.textMeta)
    }

    private func legendItem(_ systemImage: String, _ title: String) -> some View {
        HStack(spacing: Theme.Spacing.xs) {
            Image(systemName: systemImage)
                .font(.system(size: 10))
            Text(UIStrings.text(title))
        }
    }
}

// MARK: - Test field

private struct PlaygroundPanel: View {
    @ObservedObject var model: DecisionPlaygroundModel
    @FocusState private var isFieldFocused: Bool

    private func title(for app: PlaygroundApp) -> String {
        switch app {
        case .readsText: return "TextEdit, Notes, Mail: text read and written"
        case .slack: return "Slack: text read, retyped"
        case .hidesText: return "Claude, VS Code, terminal: text hidden"
        case .unknownHidden: return "Another app that hides its text"
        }
    }

    var body: some View {
        WorkbenchSection(
            title: "Try a word",
            detail: "Type a word or a phrase. Each word is checked the way it would be while you type in the chosen app, with the settings below; the diagram shows what every block did with the selected word, down to how it would be replaced. RightLayout doesn't correct this field, and nothing is learned."
        ) {
            HStack(spacing: Theme.Spacing.sm) {
                TextField(UIStrings.text("For example: ghbdtn rfr ltkf"), text: $model.text)
                    .textFieldStyle(.roundedBorder)
                    .font(Theme.Typography.mono())
                    .focused($isFieldFocused)
                    // RightLayout doesn't correct what is typed here, or it would change
                    // the word being checked.
                    .onChange(of: isFieldFocused) { focused in
                        DecisionPlaygroundFocus.isFocused = focused
                    }
                    .onDisappear {
                        DecisionPlaygroundFocus.isFocused = false
                    }
                if model.isChecking {
                    ProgressView()
                        .controlSize(.small)
                }
                if !model.text.isEmpty {
                    Button {
                        model.text = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(Theme.Color.textMeta)
                    }
                    .buttonStyle(.plain)
                    .help(UIStrings.text("Clear"))
                }
            }

            HStack(spacing: Theme.Spacing.lg) {
                Picker("", selection: $model.app) {
                    ForEach(PlaygroundApp.allCases) { app in
                        Text(UIStrings.text(title(for: app))).tag(app)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 340)
                .help(UIStrings.text("Where the word is typed: it decides how careful the check is and how the correction is put into the text."))

                Toggle(UIStrings.text("Ends with Enter"), isOn: $model.endsWithEnter)
                    .toggleStyle(.checkbox)
                    .font(Theme.Typography.body())

                Spacer()
            }

            if !model.words.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: Theme.Spacing.sm) {
                        ForEach(model.words) { word in
                            WordChip(
                                word: word,
                                isSelected: word.id == model.selectedWord?.id,
                                onSelect: { model.selectedWordId = word.id }
                            )
                        }
                    }
                }
            }
        }
    }
}

private struct WordChip: View {
    let word: PlaygroundWord
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: Theme.Spacing.xs) {
                Circle()
                    .fill(TraceStyle.color(word.outcome))
                    .frame(width: 7, height: 7)
                Text(word.shown == word.typed ? word.typed : "\(word.typed) → \(word.shown)")
                    .font(Theme.Typography.mono())
                    .foregroundStyle(Theme.Color.textPrimary)
            }
            .padding(.horizontal, Theme.Spacing.md)
            .padding(.vertical, Theme.Spacing.xs)
            .background(Theme.Color.surfaceRaised, in: Capsule())
            .overlay {
                Capsule().stroke(isSelected ? Theme.Color.accent : Theme.Color.borderSubtle, lineWidth: isSelected ? 2 : 1)
            }
        }
        .buttonStyle(.plain)
        .help(UIStrings.text(TraceStyle.outcomeTitle(word.outcome)))
    }
}

/// The line on a block that says what it did with the test field's word.
private struct TraceLine: View {
    let event: DecisionProbeEvent?
    let isOn: Bool

    var body: some View {
        if let event {
            HStack(alignment: .top, spacing: Theme.Spacing.xs) {
                Image(systemName: TraceStyle.symbol(event.effect))
                    .font(.system(size: 10))
                Text(TraceStyle.text(event))
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .foregroundStyle(TraceStyle.color(event.effect))
            .padding(.top, Theme.Spacing.xxs)
        } else {
            Text(UIStrings.text(isOn ? "Not reached" : "Turned off"))
                .font(.system(size: 11))
                .foregroundStyle(Theme.Color.textMeta)
                .padding(.top, Theme.Spacing.xxs)
        }
    }
}

/// How the trace of a word is drawn and worded.
enum TraceStyle {
    /// The knowledge sources, which report on each word they were asked about.
    static let knowledgeSteps: Set<DecisionStep> = [.builtinLexicon, .frequencyDictionaries, .systemSpellChecker, .trigramModel]

    /// The event a block is summed up by: its strongest effect, the latest of those.
    static func headline(_ events: [DecisionProbeEvent]) -> DecisionProbeEvent? {
        guard let strongest = events.map(\.effect).max() else { return nil }
        return events.last { $0.effect == strongest }
    }

    static func text(_ event: DecisionProbeEvent) -> String {
        let format = UIStrings.text(event.note.rawValue)
        guard !event.arguments.isEmpty else { return format }
        return String(format: format, locale: Locale.current, arguments: event.arguments.map { $0 as CVarArg })
    }

    static func symbol(_ effect: DecisionEffect) -> String {
        switch effect {
        case .checked: return "checkmark.circle"
        case .contributed: return "plus.circle.fill"
        case .rejected: return "xmark.circle.fill"
        case .decided: return "flag.fill"
        }
    }

    static func color(_ effect: DecisionEffect) -> SwiftUI.Color {
        switch effect {
        case .checked: return Theme.Color.textSecondary
        case .contributed: return Theme.Color.accent
        case .rejected: return Theme.Color.warning
        case .decided: return Theme.Color.success
        }
    }

    static func title(_ effect: DecisionEffect) -> String {
        switch effect {
        case .checked: return "Checked, no effect"
        case .contributed: return "Contributed"
        case .rejected: return "Proposed, rejected"
        case .decided: return "Decided"
        }
    }

    static func color(_ outcome: PlaygroundWord.Outcome) -> SwiftUI.Color {
        switch outcome {
        case .replace: return Theme.Color.success
        case .suggest: return Theme.Color.accent
        case .hotkeyOnly: return Theme.Color.warning
        case .leave: return Theme.Color.textMeta
        }
    }

    /// The title of the outcome pill (`AlgorithmDiagram.outcomes`).
    static func outcomeTitle(_ outcome: PlaygroundWord.Outcome) -> String {
        switch outcome {
        case .replace: return "Replace"
        case .suggest: return "Suggest"
        case .hotkeyOnly: return "Hotkey only"
        case .leave: return "Leave as typed"
        }
    }

    /// How the word is put into the text, or why it isn't.
    static func replacement(of word: PlaygroundWord) -> DecisionProbeEvent? {
        let steps: [DecisionStep] = [.accessibilityWrite, .verifiedRetype, .blindRetype]
        return word.events.last { steps.contains($0.step) && $0.effect != .checked && !($0.step == .accessibilityWrite && $0.effect == .rejected) }
    }

    static func resultText(_ word: PlaygroundWord) -> String {
        let confidence = word.confidence.map { " · " + DecisionProbe.percent($0) } ?? ""
        switch word.outcome {
        case .replace:
            return "\(word.typed) → \(word.shown)\(confidence)"
        case .suggest, .hotkeyOnly:
            if let proposed = word.proposed {
                return "\(word.typed) → \(proposed)?\(confidence)"
            }
            return word.typed + confidence
        case .leave:
            return word.shown == word.typed ? word.typed : "\(word.typed) → \(word.shown)"
        }
    }
}
