import CoreHaptics
import Foundation
import QuartzCore

/// Retours Core Haptics. Entièrement inerte sans matériel compatible (simulateur) : ni crash ni log.
///
/// Les rappels du moteur (`stoppedHandler`, `resetHandler`) arrivent sur une file interne : ils sont
/// fabriqués hors main actor et ne font que repasser sur le main actor.
final class HapticPlayer {
    static let isSupported = CHHapticEngine.capabilitiesForHardware().supportsHaptics

    private var engine: CHHapticEngine?
    private var isRunning = false
    private var lastStartAttempt: CFTimeInterval = -.infinity

    private var scratchPlayer: CHHapticAdvancedPatternPlayer?
    private var scratchTimbre: FeedbackTimbre?
    private(set) var isScratchPlaying = false
    private var scratchThrottle = ParameterThrottle(minInterval: 1.0 / 60)
    private var lastScratchResume: CFTimeInterval = -.infinity

    private var rumblePlayer: CHHapticAdvancedPatternPlayer?
    private(set) var isRumblePlaying = false
    private var rumbleThrottle = ParameterThrottle(minInterval: 1.0 / 30)

    private var texturePatterns: [FeedbackTimbre: CHHapticPattern] = [:]
    private var rumblePattern: CHHapticPattern?
    private var celebrationPattern: CHHapticPattern?
    /// Lecteur des vibrations déduites d'un fichier audio (arrêtable).
    private var audioDrivenPlayer: CHHapticPatternPlayer?

    var isAvailable: Bool { engine != nil }

    // MARK: - Moteur

    func start() {
        guard Self.isSupported else { return }
        if engine == nil {
            do {
                let engine = try CHHapticEngine()
                engine.playsHapticsOnly = true
                engine.isAutoShutdownEnabled = false
                engine.stoppedHandler = Self.makeStoppedHandler { [weak self] reason in
                    Task { @MainActor in self?.engineDidStop(reason) }
                }
                engine.resetHandler = Self.makeResetHandler { [weak self] in
                    Task { @MainActor in self?.engineDidReset() }
                }
                self.engine = engine
            } catch {
                FeedbackLog.report("haptics.create", error)
                return
            }
        }
        _ = ensureRunning(force: true)
    }

    /// Arrêt volontaire (réglage coupé, arrière-plan) : les lecteurs restent valides pour la reprise.
    func stop() {
        stopScratch()
        stopRumble()
        guard let engine, isRunning else { return }
        isRunning = false
        engine.stop(completionHandler: nil)
    }

    /// Démarre le moteur si nécessaire. Après un échec, on ne retente pas avant une seconde.
    private func ensureRunning(force: Bool = false) -> Bool {
        guard let engine else { return false }
        if isRunning { return true }
        let now = CACurrentMediaTime()
        guard force || now - lastStartAttempt > 1 else { return false }
        lastStartAttempt = now
        do {
            try engine.start()
            isRunning = true
        } catch {
            FeedbackLog.report("haptics.start", error)
        }
        return isRunning
    }

    private func engineDidStop(_ reason: CHHapticEngine.StoppedReason) {
        // Les lecteurs survivent à un arrêt ; ils ne jouent simplement plus. Redémarrage à la demande.
        isRunning = false
        isScratchPlaying = false
        isRumblePlaying = false
        scratchThrottle.reset()
        rumbleThrottle.reset()
    }

    private func engineDidReset() {
        // Le serveur haptique a redémarré : lecteurs invalides (les motifs, eux, restent bons).
        isRunning = false
        scratchPlayer = nil
        scratchTimbre = nil
        rumblePlayer = nil
        isScratchPlaying = false
        isRumblePlaying = false
        scratchThrottle.reset()
        rumbleThrottle.reset()
    }

    nonisolated private static func makeStoppedHandler(
        _ handler: @escaping @Sendable (CHHapticEngine.StoppedReason) -> Void
    ) -> CHHapticEngine.StoppedHandler {
        { reason in handler(reason) }
    }

    nonisolated private static func makeResetHandler(_ handler: @escaping @Sendable () -> Void) -> CHHapticEngine.ResetHandler {
        { handler() }
    }

    // MARK: - Gratter

    func beginScratch(feel: MaskFeel) {
        guard ensureRunning(), let engine else { return }
        if scratchTimbre != feel.timbre {
            stopScratch()
            scratchPlayer = nil
        }
        do {
            if scratchPlayer == nil {
                let player = try engine.makeAdvancedPlayer(with: texturePattern(for: feel))
                player.loopEnabled = true
                player.loopEnd = feel.texture.loopDuration
                scratchPlayer = player
                scratchTimbre = feel.timbre
            }
            guard let player = scratchPlayer, !isScratchPlaying else { return }
            try player.start(atTime: CHHapticTimeImmediate)
            // Départ silencieux : l'intensité suivra la vitesse du doigt dès le premier échantillon.
            try Self.send(intensity: 0, sharpness: feel.sharpnessBase, to: player)
            scratchThrottle.reset()
            _ = scratchThrottle.shouldSend(SIMD2(0, feel.sharpnessBase), at: CACurrentMediaTime())
            isScratchPlaying = true
        } catch {
            FeedbackLog.report("haptics.scratch", error)
        }
    }

    /// Le moteur a pu être arrêté par le système en plein trait : on relance la texture,
    /// au plus deux fois par seconde (un échec ne doit pas se répéter à 120 Hz).
    func resumeScratchIfNeeded(feel: MaskFeel, now: CFTimeInterval) {
        guard engine != nil, !isScratchPlaying, now - lastScratchResume > 0.5 else { return }
        lastScratchResume = now
        beginScratch(feel: feel)
    }

