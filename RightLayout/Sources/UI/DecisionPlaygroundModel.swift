import Foundation

/// The test field of the Algorithm page: checks what is typed there with an engine of
/// its own, so nothing reaches the real one, and keeps what each block did.
@MainActor
final class DecisionPlaygroundModel: ObservableObject {
    @Published var text = "" {
        didSet { schedule() }
    }
    @Published var environment: EditingEnvironment = .accessibility {
        didSet { schedule() }
    }
    @Published var endsWithEnter = false {
        didSet { schedule() }
    }
    @Published private(set) var words: [PlaygroundWord] = []
    @Published var selectedWordId: Int?
    @Published private(set) var isChecking = false

    private let settings: SettingsManager
    private var engine: CorrectionEngine?
    private var knowledge: KnowledgeLookup?
    private var pending: Task<Void, Never>?
    private var isRunning = false
    private var needsRerun = false

    init(settings: SettingsManager = .shared) {
        self.settings = settings
    }

    /// The word the diagram shows: the one picked, or else the last one.
    var selectedWord: PlaygroundWord? {
        words.first { $0.id == selectedWordId } ?? words.last
    }

    /// Checks the text again shortly, once typing or a change of settings pauses.
    func schedule() {
        pending?.cancel()
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            words = []
            selectedWordId = nil
            return
        }
        pending = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            await self?.run()
        }
    }

    /// One check at a time: the engine keeps the words of the text it is checking.
    private func run() async {
        if isRunning {
            needsRerun = true
            return
        }
        isRunning = true
        isChecking = true
        defer {
            isRunning = false
            isChecking = false
        }

        let (engine, knowledge) = await prepare()
        repeat {
            needsRerun = false
            let text = self.text
            let result = await DecisionPlayground.check(
                text,
                engine: engine,
                knowledge: knowledge,
                environment: environment,
                endsWithEnter: endsWithEnter,
                holdsEnter: settings.holdEnterForCorrection
            )
            if !needsRerun, text == self.text {
                words = result
                if let selectedWordId, !result.contains(where: { $0.id == selectedWordId }) {
                    self.selectedWordId = nil
                }
            }
        } while needsRerun
    }

    /// Loading the models takes a moment, so it is done off the main thread, once.
    private func prepare() async -> (CorrectionEngine, KnowledgeLookup) {
        if let engine, let knowledge {
            return (engine, knowledge)
        }
        let settings = self.settings
        let loaded = await Task.detached(priority: .userInitiated) {
            (CorrectionEngine(settings: settings), KnowledgeLookup())
        }.value
        engine = loaded.0
        knowledge = loaded.1
        return loaded
    }
}
