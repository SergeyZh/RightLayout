import XCTest
@testable import RightLayout

/// Temporary: prints how short Russian words typed on the English layout are decided.
final class ShortRussianWordDiagnosticsTests: XCTestCase {
    @MainActor
    func testPrintDecisions() async {
        let settings = SettingsManager.shared
        settings.isEnabled = true
        settings.isLearningEnabled = false
        settings.activeLayouts = ["en": "us", "ru": "russianwin", "he": "hebrew"]
        settings.customEnabledLanguages = [.english, .russian]
        settings.preferredLanguage = .russian
        var lines: [String] = []
        for minLength in [1, 2] {
            settings.minAutoCorrectWordLength = minLength
            for phrase in ["", "Привет"] {
                for environment in [EditingEnvironment.accessibility, .nonAccessibility] {
                    for token in ["Yj", "yj", "Z", "z", "E", "e", "Yt", "Lf", "Vs", "D", "J", "Nfr"] {
                        let engine = CorrectionEngine(settings: settings)
                        let planned = await engine.planCorrection(token, phraseBuffer: phrase, editingEnvironment: environment)
                        let e = planned.result.evidence
                        lines.append("DIAG min=\(minLength) phrase='\(phrase)' env=\(environment) token=\(token) plan=\(Self.kind(of: planned.plan)) corrected=\(planned.result.corrected ?? "-") hyp=\(e.map { $0.decision.layoutHypothesis.rawValue } ?? "-") conf=\(e.map { String(format: "%.3f", $0.confidence) } ?? "-") margin=\(e.map { String(format: "%.3f", $0.winnerMargin) } ?? "-") kind=\(e.map { String(describing: $0.tokenKind) } ?? "-") wl=\(e.map { String($0.isWhitelistedShort) } ?? "-") why=\(planned.trail ?? "-")")
                    }
                }
            }
        }
        settings.minAutoCorrectWordLength = AutoCorrectionLimits.default.minimumWordLength
        settings.preferredLanguage = .english
        settings.customEnabledLanguages = nil
        settings.isLearningEnabled = true
        XCTFail(lines.joined(separator: "\n"))
    }

    private static func kind(of plan: CorrectionPlan) -> String {
        switch plan {
        case .autoReplace: return "auto"
        case .hint: return "hint"
        case .none: return "none"
        default: return "other"
        }
    }
}
