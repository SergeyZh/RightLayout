import Foundation
import ApplicationServices
import os.log

@MainActor
public final class SandboxPermissionManager {
    public static let shared = SandboxPermissionManager()
    private let logger = Logger(subsystem: "com.rightlayout.app", category: "SandboxPermissionManager")
    
    private init() {}
    
    /// Checks if Accessibility permission is granted.
    /// This is the only permission RightLayout needs to function.
    public func checkAccessibilityPermission() -> Bool {
        let trusted = AXIsProcessTrusted()
        if trusted {
            logger.info("✅ checkAccessibilityPermission: Accessibility permission granted.")
        } else {
            logger.warning("⚠️ checkAccessibilityPermission: Accessibility permission not granted.")
        }
        return trusted
    }
    
    /// Prompts the user to grant Accessibility permission via system dialog.
    func requestAccessibilityPermission() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }

    /// Bundle identifier macOS tracks the permission under, or `nil` when running a bare
    /// executable (e.g. from Terminal), where the permission belongs to the terminal app.
    public var appBundleIdentifier: String? {
        guard Bundle.main.bundlePath.hasSuffix(".app") else { return nil }
        return Bundle.main.bundleIdentifier
    }

    /// Removes the Accessibility entry macOS keeps for this app.
    ///
    /// Locally built copies are ad-hoc signed, so every rebuild or reinstall is a new
    /// binary for macOS. The old entry stays in System Settings with its switch on, yet
    /// it doesn't apply to the running binary. Resetting lets the current one be added.
    @discardableResult
    public func resetAccessibilityPermission() -> Bool {
        guard let bundleId = appBundleIdentifier else { return false }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        process.arguments = ["reset", "Accessibility", bundleId]
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            logger.error("tccutil reset failed: \(error.localizedDescription, privacy: .public)")
            return false
        }

        let succeeded = process.terminationStatus == 0
        if succeeded {
            logger.info("Reset Accessibility permission for \(bundleId, privacy: .public)")
        } else {
            logger.error("tccutil reset exited with status \(process.terminationStatus)")
        }
        return succeeded
    }
}
