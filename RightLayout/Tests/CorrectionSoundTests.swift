import XCTest
@testable import RightLayout

final class CorrectionSoundTests: XCTestCase {
    @MainActor
    func testEverySoundIsBundled() {
        for sound in SettingsManager.CorrectionSound.allCases {
            XCTAssertNotNil(CorrectionSoundPlayer.url(for: sound), "Missing correction_\(sound.rawValue).wav")
        }
    }
}
