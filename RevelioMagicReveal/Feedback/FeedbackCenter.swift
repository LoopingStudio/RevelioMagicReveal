import Foundation
import QuartzCore
import UIKit

/// Retours haptiques (Core Haptics) et sonores (synthèse procédurale) des gestes de révélation.
///
/// Appelé par le moteur sur le main actor, jusqu'à 120 fois par seconde : chaque méthode se contente
/// de calculs scalaires, d'écritures atomiques et d'envois haptiques limités en cadence.
/// Rien ne se passe avant `prepare()` (les tests du moteur utilisent un centre jamais préparé).
final class FeedbackCenter {
    var hapticsEnabled = true {
        didSet { if hapticsEnabled != oldValue { applyHapticsSetting() } }
    }
    var soundEnabled = true {
        didSet { if soundEnabled != oldValue { applySoundSetting() } }
    }

    private let haptics = HapticPlayer()
    private let sound = ProceduralSound()
    private var prepared = false
    private var inForeground = true
    private var lifecycleObservers: [NSObjectProtocol] = []

    // Gratter
    private var feel = MaskFeel.of(.snow)
    private var isScratching = false
    private var lastScratchTime: CFTimeInterval = 0
    private var scratchMuted = true
    private var material = MaterialTracker()
    private var crinkleGate = ImpulseGate(threshold: 14, minInterval: 0.05)
    private var random = FeedbackRandom(seed: 0xF00D)

    // Souffler
    private var isBlowing = false
    private var lastBlowTime: CFTimeInterval = 0

    // Secouer
    private var lastShakeTime: CFTimeInterval = -.infinity
    private var chunkGate = ImpulseGate(threshold: 60, minInterval: 0.06)
    private var whooshGate = ImpulseGate(threshold: 80, minInterval: 0.15)

    /// Surveille les textures continues : doigt immobile, souffle qui ne vient plus, lecteurs à éteindre.
    private var watchdog: Task<Void, Never>?

    // MARK: - Cycle de vie

    func prepare() {
        guard !prepared else { return }
        prepared = true
        observeLifecycle()
        if hapticsEnabled { startHaptics() }
        if soundEnabled { startSound() }
        if HapticPlayer.isSupported, Self.drivesHardware { sound.allowHapticsDuringRecording() }
    }

    func reset() {
        guard prepared else { return }
        endContinuousFeedback()
        material.reset()
        crinkleGate.reset()
        chunkGate.reset()
        whooshGate.reset()
    }

    // MARK: - Gratter

    func scratchBegan(mask: MaskKind) {
        guard prepared else { return }
        feel = MaskFeel.of(Self.timbre(for: mask))
        isScratching = true
        scratchMuted = true
        lastScratchTime = CACurrentMediaTime()
        material.reset()
        if let crinkle = feel.crinkle {
            crinkleGate = ImpulseGate(threshold: crinkle.threshold, minInterval: crinkle.minInterval)
        }
        if hapticsEnabled { haptics.beginScratch(feel: feel) }
        startWatchdogIfNeeded()
    }

    /// `speed` : vitesse du doigt normalisée 0…1. `erodedAmount` : quantité effacée par cet échantillon.
    func scratchMoved(speed: Float, erodedAmount: Float, mask: MaskKind) {
        guard prepared, hapticsEnabled || soundEnabled else { return }
        if !isScratching { scratchBegan(mask: mask) }
        let now = CACurrentMediaTime()
        let dt = Float(min(max(now - lastScratchTime, 0.001), 0.1))
        lastScratchTime = now
        let materialLevel = material.update(erodedAmount: erodedAmount, dt: dt)
        scratchMuted = speed <= FeedbackCurves.restSpeed

        if hapticsEnabled {
            haptics.resumeScratchIfNeeded(feel: feel, now: now)
            haptics.updateScratch(
                intensity: FeedbackCurves.scratchHapticIntensity(speed: speed, material: materialLevel),
                sharpness: FeedbackCurves.scratchHapticSharpness(speed: speed, base: feel.sharpnessBase, slope: feel.sharpnessSpeed),
                now: now)
            if let crinkle = feel.crinkle, let _ = crinkleGate.add(erodedAmount, at: now), !scratchMuted {
                let intensity = random.value(in: crinkle.intensity) * (0.5 + 0.5 * FeedbackCurves.clamp01(speed))
                haptics.play([HapticEventSpec(kind: .transient, time: 0, intensity: intensity, sharpness: crinkle.sharpness)])
            }
        }
        if soundEnabled {
            sound.setScratch(gain: FeedbackCurves.scratchGain(speed: speed, material: materialLevel),
                             brightness: FeedbackCurves.scratchBrightness(speed: speed),
                             timbre: feel.timbre)
        }
    }

