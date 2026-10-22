import XCTest
@testable import RightLayout

/// The Adaptation page reads the learned data back by app.
final class AdaptationInspectorTests: XCTestCase {
    private let claude = AppContextHashes(
        bundleId: "com.anthropic.claudefordesktop",
        app: 11,
        intents: ["prose": 21, "code": 22, "url": 23],
        timeBuckets: [0: 31, 1: 32, 2: 33]
    )

    func testContextIsNamedAfterItsAppAndShowsItsEffect() {
        var undone = RiskState()
        undone.alpha = 1.5
        undone.beta = 6.0
        let snapshot = AdaptationInspector.assemble(
            risk: [
                ContextKey(global: 0, app: 11, appIntent: 21, appTime: 32): undone,
                ContextKey(global: 0, app: 99, appIntent: 98, appTime: 97): RiskState()
            ],
            priors: [11: ["ru": -3.5, "en": 1.0]],
            learningEvents: 5,
            patterns: ["com.anthropic.claudefordesktop": ["ru,ru->ru": 7, "ru->END": 2]],
            apps: [claude],
            names: ["com.anthropic.claudefordesktop": "Claude"]
        )

        XCTAssertEqual(snapshot.demotions.count, 2)
        let first = snapshot.demotions[0]
        XCTAssertEqual(first.app, "Claude", "Demoting contexts come first")
        XCTAssertEqual(first.textKind, "prose")
        XCTAssertEqual(first.timeOfDay, 1)
        XCTAssertEqual(first.correctionBecomes, .suggestHint)
        XCTAssertTrue(first.demotes)
        XCTAssertEqual(first.kept, 0.5, accuracy: 0.001)
        XCTAssertEqual(first.undone, 4.0, accuracy: 0.001)

        let unknown = snapshot.demotions[1]
        XCTAssertNil(unknown.bundleId)
        XCTAssertTrue(unknown.app.hasPrefix("#"))
        XCTAssertFalse(unknown.demotes, "A fresh context changes nothing")

        XCTAssertEqual(snapshot.layoutPreferences.first?.app, "Claude")
        XCTAssertEqual(snapshot.layoutPreferences.first?.demotedLayouts, ["ru"])

        XCTAssertEqual(snapshot.sentencePatterns.first?.patterns.first?.text, "ru,ru->ru")
        XCTAssertEqual(snapshot.learningEvents, 5)
        XCTAssertFalse(snapshot.isEmpty)
    }

    func testNothingLearnedIsEmpty() {
        let snapshot = AdaptationInspector.assemble(risk: [:], priors: [:], learningEvents: 0, patterns: [:], apps: [], names: [:])
        XCTAssertTrue(snapshot.isEmpty)
    }

    func testResetForgetsTheDemotions() async {
        let controller = RiskController(customDirectory: FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true))
        let key = ContextKey(global: 0, app: 1, appIntent: 2, appTime: 3)
        for _ in 0..<5 {
            await controller.recordFeedback(contextKey: key, isSuccess: false)
        }
        let demoted = await controller.demote(policy: .autoApply, contextKey: key)
        XCTAssertEqual(demoted, .suggestHint)

        await controller.reset()
        let states = await controller.allStates()
        XCTAssertTrue(states.isEmpty)
        let restored = await controller.demote(policy: .autoApply, contextKey: key)
        XCTAssertEqual(restored, .autoApply)
    }
}
