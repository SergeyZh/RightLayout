import Foundation

enum AppVersionResolver {
    private static let environmentKey = "RIGHTLAYOUT_APP_VERSION"
    private static let versionFileName = "VERSION"

    static func current(
        bundle: Bundle = .main,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        currentDirectory: String = FileManager.default.currentDirectoryPath
    ) -> String {
        if let version = normalized(environment[environmentKey]) {
            return version
        }

        if let version = versionFromFile(bundle: bundle, currentDirectory: currentDirectory) {
            return version
        }

        if let version = normalized(bundle.infoDictionary?["CFBundleShortVersionString"] as? String) {
            return version
        }

        return "0.0"
    }

    static func versionFromFile(
        bundle: Bundle = .main,
        currentDirectory: String = FileManager.default.currentDirectoryPath
    ) -> String? {
        for path in candidateVersionPaths(bundle: bundle, currentDirectory: currentDirectory) {
            if let version = try? String(contentsOfFile: path, encoding: .utf8),
               let normalized = normalized(version) {
                return normalized
            }
        }
        return nil
    }

    static func candidateVersionPaths(
        bundle: Bundle = .main,
        currentDirectory: String = FileManager.default.currentDirectoryPath
    ) -> [String] {
        var candidates: [String] = []

        func appendCandidate(_ path: String) {
            guard !path.isEmpty, !candidates.contains(path) else { return }
            candidates.append(path)
        }

        appendCandidate(URL(fileURLWithPath: currentDirectory).appendingPathComponent(versionFileName).path)

        var bundleURL = URL(fileURLWithPath: bundle.bundlePath)
        for _ in 0..<6 {
            appendCandidate(bundleURL.appendingPathComponent(versionFileName).path)
            bundleURL.deleteLastPathComponent()
        }

        if let executableURL = bundle.executableURL {
            var executableDir = executableURL.deletingLastPathComponent()
            for _ in 0..<6 {
                appendCandidate(executableDir.appendingPathComponent(versionFileName).path)
                executableDir.deleteLastPathComponent()
            }
        }

        return candidates
    }

    /// The commit the app was built from ("f43fb78", "f43fb78-dirty" with local changes),
    /// as `rightlayout.sh run` passes it or a release build records it, or nil.
    static func buildCommit(
        bundle: Bundle = .main,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String? {
        normalized(environment[commitEnvironmentKey])
            ?? normalized(bundle.infoDictionary?[commitInfoKey] as? String)
    }

    private static let commitEnvironmentKey = "RIGHTLAYOUT_BUILD_COMMIT"
    private static let commitInfoKey = "RightLayoutBuildCommit"

    private static func normalized(_ version: String?) -> String? {
        guard let version else { return nil }
        let trimmed = version.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

let appVersion: String = AppVersionResolver.current()
