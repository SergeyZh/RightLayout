import Foundation

enum CorrectionPlan: Sendable {
    case none
    case autoReplace(CorrectionCandidate)
    case hint(CorrectionCandidate)
    case manualCycle([CorrectionEngine.CyclingContext.Alternative])
}

struct CorrectionCandidate: Sendable {
    let original: String
    let replacement: String
    let pendingOriginal: String?
    let pendingReplacement: String?
    let trackingId: UUID?
    let transaction: CorrectionTransaction?
    let transliterationSuggestion: TransliterationSuggestion?
}

struct PlannedCorrection: Sendable {
    let result: CorrectionEngine.CorrectionResult
    let plan: CorrectionPlan
    /// How the word was decided, for the detailed log ("policy=autoApply,learning=suggestHint").
    var trail: String? = nil
}

/// Notes on how the word being decided got its outcome: the policy's verdict and what
/// changed it afterwards. A problem report then says why a sure correction was only
/// suggested instead of leaving it to guesswork.
final class DecisionTrail: @unchecked Sendable {
    @TaskLocal static var current: DecisionTrail?

    private let lock = NSLock()
    private var notes: [String] = []

    /// Adds `note` to the trail of the word being decided, if any.
    static func note(_ note: String) {
        current?.append(note)
    }

    func append(_ note: String) {
        lock.lock()
        defer { lock.unlock() }
        notes.append(note)
    }

    var summary: String? {
        lock.lock()
        defer { lock.unlock() }
        return notes.isEmpty ? nil : notes.joined(separator: ",")
    }
}

extension CorrectionEngine {
    func planCorrection(
        _ text: String,
        phraseBuffer: String = "",
        expectedLayout: Language? = nil,
        latencies: [TimeInterval] = [],
        editingEnvironment: EditingEnvironment = .accessibility
    ) async -> PlannedCorrection {
        let trail = DecisionTrail()
        let result = await DecisionTrail.$current.withValue(trail) {
            await correctText(
                text,
                phraseBuffer: phraseBuffer,
                expectedLayout: expectedLayout,
                latencies: latencies,
                editingEnvironment: editingEnvironment
            )
        }

        let candidate = CorrectionCandidate(
            original: text,
            replacement: result.corrected ?? text,
            pendingOriginal: result.pendingOriginal,
            pendingReplacement: result.pendingCorrection,
            trackingId: result.trackingId,
            transaction: result.transaction,
            transliterationSuggestion: result.transliterationSuggestion
        )

        let plan: CorrectionPlan
        switch result.action {
        case .applied:
            if result.corrected != nil {
                plan = .autoReplace(candidate)
            } else {
                plan = .none
            }
        case .hint:
            plan = .hint(candidate)
        case .none:
            plan = .none
        }

        return PlannedCorrection(result: result, plan: plan, trail: trail.summary)
    }

    func currentManualCyclePlan() -> CorrectionPlan {
        if let state = cyclingState, state.isValid {
            return .manualCycle(state.alternatives)
        }
        return .none
    }
}
