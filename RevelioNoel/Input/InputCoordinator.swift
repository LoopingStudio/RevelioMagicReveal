import CoreMotion
import Foundation
import Observation
import simd

/// Branche le micro et les capteurs de mouvement sur le moteur selon le geste choisi.
@Observable
final class InputCoordinator {
    enum MicrophoneState: Equatable { case off, listening, denied, unavailable }

    private(set) var microphone: MicrophoneState = .off

    @ObservationIgnored private let engine: RevealEngine
    @ObservationIgnored private let settings: RevealSettings
    @ObservationIgnored private let mic = MicrophoneMonitor()
    @ObservationIgnored private let motion = MotionMonitor()
    @ObservationIgnored private var shakeAnalyzer: ShakeAnalyzer
    @ObservationIgnored private var lastMotionTimestamp: TimeInterval?
    @ObservationIgnored private var shakeObserver: NSObjectProtocol?

    init(engine: RevealEngine, settings: RevealSettings) {
        self.engine = engine
        self.settings = settings
        shakeAnalyzer = ShakeAnalyzer(thresholdG: Float(settings.shakeThresholdG))
        mic.onLevel = { [weak self] db, dt in
            self?.engine.microphoneLevel(db, dt: dt)
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
            try mic.start()
            microphone = .listening
        } catch {
            microphone = .unavailable
        }
    }

    func suspend() {
        mic.stop()
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