    func updateScratch(intensity: Float, sharpness: Float, now: CFTimeInterval) {
        guard isScratchPlaying, let player = scratchPlayer,
              scratchThrottle.shouldSend(SIMD2(intensity, sharpness), at: now) else { return }
        do {
            try Self.send(intensity: intensity, sharpness: sharpness, to: player)
        } catch {
            FeedbackLog.report("haptics.scratch.update", error)
        }
    }

    /// Doigt levé ou immobile : silence immédiat, lecteur gardé chaud quelques instants.
    func muteScratch(now: CFTimeInterval) {
        updateScratch(intensity: 0, sharpness: 0, now: now)
    }

    func stopScratch() {
        guard isScratchPlaying, let player = scratchPlayer else { return }
        isScratchPlaying = false
        try? player.stop(atTime: CHHapticTimeImmediate)
    }

    private func texturePattern(for feel: MaskFeel) throws -> CHHapticPattern {
        if let cached = texturePatterns[feel.timbre] { return cached }
        let pattern = try Self.pattern(from: feel.texture.events())
        texturePatterns[feel.timbre] = pattern
        return pattern
    }

    // MARK: - Souffler

    func updateRumble(intensity: Float, sharpness: Float, now: CFTimeInterval) {
        if intensity <= 0 {
            guard isRumblePlaying, let player = rumblePlayer,
                  rumbleThrottle.shouldSend(SIMD2(0, sharpness), at: now) else { return }
            try? Self.send(intensity: 0, sharpness: sharpness, to: player)
            return
        }
        guard ensureRunning(), let engine else { return }
        do {
            if rumblePlayer == nil {
                let pattern = try rumblePattern ?? Self.pattern(from: [
                    HapticEventSpec(kind: .continuous(duration: 4), time: 0, intensity: 1, sharpness: 0),
                ])
                rumblePattern = pattern
                let player = try engine.makeAdvancedPlayer(with: pattern)
                player.loopEnabled = true
                player.loopEnd = 4
                rumblePlayer = player
            }
            guard let player = rumblePlayer else { return }
            if !isRumblePlaying {
                try player.start(atTime: CHHapticTimeImmediate)
                isRumblePlaying = true
                rumbleThrottle.reset()
            }
            if rumbleThrottle.shouldSend(SIMD2(intensity, sharpness), at: now) {
                try Self.send(intensity: intensity, sharpness: sharpness, to: player)
            }
        } catch {
            FeedbackLog.report("haptics.rumble", error)
        }
    }

    func stopRumble() {
        guard isRumblePlaying, let player = rumblePlayer else { return }
        isRumblePlaying = false
        try? player.stop(atTime: CHHapticTimeImmediate)
    }

    // MARK: - Ponctuels

    func play(_ events: [HapticEventSpec]) {
        guard !events.isEmpty, ensureRunning(), let engine else { return }
        do {
            let player = try engine.makePlayer(with: Self.pattern(from: events))
            try player.start(atTime: CHHapticTimeImmediate)
        } catch {
            FeedbackLog.report("haptics.play", error)
        }
    }

    /// Vibrations déduites d'un son, démarrées après `delay` secondes (même délai que l'audio).
    func playAudioDriven(_ events: [HapticEventSpec], delay: Double) {
        stopAudioDriven()
        guard !events.isEmpty, ensureRunning(), let engine else { return }
        do {
            let player = try engine.makePlayer(with: Self.pattern(from: events))
            try player.start(atTime: engine.currentTime + delay)
            audioDrivenPlayer = player
        } catch {
            FeedbackLog.report("haptics.audioDriven", error)
        }
    }

    func stopAudioDriven() {
        try? audioDrivenPlayer?.stop(atTime: CHHapticTimeImmediate)
        audioDrivenPlayer = nil
    }

    func playCelebration() {
        guard ensureRunning(), let engine else { return }
        do {
            let pattern = try celebrationPattern ?? Self.pattern(from: HapticScripts.celebration())
            celebrationPattern = pattern
            try engine.makePlayer(with: pattern).start(atTime: CHHapticTimeImmediate)
        } catch {
            FeedbackLog.report("haptics.celebration", error)
        }
    }

    // MARK: - Conversion

    private static func send(intensity: Float, sharpness: Float, to player: CHHapticAdvancedPatternPlayer) throws {
        try player.sendParameters([
            CHHapticDynamicParameter(parameterID: .hapticIntensityControl, value: intensity, relativeTime: 0),
            CHHapticDynamicParameter(parameterID: .hapticSharpnessControl, value: sharpness, relativeTime: 0),
        ], atTime: CHHapticTimeImmediate)
    }

    static func pattern(from specs: [HapticEventSpec]) throws -> CHHapticPattern {
        let events = specs.map { spec -> CHHapticEvent in
            let parameters = [
                CHHapticEventParameter(parameterID: .hapticIntensity, value: FeedbackCurves.clamp01(spec.intensity)),
                CHHapticEventParameter(parameterID: .hapticSharpness, value: FeedbackCurves.clamp01(spec.sharpness)),
            ]
            switch spec.kind {
            case .transient:
                return CHHapticEvent(eventType: .hapticTransient, parameters: parameters, relativeTime: spec.time)
            case .continuous(let duration):
                return CHHapticEvent(eventType: .hapticContinuous, parameters: parameters,
                                     relativeTime: spec.time, duration: duration)
            }
        }
        return try CHHapticPattern(events: events, parameters: [])
    }
}
