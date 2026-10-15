import SwiftUI

public struct PermissionRequestView: View {
    private let onGranted: @MainActor () -> Void

    /// - Parameter onGranted: Called once the permission is detected, so the host can
    ///   start monitoring and dismiss this window.
    public init(onGranted: @escaping @MainActor () -> Void = {}) {
        self.onGranted = onGranted
    }

    @State private var isChecking = false
    @State private var isGranted = SandboxPermissionManager.shared.checkAccessibilityPermission()
    @State private var resetStatus: String?

    private let privacyURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    private let bundleIdentifier = SandboxPermissionManager.shared.appBundleIdentifier

    public var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xl) {
            HStack(alignment: .top, spacing: Theme.Spacing.lg) {
                Image(systemName: isGranted ? "checkmark.shield" : "lock.open.display")
                    .font(.system(size: 34, weight: .regular))
                    .foregroundStyle(isGranted ? Theme.Color.success : Theme.Color.accent)

                VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                    Text(UIStrings.text(isGranted ? "Accessibility granted" : "Accessibility permission required"))
                        .font(Theme.Typography.heading())
                        .foregroundStyle(Theme.Color.textPrimary)

                    Text(
                        UIStrings.text(
                            isGranted
                            ? "RightLayout can now monitor supported text fields and apply verified corrections."
                            : "RightLayout cannot monitor keyboard input or correct text until Accessibility access is granted in System Settings."
                        )
                    )
                    .font(Theme.Typography.body())
                    .foregroundStyle(Theme.Color.textSecondary)
                }
            }

            WorkbenchSection(title: "Why this is needed", detail: "This is the only permission RightLayout needs to observe text entry and correct the visible field.") {
                Text(UIStrings.text("Without Accessibility access, automatic correction, manual last-word correction, and diagnostics for live typing remain blocked."))
                    .font(Theme.Typography.body())
                    .foregroundStyle(Theme.Color.textSecondary)
            }

            WorkbenchSection(title: "What to do", detail: "Grant access once, then return here and confirm the status.") {
                VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                    Text(UIStrings.text("1. Open System Settings → Privacy & Security → Accessibility"))
                    Text(UIStrings.text("2. Enable the switch next to RightLayout"))
                    Text(UIStrings.text("3. If macOS asks, quit and reopen the app"))
                }
                .font(Theme.Typography.body())
                .foregroundStyle(Theme.Color.textSecondary)

                HStack(spacing: Theme.Spacing.md) {
                    Button {
                        SandboxPermissionManager.shared.requestAccessibilityPermission()
                        openPrivacySettings()
                    } label: {
                        Label(UIStrings.text("Open Accessibility Settings"), systemImage: "gearshape")
                    }
                    .buttonStyle(.plain)
                    .primaryActionButton()

                    Button {
                        checkPermission()
                    } label: {
                        Label(UIStrings.text("Check Again"), systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.plain)
                    .secondaryActionButton()
                    .disabled(isChecking)
                }
            }

            if !isGranted {
                if bundleIdentifier == nil {
                    WorkbenchSection(title: "Running from Terminal", detail: nil) {
                        Text(UIStrings.text("RightLayout was started outside of its app bundle, so macOS checks the permission of the app that launched it. Enable Accessibility for Terminal (or iTerm) instead, then restart it."))
                            .font(Theme.Typography.body())
                            .foregroundStyle(Theme.Color.textSecondary)
                    }
                } else {
                    WorkbenchSection(title: "Already enabled?", detail: nil) {
                        Text(UIStrings.text("If RightLayout is already switched on in the list but this window doesn't change, the entry belongs to a previous build or installation. Reset it, then enable RightLayout again."))
                            .font(Theme.Typography.body())
                            .foregroundStyle(Theme.Color.textSecondary)

                        Button {
                            resetPermission()
                        } label: {
                            Label(UIStrings.text("Reset Permission"), systemImage: "arrow.counterclockwise")
                        }
                        .buttonStyle(.plain)
                        .secondaryActionButton()

                        if let resetStatus {
                            Text(resetStatus)
                                .font(Theme.Typography.body())
                                .foregroundStyle(Theme.Color.textSecondary)
                                .textSelection(.enabled)
                        }
                    }
                }
            }
        }
        .padding(Theme.Spacing.xxl)
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
        .background(Theme.Color.pageBackgroundPrimary)
        .task {
            await pollPermission()
        }
    }

    private func openPrivacySettings() {
        guard let privacyURL else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            NSWorkspace.shared.open(privacyURL)
        }
    }

    @MainActor
    private func checkPermission() {
        isChecking = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            MainActor.assumeIsolated {
                updateGranted(SandboxPermissionManager.shared.checkAccessibilityPermission())
                isChecking = false
            }
        }
    }

    @MainActor
    private func resetPermission() {
        if SandboxPermissionManager.shared.resetAccessibilityPermission() {
            resetStatus = UIStrings.text("The old entry was removed. Enable RightLayout in the list that opens.")
            SandboxPermissionManager.shared.requestAccessibilityPermission()
            openPrivacySettings()
        } else if let bundleIdentifier {
            resetStatus = UIStrings.text("Could not reset automatically. Run this in Terminal, then reopen RightLayout:")
                + "\ntccutil reset Accessibility \(bundleIdentifier)"
        }
    }

    /// Watches for the permission while the window is open: macOS doesn't notify
    /// the app when the switch in System Settings is turned on.
    @MainActor
    private func pollPermission() async {
        while !Task.isCancelled {
            if updateGranted(SandboxPermissionManager.shared.checkAccessibilityPermission()) {
                return
            }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
    }

    @MainActor
    @discardableResult
    private func updateGranted(_ granted: Bool) -> Bool {
        isGranted = granted
        if granted {
            // May be called more than once; the host handles repeats.
            onGranted()
        }
        return granted
    }
}

#Preview {
    PermissionRequestView()
}
