import Foundation

/// The last minutes of what RightLayout saw and did, kept while "Detailed log" is on,
/// for problem reports. It holds the words typed, so it stays in memory and leaves it
/// only when the user copies a report.
final class DiagnosticJournal: @unchecked Sendable {
    static let shared = DiagnosticJournal()

    struct Entry: Sendable {
        let timestamp: Date
        let message: String
    }

    static let maxEntries = 5000

    private let lock = NSLock()
    private var enabled = false
    private var entries: [Entry] = []

    var isEnabled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return enabled
    }

    func setEnabled(_ value: Bool) {
        lock.lock()
        enabled = value
        if !value {
            entries.removeAll()
        }
        lock.unlock()
    }

    func record(_ message: String, at timestamp: Date = Date()) {
        lock.lock()
        defer { lock.unlock() }
        guard enabled else { return }
        entries.append(Entry(timestamp: timestamp, message: message))
        if entries.count > Self.maxEntries {
            entries.removeFirst(entries.count - Self.maxEntries)
        }
    }

    /// Oldest first.
    func entries(since date: Date) -> [Entry] {
        lock.lock()
        defer { lock.unlock() }
        return entries.filter { $0.timestamp >= date }
    }

    func clear() {
        lock.lock()
        entries.removeAll()
        lock.unlock()
    }
}
