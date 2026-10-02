import Observation
import SwiftUI

/// Assemble les briques de l'app et les fait vivre.
@Observable
final class AppModel {
    let settings: RevealSettings
    let feedback: FeedbackCenter
    let engine: RevealEngine
    let inputs: InputCoordinator
    let photos: PhotoStore

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
        photos = PhotoStore()
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
