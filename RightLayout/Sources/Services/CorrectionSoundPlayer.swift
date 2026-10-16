import AppKit

/// Plays the short sound chosen in Settings when a word has been corrected.
@MainActor
final class CorrectionSoundPlayer {
    static let shared = CorrectionSoundPlayer()

    private let settings: SettingsManager
    private var players: [SettingsManager.CorrectionSound: NSSound] = [:]

    init(settings: SettingsManager = .shared) {
        self.settings = settings
    }

    func playIfEnabled() {
        guard settings.correctionSoundEnabled else { return }
        play(settings.correctionSound)
    }

    /// Plays `sound` at the configured volume, restarting it if it is still playing.
    func play(_ sound: SettingsManager.CorrectionSound) {
        guard let player = player(for: sound) else { return }
        player.stop()
        player.volume = Float(settings.correctionSoundVolume)
        player.play()
    }

    private func player(for sound: SettingsManager.CorrectionSound) -> NSSound? {
        if let cached = players[sound] {
            return cached
        }
        guard let url = Self.url(for: sound),
              let player = NSSound(contentsOf: url, byReference: false) else {
            return nil
        }
        players[sound] = player
        return player
    }

    nonisolated static func url(for sound: SettingsManager.CorrectionSound) -> URL? {
        let name = "correction_\(sound.rawValue)"
        return Bundle.rightLayoutResources.url(forResource: name, withExtension: "wav", subdirectory: "Sounds")
            ?? Bundle.rightLayoutResources.url(forResource: name, withExtension: "wav")
    }
}
