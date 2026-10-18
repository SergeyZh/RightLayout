import XCTest
@testable import RightLayout

/// Chromium apps are recognized by their renderer helper, whatever their engine
/// framework is called (Electron, Chrome, ChatGPT Atlas…).
final class ChromiumHostDetectorTests: XCTestCase {
    private var frameworks: URL!

    override func setUpWithError() throws {
        frameworks = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("Frameworks", isDirectory: true)
        try FileManager.default.createDirectory(at: frameworks, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: frameworks.deletingLastPathComponent())
    }

    private func makeDirectory(_ path: String) throws {
        try FileManager.default.createDirectory(
            at: frameworks.appendingPathComponent(path, isDirectory: true),
            withIntermediateDirectories: true
        )
    }

    func testElectronAppWithHelperNextToFrameworks() throws {
        try makeDirectory("Electron Framework.framework")
        try makeDirectory("Notion Helper (Renderer).app")
        XCTAssertTrue(ChromiumHostDetector.hasChromiumRendererHelper(frameworksPath: frameworks.path))
    }

    func testBrowserWithItsOwnEngineFramework() throws {
        try makeDirectory("ChatGPT Atlas Framework.framework/Versions/Current/Helpers/ChatGPT Atlas Helper (Renderer).app")
        XCTAssertTrue(ChromiumHostDetector.hasChromiumRendererHelper(frameworksPath: frameworks.path))
    }

    func testNativeApp() throws {
        try makeDirectory("Sparkle.framework/Versions/Current/Resources")
        XCTAssertFalse(ChromiumHostDetector.hasChromiumRendererHelper(frameworksPath: frameworks.path))
    }

    func testMissingFrameworksFolder() {
        XCTAssertFalse(ChromiumHostDetector.hasChromiumRendererHelper(frameworksPath: frameworks.appendingPathComponent("none").path))
    }
}
