import XCTest
@testable import RightLayout

final class DiagnosticJournalTests: XCTestCase {
    func testRecordsOnlyWhileEnabled() {
        let journal = DiagnosticJournal()
        journal.record("before")
        XCTAssertTrue(journal.entries(since: .distantPast).isEmpty)

        journal.setEnabled(true)
        journal.record("during")
        XCTAssertEqual(journal.entries(since: .distantPast).map(\.message), ["during"])

        journal.setEnabled(false)
        journal.record("after")
        XCTAssertTrue(journal.entries(since: .distantPast).isEmpty, "Turning the log off forgets it")
    }

    func testKeepsTheNewestEntries() {
        let journal = DiagnosticJournal()
        journal.setEnabled(true)
        for index in 0..<(DiagnosticJournal.maxEntries + 10) {
            journal.record("\(index)")
        }
        let entries = journal.entries(since: .distantPast)
        XCTAssertEqual(entries.count, DiagnosticJournal.maxEntries)
        XCTAssertEqual(entries.first?.message, "10")
        XCTAssertEqual(entries.last?.message, "\(DiagnosticJournal.maxEntries + 9)")
    }

    func testEntriesSinceADate() {
        let journal = DiagnosticJournal()
        journal.setEnabled(true)
        let now = Date()
        journal.record("old", at: now.addingTimeInterval(-600))
        journal.record("new", at: now.addingTimeInterval(-10))
        XCTAssertEqual(journal.entries(since: now.addingTimeInterval(-300)).map(\.message), ["new"])
    }

    @MainActor
    func testReportHasSettingsDecisionsAndTheLog() {
        let settings = SettingsManager.shared
        let wasEnabled = settings.isDetailedLogEnabled
        defer { settings.isDetailedLogEnabled = wasEnabled }

        settings.isDetailedLogEnabled = true
        DiagnosticJournal.shared.record("TRACE plan_ready token=ghbdtn")
        DecisionLogStore.shared.log(token: "ghbdtn", confidence: 0.9, appName: "Notes", action: "Applied", hypothesis: "ru_from_en")

        let report = ProblemReport.make()
        XCTAssertTrue(report.contains("Working languages:"))
        XCTAssertTrue(report.contains("Layouts:"))
        XCTAssertTrue(report.contains("Secure input: "))
        XCTAssertTrue(report.contains("Applied ghbdtn conf=90%"))
        XCTAssertTrue(report.contains("TRACE plan_ready token=ghbdtn"))
    }

    @MainActor
    func testReportSaysHowToTurnTheLogOn() {
        let settings = SettingsManager.shared
        let wasEnabled = settings.isDetailedLogEnabled
        defer { settings.isDetailedLogEnabled = wasEnabled }

        settings.isDetailedLogEnabled = false
        XCTAssertTrue(ProblemReport.make().contains("turn on Detailed log"))
    }
}