    func scratchEnded() {
        guard prepared, isScratching else { return }
        isScratching = false
        scratchMuted = true
        haptics.muteScratch(now: CACurrentMediaTime())
        sound.silenceScratch(timbre: feel.timbre)
    }

    // MARK: - Souffler

    /// Appelé à chaque tick quand le geste est « souffler » ; `strength` 0…1.
    func blow(strength: Float, mask: MaskKind) {
        guard prepared, hapticsEnabled else { return }
        let target = FeedbackCurves.rumbleIntensity(strength: strength)
        guard target > 0 || isBlowing else { return }
        let now = CACurrentMediaTime()
        let sharpness = FeedbackCurves.rumbleSharpness(strength: strength, base: MaskFeel.of(Self.timbre(for: mask)).rumbleSharpness)
        if target > 0 {
            if !isBlowing, HapticPlayer.isSupported, Self.drivesHardware {
                // Début d'un souffle : le micro a pu reconfigurer la session depuis le lancement.
                sound.allowHapticsDuringRecording()
            }
            isBlowing = true
            lastBlowTime = now
            // Léger frémissement à ~4,5 Hz : un souffle n'est jamais parfaitement régulier.
            let flutter = Float(0.88 + 0.12 * sin(2 * Double.pi * 4.5 * now))
            haptics.updateRumble(intensity: target * flutter, sharpness: sharpness, now: now)
            startWatchdogIfNeeded()
        } else {
            isBlowing = false
            haptics.updateRumble(intensity: 0, sharpness: sharpness, now: now)
        }
    }

    // MARK: - Secouer

    /// Une secousse détectée, `strength` 0…1.
    func shake(strength: Float, mask: MaskKind) {
        guard prepared, hapticsEnabled else { return }
        let now = CACurrentMediaTime()
        guard now - lastShakeTime >= 0.07 else { return }
        lastShakeTime = now
        let feel = MaskFeel.of(Self.timbre(for: mask))
        haptics.play(HapticScripts.impact(intensity: FeedbackCurves.shakeIntensity(strength: strength),
                                          sharpness: feel.impulseSharpness, tail: 0.08))
    }

    /// Des morceaux viennent de tomber pendant une secousse (`amount` : cellules érodées cumulées).
    func chunk(amount: Float, mask: MaskKind) {
        guard prepared, hapticsEnabled || soundEnabled else { return }
        let now = CACurrentMediaTime()
        let feel = MaskFeel.of(Self.timbre(for: mask))
        if hapticsEnabled, let released = chunkGate.add(amount, at: now) {
            haptics.play(HapticScripts.impact(intensity: FeedbackCurves.chunkIntensity(amount: released),
                                              sharpness: feel.impulseSharpness, tail: feel.impulseTail))
        }
        if soundEnabled, let released = whooshGate.add(amount, at: now) {
            sound.whoosh(amplitude: FeedbackCurves.whooshAmplitude(amount: released), timbre: feel.timbre)
        }
    }

    // MARK: - Fin

