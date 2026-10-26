import XCTest
@testable import RightLayout

final class SecureInputMonitorTests: XCTestCase {
    func testHelperIsNamedAfterTheAppItShipsIn() {
        XCTAssertEqual(
            SecureInputMonitor.outermostAppBundlePath(
                inExecutablePath: "/Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Framework.framework/Versions/1/Helpers/Google Chrome Helper.app/Contents/MacOS/Google Chrome Helper"
            ),
            "/Applications/Google Chrome.app"
        )
        XCTAssertEqual(
            SecureInputMonitor.outermostAppBundlePath(inExecutablePath: "/System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal"),
            "/System/Applications/Utilities/Terminal.app"
        )
        XCTAssertNil(SecureInputMonitor.outermostAppBundlePath(inExecutablePath: "/usr/libexec/sshd-keygen-wrapper"))
    }

    func testReportLine() {
        XCTAssertEqual(SecureInputMonitor.State.off.reportLine, "Secure input: off")
        XCTAssertEqual(
            SecureInputMonitor.State(isActive: true, owner: nil).reportLine,
            "Secure input: on, held by an unknown process"
        )
        let chrome = SecureInputMonitor.Owner(pid: 1234, name: "Google Chrome", bundleId: "com.google.Chrome")
        XCTAssertEqual(
            SecureInputMonitor.State(isActive: true, owner: chrome).reportLine,
            "Secure input: on, held by Google Chrome (com.google.Chrome, PID 1234)"
        )
    }

    @MainActor
    func testToolTipNamesTheApp() {
        XCTAssertNil(SecureInputMonitor.State.off.menuBarToolTip)
        let chrome = SecureInputMonitor.Owner(pid: 1234, name: "Google Chrome", bundleId: "com.google.Chrome")
        XCTAssertTrue(SecureInputMonitor.State(isActive: true, owner: chrome).menuBarToolTip?.contains("Google Chrome") == true)
        XCTAssertNotNil(SecureInputMonitor.State(isActive: true, owner: nil).menuBarToolTip)
    }

    @MainActor
    func testStatusShowsWhoHoldsSecureInput() {
        let chrome = SecureInputMonitor.Owner(pid: 1234, name: "Google Chrome", bundleId: "com.google.Chrome")
        let source = AppStatusSnapshot.Source(
            isEnabled: true,
            hasAccessibilityPermission: true,
            updateAvailableVersion: nil,
            isStatsCollectionEnabled: true,
            isStrictPrivacyMode: false,
            behaviorPresetTitle: "Balanced+",
            preferredLanguageTitle: "EN",
            activeLayouts: ["en": "us"],
            excludedAppsCount: 0,
            recentCorrectionDescription: nil,
            secureInput: SecureInputMonitor.State(isActive: true, owner: chrome)
        )

        let snapshot = AppStatusSnapshot.build(from: source)

        XCTAssertEqual(snapshot.issues.first?.severity, .critical)
        XCTAssertEqual(snapshot.issues.first?.isSecureInput, true, "The menu shows it as a button")
        XCTAssertTrue(snapshot.issues.first?.title.contains("Google Chrome") == true)
        XCTAssertEqual(snapshot.runtimeTitle, UIStrings.text("Blocked"))
    }

    func testDescribesThisProcess() {
        let owner = SecureInputMonitor.describeProcess(ProcessInfo.processInfo.processIdentifier)
        XCTAssertEqual(owner.pid, ProcessInfo.processInfo.processIdentifier)
        XCTAssertFalse(owner.name.isEmpty)
    }
}
