import XCTest
@testable import RightLayout

final class HostRuntimeProfileTests: XCTestCase {
    func testKnownGoodBlindBundleResolvesToBlindKnownGood() {
        let profile = HostRuntimeProfile.resolve(
            bundleId: "com.microsoft.VSCode",
            capabilities: AppEditCapabilities(
                supportsSelectedTextWrite: false,
                supportsSelectedRangeWrite: false,
                supportsValueWrite: false,
                supportsSelectionRead: false,
                supportsFullTextRead: false,
                isSecureOrReadBlind: true,
                capabilityClass: .blind,
                elementFingerprint: nil
            )
        )

        XCTAssertEqual(profile, .blindKnownGood)
        XCTAssertTrue(profile.allowsAutomaticBlindReplay)
        XCTAssertTrue(profile.switchSafeAfterBlindReplay)
    }

    func testUnknownBlindBundleResolvesToBlindUnknown() {
        let profile = HostRuntimeProfile.resolve(
            bundleId: "com.example.unknowneditor",
            capabilities: AppEditCapabilities(
                supportsSelectedTextWrite: false,
                supportsSelectedRangeWrite: false,
                supportsValueWrite: false,
                supportsSelectionRead: false,
                supportsFullTextRead: false,
                isSecureOrReadBlind: true,
                capabilityClass: .blind,
                elementFingerprint: nil
            )
        )

        XCTAssertEqual(profile, .blindUnknown)
        XCTAssertFalse(profile.allowsAutomaticBlindReplay)
        XCTAssertFalse(profile.switchSafeAfterBlindReplay)
        XCTAssertTrue(profile.allowsManualLastWordReplay)
    }

    func testSecureCapabilityResolvesToSecure() {
        let profile = HostRuntimeProfile.resolve(
            bundleId: "com.apple.SecurityAgent",
            capabilities: AppEditCapabilities(
                supportsSelectedTextWrite: false,
                supportsSelectedRangeWrite: false,
                supportsValueWrite: false,
                supportsSelectionRead: false,
                supportsFullTextRead: false,
                isSecureOrReadBlind: true,
                capabilityClass: .secure,
                elementFingerprint: nil
            )
        )

        XCTAssertEqual(profile, .secure)
        XCTAssertFalse(profile.allowsManualLastWordReplay)
        XCTAssertFalse(profile.allowsManualSelectionClipboardFallback)
    }

    func testClaudeDesktopResolvesToBlindKnownGood() {
        let profile = HostRuntimeProfile.resolve(
            bundleId: "com.anthropic.claudefordesktop",
            capabilities: AppEditCapabilities(
                supportsSelectedTextWrite: false,
                supportsSelectedRangeWrite: false,
                supportsValueWrite: false,
                supportsSelectionRead: false,
                supportsFullTextRead: false,
                isSecureOrReadBlind: true,
                capabilityClass: .blind,
                elementFingerprint: nil
            )
        )

        XCTAssertEqual(profile, .blindKnownGood)
        XCTAssertTrue(profile.allowsAutomaticBlindReplay)
    }

    /// The ChatGPT app takes retyped words, so words are corrected there automatically
    /// too, not only with the hotkey.
    func testChatGPTDesktopResolvesToBlindKnownGood() {
        // The current ChatGPT app is "com.openai.codex"; older builds were "com.openai.chat".
        for bundleId in ["com.openai.chat", "com.openai.codex"] {
            let profile = HostRuntimeProfile.resolve(
                bundleId: bundleId,
                capabilities: AppEditCapabilities(
                    supportsSelectedTextWrite: false,
                    supportsSelectedRangeWrite: false,
                    supportsValueWrite: false,
                    supportsSelectionRead: false,
                    supportsFullTextRead: false,
                    isSecureOrReadBlind: true,
                    capabilityClass: .blind,
                    elementFingerprint: nil
                )
            )

            XCTAssertEqual(profile, .blindKnownGood, bundleId)
            XCTAssertTrue(profile.allowsAutomaticBlindReplay, bundleId)
        }
    }

    func testKnownGoodHostWithPartialAXWithoutTextResolvesToBlindKnownGood() {
        let profile = HostRuntimeProfile.resolve(
            bundleId: "com.tinyspeck.slackmacgap",
            capabilities: AppEditCapabilities(
                supportsSelectedTextWrite: false,
                supportsSelectedRangeWrite: false,
                supportsValueWrite: false,
                supportsSelectionRead: true,
                supportsFullTextRead: false,
                isSecureOrReadBlind: false,
                capabilityClass: .axPartial,
                elementFingerprint: nil
            )
        )

        XCTAssertEqual(profile, .blindKnownGood)
    }

    func testTerminalWithReadableBufferResolvesToBlindKnownGood() {
        let profile = HostRuntimeProfile.resolve(
            bundleId: "com.googlecode.iterm2",
            capabilities: AppEditCapabilities(
                supportsSelectedTextWrite: false,
                supportsSelectedRangeWrite: false,
                supportsValueWrite: false,
                supportsSelectionRead: true,
                supportsFullTextRead: true,
                isSecureOrReadBlind: false,
                capabilityClass: .axFull,
                elementFingerprint: nil
            )
        )

        XCTAssertEqual(profile, .blindKnownGood)
        XCTAssertTrue(profile.allowsAutomaticBlindReplay)
    }
}