    func revealCompleted(mask: MaskKind) {
        guard prepared else { return }
        endContinuousFeedback()
        if hapticsEnabled { haptics.playCelebration() }
        if soundEnabled { sound.playChime() }
    }

    // MARK: - Musique

    /// Jingle Bells en vibrations, accompagné du glockenspiel si le son est activé.
    func playJingleBells() {
        guard prepared else { return }
        endContinuousFeedback()
        if hapticsEnabled { haptics.play(HapticScripts.melody()) }
        if soundEnabled { sound.playJingle() }
    }

    // MARK: - Interne

    private func endContinuousFeedback() {
        isScratching = false
        scratchMuted = true
        isBlowing = false
        haptics.stopScratch()
        haptics.stopRumble()
        sound.silenceScratch(timbre: feel.timbre)
    }

    private func startWatchdogIfNeeded() {
        guard watchdog == nil else { return }
        watchdog = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(40))
                guard let self, self.watch() else { break }
            }
            self?.watchdog = nil
        }
    }

    /// Un passage du chien de garde. Renvoie faux quand plus rien n'est à surveiller.
    private func watch() -> Bool {
        let now = CACurrentMediaTime()
        var busy = false
        if isScratching {
            busy = true
            // Doigt posé mais immobile : plus d'échantillons, donc plus de texture.
            if !scratchMuted, now - lastScratchTime > 0.07 {
                scratchMuted = true
                haptics.muteScratch(now: now)
            }
        } else if haptics.isScratchPlaying {
            // Lecteur gardé chaud entre deux traits rapprochés, puis éteint.
            if now - lastScratchTime > 0.35 { haptics.stopScratch() } else { busy = true }
        }
        if isBlowing, now - lastBlowTime > 0.15 {
            // Plus d'appels à `blow` (fin de révélation, app en pause) : le grondement s'éteint.
            isBlowing = false
            haptics.updateRumble(intensity: 0, sharpness: 0, now: now)
        }
        if isBlowing {
            busy = true
        } else if haptics.isRumblePlaying {
            if now - lastBlowTime > 0.5 { haptics.stopRumble() } else { busy = true }
        }
        return busy
    }

    private func applyHapticsSetting() {
        guard prepared else { return }
        if hapticsEnabled, inForeground {
            startHaptics()
        } else {
            isBlowing = false
            haptics.stop()
        }
    }

    private func applySoundSetting() {
        guard prepared else { return }
        if soundEnabled, inForeground {
            startSound()
        } else {
            sound.stop()
        }
    }

    private func observeLifecycle() {
        let center = NotificationCenter.default
        lifecycleObservers.append(center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.enterBackground() }
        })
        lifecycleObservers.append(center.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.enterForeground() }
        })
    }

    private func enterBackground() {
        inForeground = false
        endContinuousFeedback()
        haptics.stop()
        sound.stop()
    }

    private func enterForeground() {
        inForeground = true
        if hapticsEnabled { startHaptics() }
        if soundEnabled { startSound() }
    }

    private func startHaptics() {
        guard Self.drivesHardware else { return }
        haptics.start()
    }

    private func startSound() {
        guard Self.drivesHardware else { return }
        sound.start()
    }

    /// Faux quand l'app sert d'hôte aux tests unitaires : ils n'ont besoin ni du serveur audio ni du
    /// moteur haptique. Sous forte charge, le serveur audio du simulateur peut ne pas répondre à temps
    /// à l'initialisation de la sortie, et AudioToolbox tue alors le processus (vu pendant ce chantier).
    private static let drivesHardware: Bool = {
        let environment = ProcessInfo.processInfo.environment
        return !["XCTestConfigurationFilePath", "XCTestBundlePath", "XCTestSessionIdentifier"]
            .contains { environment[$0] != nil }
    }()

    private static func timbre(for mask: MaskKind) -> FeedbackTimbre {
        switch mask {
        case .frost: .frost
        case .snow: .snow
        case .paper: .paper
        case .gold: .gold
        }
    }
}
