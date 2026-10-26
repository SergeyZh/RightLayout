import AppKit
import Carbon
import Combine
import IOKit

/// Watches Secure Event Input. While any app has it on (a password field, Terminal's
/// Secure Keyboard Entry), macOS hides typed keys from every other app, RightLayout
/// included, so neither automatic nor manual correction can work. It is system-wide:
/// the app holding it is often not the one being typed in.
@MainActor
public final class SecureInputMonitor: ObservableObject {
    public static let shared = SecureInputMonitor()

    public struct Owner: Equatable, Sendable {
        public let pid: pid_t
        public let name: String
        public let bundleId: String?
    }

    public struct State: Equatable, Sendable {
        public let isActive: Bool
        /// Nil when macOS doesn't say who holds it.
        public let owner: Owner?

        public static let off = State(isActive: false, owner: nil)

        /// The problem report line.
        public var reportLine: String {
            guard isActive else { return "Secure input: off" }
            guard let owner else { return "Secure input: on, held by an unknown process" }
            let details = [owner.bundleId, "PID \(owner.pid)"].compactMap { $0 }.joined(separator: ", ")
            return "Secure input: on, held by \(owner.name) (\(details))"
        }

        /// What the menu bar icon says on hover; nil while secure input is off.
        public var menuBarToolTip: String? {
            guard isActive else { return nil }
            if let owner {
                return UIStrings.format("Secure input is on in %@. RightLayout can't see typing.", owner.name)
            }
            return UIStrings.text("Secure input is on. RightLayout can't see typing.")
        }
    }

    @Published public private(set) var state: State = .off

    private static let pollInterval: TimeInterval = 1
    private var timer: Timer?
    private let trace = RuntimeTraceLogger.shared

    public func start() {
        guard timer == nil else { return }
        refresh()
        // macOS posts no notification when secure input turns on or off.
        timer = Timer.scheduledTimer(withTimeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refresh()
            }
        }
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
    }

    func refresh() {
        guard IsSecureEventInputEnabled() else {
            if state.isActive {
                update(.off)
            }
            return
        }
        let pid = Self.ownerPID()
        if state.isActive, state.owner?.pid == pid {
            return
        }
        update(State(isActive: true, owner: pid.map(Self.describeProcess)))
    }

    private func update(_ newState: State) {
        state = newState
        trace.log(
            .secureInputChanged,
            fields: [
                "state": newState.isActive ? "on" : "off",
                "app": newState.owner?.bundleId ?? newState.owner?.name,
                "pid": newState.owner.map { String($0.pid) }
            ]
        )
    }

    /// The current state, looked up now.
    public nonisolated static func currentState() -> State {
        guard IsSecureEventInputEnabled() else { return .off }
        return State(isActive: true, owner: ownerPID().map(describeProcess))
    }

    /// The process holding secure input, as `ioreg -l | grep SecureInput` shows it.
    nonisolated static func ownerPID() -> pid_t? {
        let root = IORegistryGetRootEntry(kIOMainPortDefault)
        defer { IOObjectRelease(root) }
        guard let property = IORegistryEntryCreateCFProperty(root, "IOConsoleUsers" as CFString, kCFAllocatorDefault, 0),
              let users = property.takeRetainedValue() as? [[String: Any]] else {
            return nil
        }
        let uid = Int(getuid())
        let holders = users.compactMap { user -> (pid: pid_t, isMine: Bool)? in
            guard let pid = (user["kCGSSessionSecureInputPID"] as? NSNumber)?.int32Value, pid > 0 else { return nil }
            let isMine = (user["kCGSSessionUserIDKey"] as? NSNumber)?.intValue == uid
            return (pid, isMine)
        }
        return (holders.first(where: { $0.isMine }) ?? holders.first)?.pid
    }

    nonisolated static func describeProcess(_ pid: pid_t) -> Owner {
        let app = NSRunningApplication(processIdentifier: pid)
        let path = executablePath(of: pid) ?? app?.executableURL?.path
        // A helper ("Google Chrome Helper") is named after the app it ships in.
        if let path, let appPath = outermostAppBundlePath(inExecutablePath: path) {
            let name = ((appPath as NSString).lastPathComponent as NSString).deletingPathExtension
            return Owner(pid: pid, name: name, bundleId: Bundle(path: appPath)?.bundleIdentifier ?? app?.bundleIdentifier)
        }
        if let name = app?.localizedName {
            return Owner(pid: pid, name: name, bundleId: app?.bundleIdentifier)
        }
        if let path {
            return Owner(pid: pid, name: (path as NSString).lastPathComponent, bundleId: nil)
        }
        return Owner(pid: pid, name: "PID \(pid)", bundleId: nil)
    }

    /// "/Applications/Google Chrome.app/Contents/Frameworks/…/Google Chrome Helper.app/Contents/MacOS/…"
    /// → "/Applications/Google Chrome.app".
    nonisolated static func outermostAppBundlePath(inExecutablePath path: String) -> String? {
        let components = (path as NSString).pathComponents
        guard let index = components.firstIndex(where: { $0.hasSuffix(".app") }) else { return nil }
        return NSString.path(withComponents: Array(components[...index]))
    }

    private nonisolated static func executablePath(of pid: pid_t) -> String? {
        // PROC_PIDPATHINFO_MAXSIZE
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return String(cString: buffer)
    }
}
