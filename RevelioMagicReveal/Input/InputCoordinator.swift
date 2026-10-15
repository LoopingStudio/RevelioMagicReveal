import CoreMotion
import Foundation
import Observation
import simd

/// Branche le micro et les capteurs de mouvement sur le moteur selon le geste choisi.
@Observable
final class InputCoordinator {
    enum MicrophoneState: Equatable { case off, listening, denied, unavailable }

    private(set) var microphone: MicrophoneState = .off
    /// Prise en cours (mode debug), nil sinon.
    private(set) var recordingLabel: BlowRecorder.Label?
    /// Fichiers d'enregistrement disponibles (WAV + CSV).
    private(set) var recordings: [URL] = BlowRecorder.recordings()
    /// Nom du micro réellement utilisé, tel que le système le donne.
    private(set) var microphoneName = ""

    @ObservationIgnored private let engine: RevealEngine
    @ObservationIgnored private let settings: RevealSettings
    @ObservationIgnored private let mic: MicrophoneMonitor
    @ObservationIgnored private let motion = MotionMonitor()
    @ObservationIgnored private var shakeAnalyzer: ShakeAnalyzer
    @ObservationIgnored private var lastMotionTimestamp: TimeInterval?
    @ObservationIgnored private var shakeObserver: NSObjectProtocol?

    init(engine: RevealEngine, settings: RevealSettings) {
        self.engine = engine
        self.settings = settings
        shakeAnalyzer = ShakeAnalyzer(thresholdG: Float(settings.shakeThresholdG))
        // Le recorder rappelle hors fil principal ; on repasse sur le main actor pour l'état observé.
        let finished = FinishedRelay()
        mic = MicrophoneMonitor(recorder: BlowRecorder { url in finished.send(url) }) { [weak engine] features, dt in
            engine?.microphoneFrame(features, dt: dt)
        }
        finished.handler = { [weak self] _ in
            self?.recordingLabel = nil
            self?.recordings = BlowRecorder.recordings()
        }
    }

    func startMotion() {
        motion.start { [weak self] sample in
            self?.handle(sample)
        }
        // Simulateur : pas de capteurs, on se rabat sur la secousse système (⌃⌘Z).
        if !motion.isAvailable, shakeObserver == nil {
            shakeObserver = NotificationCenter.default.addObserver(forName: .deviceDidShake, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    let angle = Float.random(in: 0...(2 * .pi))
                    self?.engine.shakeImpulse(ShakeImpulse(strength: 0.85, direction: SIMD2(cos(angle), sin(angle))))
                }
            }
        }
    }

    /// Allume le micro seulement pour « souffler ».
    func activate(for gesture: RevealGesture) async {
        guard gesture == .blow else {
            mic.stop()
            microphone = .off
            return
        }
        guard await MicrophoneMonitor.requestPermission() else {
            microphone = .denied
            return
        }
        do {
            try await mic.start(source: settings.mic)
            // Le geste a pu changer pendant le démarrage du micro.
            guard engine.gesture == .blow else {
                mic.stop()
                microphone = .off
                return
            }
            microphone = .listening
            microphoneName = mic.sourceName
        } catch {
            microphone = .unavailable
        }
    }

    /// Nouveau choix de micro : on relance la capture si elle tourne.
    func restartMicrophone(for gesture: RevealGesture) async {
        mic.stop()
        microphone = .off
        await activate(for: gesture)
    }

    /// Enregistre 5 s étiquetées (son + mesures) pour régler la détection.
    func record(_ label: BlowRecorder.Label) {
        guard microphone == .listening, recordingLabel == nil else { return }
        recordingLabel = label
        mic.recorder.start(BlowRecorder.Context(label: label, seconds: 5,
                                                micSource: settings.mic.rawValue,
                                                thresholdDB: Float(settings.blowThresholdDB),
                                                classifier: engine.blowClassifier,
                                                audioDiagnostic: mic.diagnostic),
                           sampleRate: mic.sampleRate)
    }

    func deleteRecordings() {
        BlowRecorder.deleteAll()
        recordings = []
    }

    func suspend() {
        mic.stop()
        recordingLabel = nil
        if microphone == .listening { microphone = .off }
    }

    private func handle(_ sample: CMDeviceMotion) {
        let g = sample.gravity
        let gravity = screenVector(fromDevice: SIMD3(Float(g.x), Float(g.y), Float(g.z)))
        // Téléphone à plat : la gravité dans le plan de l'écran s'annule, on garde un minimum vers le bas.
        engine.gravity = simd_length(gravity) > 0.2 ? gravity : SIMD2(0, 0.35)

        let dt = Float(lastMotionTimestamp.map { sample.timestamp - $0 } ?? 1.0 / 60)
        lastMotionTimestamp = sample.timestamp
        shakeAnalyzer.thresholdG = Float(settings.shakeThresholdG)
        let a = sample.userAcceleration
        if let impulse = shakeAnalyzer.process(acceleration: SIMD3(Float(a.x), Float(a.y), Float(a.z)), dt: dt) {
            engine.shakeImpulse(impulse)
        }
    }
}

/// Relaie la fin d'un enregistrement (appelée hors fil principal) vers le main actor.
private final class FinishedRelay {
    var handler: ((URL?) -> Void)?

    nonisolated func send(_ url: URL?) {
        Task { @MainActor in self.handler?(url) }
    }
}
