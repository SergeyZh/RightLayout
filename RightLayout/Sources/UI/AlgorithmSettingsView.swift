import SwiftUI

/// The Algorithm page: how a typed word is checked, drawn as a flow of stages. Every
/// part that takes part in the decision has a switch, and the parts with parameters
/// let you change them.
struct AlgorithmSettingsView: View {
    @ObservedObject private var settings = SettingsManager.shared
    @State private var selectedNodeId: String?

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
            // Not a step of the flow: every stage looks words up in these.
            stageBox(AlgorithmDiagram.knowledgeSources, number: nil, isReference: true)

            VStack(spacing: 0) {
                TypedWordBadge()

                FlowConnector()

                ForEach(Array(AlgorithmDiagram.stages.enumerated()), id: \.element.id) { index, stage in
                    stageBox(stage, number: index + 1)
                    FlowConnector()
                }

                OutcomesRow()
            }

            AlgorithmLegend()
        }
    }

    private var isDefault: Bool {
        let (fast, standard) = settings.behaviorPreset.thresholds
        return settings.decisionPipeline.isDefault
            && settings.isVerifierEnabled
            && settings.isFoundationModelEnabled
            && settings.isLearningEnabled
            && settings.holdEnterForCorrection
            && !settings.transliterationHintsEnabled
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
            isReference: isReference
        ) {
            if let selected {
                NodeInspector(
                    node: selected,
                    isOn: isOn(selected),
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
        case .holdEnter: return settings.holdEnterForCorrection
        case .foundationModel: return settings.isFoundationModelEnabled
        case .verifier: return settings.isVerifierEnabled
        case .learning: return settings.isLearningEnabled
        case .transliterationHints: return settings.transliterationHintsEnabled
        }
    }

    private func setValue(_ value: Bool, of setting: AlgorithmNode.SettingSwitch) {
        switch setting {
        case .holdEnter: settings.holdEnterForCorrection = value
        case .foundationModel: settings.isFoundationModelEnabled = value
        case .verifier: settings.isVerifierEnabled = value
        case .learning: settings.isLearningEnabled = value
        case .transliterationHints: settings.transliterationHintsEnabled = value
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
    let onSelect: () -> Void

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous)
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
            } else if isOn {
                shape.stroke(Theme.Color.borderSubtle, lineWidth: 1)
            } else {
                shape.stroke(Theme.Color.borderStrong, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            }
        }
        .opacity(isOn ? 1 : 0.75)
    }
}

// MARK: - Inspector

private struct NodeInspector: View {
    let node: AlgorithmNode
    let isOn: Bool
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
    var body: some View {
        Label(UIStrings.text("Typed word"), systemImage: "character.cursor.ibeam")
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
    var body: some View {
        HStack(spacing: Theme.Spacing.sm) {
            ForEach(AlgorithmDiagram.outcomes) { outcome in
                Label(UIStrings.text(outcome.title), systemImage: outcome.systemImage)
                    .font(Theme.Typography.label())
                    .foregroundStyle(Theme.Color.textPrimary)
                    .padding(.horizontal, Theme.Spacing.md)
                    .padding(.vertical, Theme.Spacing.sm)
                    .frame(maxWidth: .infinity)
                    .background(Theme.Color.surfaceRaised, in: Capsule())
                    .overlay { Capsule().stroke(Theme.Color.borderSubtle, lineWidth: 1) }
            }
        }
    }
}

private struct AlgorithmLegend: View {
    var body: some View {
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
