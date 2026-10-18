import XCTest
@testable import RightLayout

/// Temporary: prints how the engine decides the words from the bug report.
@MainActor
final class ZZDiagnosticTests: XCTestCase {
    func testDiagnostics() async throws {
        let settings = SettingsManager.shared
        settings.isEnabled = true
        let originalLanguages = settings.customEnabledLanguages
        settings.customEnabledLanguages = [.english, .russian]
        defer { settings.customEnabledLanguages = originalLanguages }

        var lines: [String] = ["activeLayouts=\(settings.activeLayouts) preset=\(settings.behaviorPreset) verifier=\(settings.isVerifierEnabled) learning=\(settings.isLearningEnabled) threshold=\(settings.standardPathThreshold)"]
        for env in [EditingEnvironment.accessibility, .nonAccessibility] {
            for word in ["J,yjdb", "j,yjdb", "Rfrbt", "rfrbt", "фьфящт", "Ghbdtn", "Gjlujnjdm"] {
                let engine = CorrectionEngine(settings: settings)
                let planned = await engine.planCorrection(word, editingEnvironment: env)
                let ev = planned.result.evidence
                let manual = await engine.correctLastWord(word)
                lines.append("\(env) \(word): plan=\(planned.plan) corrected=\(String(describing: planned.result.corrected)) action=\(planned.result.action) conf=\(String(describing: planned.result.confidence)) kind=\(String(describing: ev?.tokenKind)) evConf=\(String(describing: ev?.confidence)) margin=\(String(describing: ev?.winnerMargin)) converted=\(String(describing: ev?.convertedText)) hyp=\(String(describing: ev?.decision.layoutHypothesis)) manual=\(String(describing: manual))")
            }
        }
        let engine = CorrectionEngine(settings: settings)
        for w in ["Обнови", "обнови", "J,нови", "J", "нови", "Какие", "какие"] {
            let s = await engine.fastTextScore(w)
            lines.append("score \(w)=\(s) lexicon=\(BuiltinLexicon.contains(w.lowercased(), language: .russian))")
        }
        let variants = LayoutMapper.shared.convertAllVariants("J,yjdb", from: .english, to: .russian, activeLayouts: settings.activeLayouts)
        lines.append("variants=\(variants)")
        lines.append("best=\(String(describing: LayoutMapper.shared.convertBest("J,yjdb", from: .english, to: .russian, activeLayouts: settings.activeLayouts)))")
        XCTFail("DIAG\n" + lines.joined(separator: "\n"))
    }
}
