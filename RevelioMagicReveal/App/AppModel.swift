import Observation
import SwiftUI

/// Assemble les briques de l'app et les fait vivre.
@Observable
final class AppModel {
    let settings: RevealSettings
    let feedback: FeedbackCenter
    let engine: RevealEngine
    let inputs: InputCoordinator
    let media: MediaStore
    let audioHaptics: AudioHapticsDemo
    let audioMessage: AudioMessageModel

    @ObservationIgnored private var driver: DisplayLinkDriver?
    @ObservationIgnored private let launch: LaunchOptions
    @ObservationIgnored private var started = false

    init(launch: LaunchOptions) {
        self.launch = launch
        let settings = RevealSettings()
        if let debug = launch.debugOverlay { settings.debugOverlay = debug }
        let feedback = FeedbackCenter()
        let engine = RevealEngine(settings: settings, feedback: feedback,
                                  mask: launch.mask ?? .snow, gesture: launch.gesture ?? .scratch)
        self.settings = settings
        self.feedback = feedback
        self.engine = engine
        inputs = InputCoordinator(engine: engine, settings: settings)
        media = MediaStore()
        audioHaptics = AudioHapticsDemo(feedback: feedback)
        audioMessage = AudioMessageModel(feedback: feedback, settings: settings)
        if let visualization = launch.message { audioMessage.visualization = visualization }
    }

    /// Visualisation demandée au lancement : l'écran du message s'ouvre dessus.
    var launchMessage: AudioMessageModel.Visualization? { launch.message }

    /// Avant d'ouvrir l'écran du message : il prend le micro et le son pour lui.
    func willShowAudioMessage() {
        inputs.hold()
        audioHaptics.stop()
    }

    /// Écran du message fermé : le souffle récupère le micro.
    func didHideAudioMessage() {
        audioMessage.close()
        Task { await inputs.release(for: engine.gesture) }
    }

    func start() {
        guard !started else { return }
        started = true
        syncFeedbackSettings()
        feedback.prepare()
        let driver = DisplayLinkDriver { [weak self] dt in
            guard let self else { return }
            engine.tick(dt: dt)
            self.driver?.setFast(engine.needsFullFrameRate)
        }
        driver.start()
        self.driver = driver
        inputs.startMotion()
        Task { await media.useSampleVideo() }
        if let demo = launch.demo {
            // Laisse la carte prendre sa taille réelle avant de jouer le script.
            Task {
                try? await Task.sleep(for: .milliseconds(600))
                engine.startDemo(demo)
            }
        }
    }

    func syncFeedbackSettings() {
        feedback.hapticsEnabled = settings.hapticsEnabled
        feedback.soundEnabled = settings.soundEnabled
    }
}
