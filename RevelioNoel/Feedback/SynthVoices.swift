import Foundation
import Synchronization

// Synthèse procédurale exécutée sur le thread audio temps réel.
// Règles : aucune allocation, aucun verrou, aucun appel bloquant. Les paramètres arrivent du main actor
// par des atomiques ; l'état des voix n'est touché que par le thread audio.

// MARK: - Paramètres partagés

/// Pont main actor → thread audio. Les flottants voyagent sous forme de motifs binaires.
nonisolated final class SynthParameters: Sendable {
    struct Scratch: Sendable {
        var serial: UInt32
        var gain: Float
        var brightness: Float
        var timbre: FeedbackTimbre
    }

    struct Whoosh: Sendable {
        var serial: UInt32
        var amplitude: Float
        var timbre: FeedbackTimbre
    }

    private let scratchGain = Atomic<UInt32>(0)
    private let scratchBrightness = Atomic<UInt32>(Float(0.5).bitPattern)
    private let scratchTimbre = Atomic<UInt8>(FeedbackTimbre.snow.rawValue)
    /// Incrémenté à chaque mise à jour : sans nouvelle valeur pendant un moment, le rendu se tait seul.
    private let scratchSerial = Atomic<UInt32>(0)
    private let whooshAmplitude = Atomic<UInt32>(0)
    private let whooshTimbre = Atomic<UInt8>(FeedbackTimbre.snow.rawValue)
    private let whooshSerial = Atomic<UInt32>(0)

    func setScratch(gain: Float, brightness: Float, timbre: FeedbackTimbre) {
        scratchGain.store(gain.bitPattern, ordering: .relaxed)
        scratchBrightness.store(brightness.bitPattern, ordering: .relaxed)
        scratchTimbre.store(timbre.rawValue, ordering: .relaxed)
        _ = scratchSerial.wrappingAdd(1, ordering: .releasing)
    }

    func triggerWhoosh(amplitude: Float, timbre: FeedbackTimbre) {
        whooshAmplitude.store(amplitude.bitPattern, ordering: .relaxed)
        whooshTimbre.store(timbre.rawValue, ordering: .relaxed)
        _ = whooshSerial.wrappingAdd(1, ordering: .releasing)
    }

    func scratch() -> Scratch {
        let serial = scratchSerial.load(ordering: .acquiring)
        return Scratch(serial: serial,
                       gain: Float(bitPattern: scratchGain.load(ordering: .relaxed)),
                       brightness: Float(bitPattern: scratchBrightness.load(ordering: .relaxed)),
                       timbre: FeedbackTimbre(rawValue: scratchTimbre.load(ordering: .relaxed)) ?? .snow)
    }

    func whoosh() -> Whoosh {
        let serial = whooshSerial.load(ordering: .acquiring)
        return Whoosh(serial: serial,
                      amplitude: Float(bitPattern: whooshAmplitude.load(ordering: .relaxed)),
                      timbre: FeedbackTimbre(rawValue: whooshTimbre.load(ordering: .relaxed)) ?? .snow)
    }
}

// MARK: - Rendu

/// État de synthèse, propriété exclusive du thread audio (d'où `@unchecked Sendable` sans verrou).
nonisolated final class SynthRenderer: @unchecked Sendable {
    /// Sans nouvelle valeur du doigt pendant ce temps (doigt immobile, main actor occupé), on se tait.
    static let holdDuration: Float = 0.09

    private let parameters: SynthParameters
    private var scratch: ScratchVoice
    private var whoosh: WhooshVoice
    private var lastScratchSerial: UInt32
    private var lastWhooshSerial: UInt32
    private var framesSinceUpdate: Int
    private let holdFrames: Int

    init(parameters: SynthParameters, sampleRate: Float) {
        self.parameters = parameters
        scratch = ScratchVoice(sampleRate: sampleRate)
        whoosh = WhooshVoice(sampleRate: sampleRate)
        lastScratchSerial = parameters.scratch().serial
        lastWhooshSerial = parameters.whoosh().serial
        holdFrames = Int(Self.holdDuration * sampleRate)
        framesSinceUpdate = holdFrames + 1
    }

    /// Remplit `out` (mono). Renvoie vrai si le tampon est entièrement silencieux.
    func render(into out: UnsafeMutablePointer<Float>, frames: Int) -> Bool {
        out.update(repeating: 0, count: frames)

        let state = parameters.scratch()
        if state.serial != lastScratchSerial {
            lastScratchSerial = state.serial
            framesSinceUpdate = 0
        }
        let targetGain = framesSinceUpdate > holdFrames ? 0 : min(max(state.gain, 0), 1)
        framesSinceUpdate = min(framesSinceUpdate + frames, Int.max / 2)

        let request = parameters.whoosh()
        if request.serial != lastWhooshSerial {
            lastWhooshSerial = request.serial
            whoosh.trigger(amplitude: request.amplitude, timbre: request.timbre)
        }

        let scratchAudible = targetGain > 0 || !scratch.isSilent
        guard scratchAudible || whoosh.isActive else { return true }

        if scratchAudible {
            scratch.setTimbre(state.timbre)
            scratch.render(into: out, frames: frames, targetGain: targetGain, targetBrightness: state.brightness)
        }
        whoosh.render(into: out, frames: frames)
        for i in 0..<frames { out[i] = Self.softLimit(out[i]) }
        return false
    }

    /// Transparent jusqu'à 0,6, puis genou doux vers 1 : jamais d'écrêtage dur.
    @inline(__always)
    static func softLimit(_ x: Float) -> Float {
        let magnitude = abs(x)
        guard magnitude > 0.6 else { return x }
        let limited = 0.6 + 0.4 * tanh((magnitude - 0.6) / 0.4)
        return x < 0 ? -limited : limited
    }
}

// MARK: - Filtre

/// Filtre à variables d'état (topologie TPT) : stable même quand la coupure bouge vite.
nonisolated struct StateVariableFilter: Sendable {
    private var ic1: Float = 0
    private var ic2: Float = 0
    private var a1: Float = 0
    private var a2: Float = 0
    private var a3: Float = 0
    private var k: Float = 1

    mutating func tune(cutoff: Float, q: Float, sampleRate: Float) {
        let fc = min(max(cutoff, 20), sampleRate * 0.45)
        let g = tan(Float.pi * fc / sampleRate)
        k = 1 / max(q, 0.1)
        a1 = 1 / (1 + g * (g + k))
        a2 = g * a1
        a3 = g * a2
    }

    @inline(__always)
    private mutating func tick(_ v0: Float) -> (low: Float, band: Float) {
        let v3 = v0 - ic2
        let v1 = a1 * ic1 + a2 * v3
        let v2 = ic2 + a2 * ic1 + a3 * v3
        ic1 = 2 * v1 - ic1
        ic2 = 2 * v2 - ic2
        return (v2, v1)
    }

    @inline(__always)
    mutating func lowpass(_ x: Float) -> Float { tick(x).low }

    @inline(__always)
    mutating func highpass(_ x: Float) -> Float {
        let (low, band) = tick(x)
        return x - k * band - low
    }

    /// Passe-bande de gain unitaire au centre.
    @inline(__always)
    mutating func bandpass(_ x: Float) -> Float { k * tick(x).band }

    /// Passe-bande résonant (gain Q au centre) : pour faire « chanter » un bruit impulsionnel.
    @inline(__always)
    mutating func resonator(_ x: Float) -> Float { tick(x).band }

    mutating func reset() {
        ic1 = 0
        ic2 = 0
    }
}

// MARK: - Grattement

/// Bruit filtré dont le timbre dépend du masque. Gain et brillance sont lissés pour éviter les clics.
nonisolated struct ScratchVoice: Sendable {
    static let blockSize = 32

    let sampleRate: Float
    private(set) var timbre: FeedbackTimbre = .snow
    private var rng = FeedbackRandom(seed: 0x5EED_1234)
    private var gain: Float = 0
    private var brightness: Float = 0.5
    private var filterA = StateVariableFilter()
    private var filterB = StateVariableFilter()
    /// Enveloppe granulaire (râpe, crépitements, adhérence-glissement).
    private var grain: Float = 0
    private var grainDecay: Float = 0.99
    private var grainProbability: Float = 0
    /// Modulations lentes : respiration de la neige, vibrato du crissement.
    private var slow: Float = 0.5
    private var slowTarget: Float = 0.5
    private var slowCounter = 0
    /// Passe-haut à un pôle (~250 Hz) : le haut-parleur de l'iPhone ne rend rien en dessous.
    private var bassState: Float = 0
    private let bassCoefficient: Float
    private let attackCoefficient: Float
    private let releaseCoefficient: Float
    private let brightnessCoefficient: Float

    init(sampleRate: Float) {
        self.sampleRate = sampleRate
        attackCoefficient = 1 - exp(-1 / (0.010 * sampleRate))
        releaseCoefficient = 1 - exp(-1 / (0.045 * sampleRate))
        brightnessCoefficient = 1 - exp(-Float(Self.blockSize) / (0.04 * sampleRate))
        bassCoefficient = 1 - exp(-2 * Float.pi * 250 / sampleRate)
        configure()
    }

    var isSilent: Bool { gain < 1e-5 }

    mutating func setTimbre(_ newTimbre: FeedbackTimbre) {
        guard newTimbre != timbre else { return }
        timbre = newTimbre
        filterA.reset()
        filterB.reset()
        grain = 0
        bassState = 0
        configure()
    }

    /// Ajoute la voix au tampon.
    mutating func render(into out: UnsafeMutablePointer<Float>, frames: Int, targetGain: Float, targetBrightness: Float) {
        let brightnessTarget = FeedbackCurves.clamp01(targetBrightness)
        var index = 0
        while index < frames {
            let end = min(index + Self.blockSize, frames)
            brightness += (brightnessTarget - brightness) * brightnessCoefficient
            configure()
            for i in index..<end {
                gain += (targetGain - gain) * (targetGain > gain ? attackCoefficient : releaseCoefficient)
                out[i] += nextSample() * gain
            }
            index = end
        }
        if targetGain == 0, gain < 1e-5 { gain = 0 }
    }

    /// Recalcule filtres et densité de grains pour la brillance courante (une fois par bloc).
    private mutating func configure() {
        let b = brightness
        let fs = sampleRate
        switch timbre {
        case .gold:
            // Aigu et râpeux : bruit éclairci, bande haute, grains serrés et secs.
            filterA.tune(cutoff: 1500, q: 0.7, sampleRate: fs)
            filterB.tune(cutoff: 2800 + 3800 * b, q: 1.1, sampleRate: fs)
            grainProbability = (120 + 380 * b) / fs
            grainDecay = exp(-1 / (0.0025 * fs))
        case .snow:
            // Souffle feutré : bruit très adouci (passe-bas 24 dB/oct), petits tassements mous.
            let cutoff = 1000 + 1500 * b
            filterA.tune(cutoff: cutoff, q: 0.55, sampleRate: fs)
            filterB.tune(cutoff: cutoff, q: 0.55, sampleRate: fs)
            grainProbability = (18 + 40 * b) / fs
            grainDecay = exp(-1 / (0.009 * fs))
        case .frost:
            // Crissement : sifflement aigu + résonance étroite excitée par adhérence-glissement.
            filterA.tune(cutoff: 5200 + 2400 * b, q: 1.8, sampleRate: fs)
            let squeak = (1900 + 1500 * b) * (1 + 0.05 * (slow * 2 - 1))
            filterB.tune(cutoff: squeak, q: 14, sampleRate: fs)
            grainProbability = (60 + 160 * b) / fs
            grainDecay = exp(-1 / (0.0018 * fs))
        case .paper:
            // Froissement : bande médium, crépitements irréguliers (la décroissance varie par grain).
            filterA.tune(cutoff: 400, q: 0.7, sampleRate: fs)
            filterB.tune(cutoff: 1100 + 2000 * b, q: 0.9, sampleRate: fs)
            grainProbability = (25 + 140 * b) / fs
        }
        // Modulation lente : nouvelle cible toutes les ~40 ms, approchée en douceur.
        slowCounter += 1
        if slowCounter * Self.blockSize >= Int(0.04 * fs) {
            slowCounter = 0
            slowTarget = rng.uniform()
        }
        slow += (slowTarget - slow) * 0.08
    }

    @inline(__always)
    private mutating func nextSample() -> Float {
        let noise = rng.bipolar()
        switch timbre {
        case .gold:
            if rng.uniform() < grainProbability { grain = max(grain, 0.5 + 0.5 * rng.uniform()) }
            grain *= grainDecay
            let band = filterB.bandpass(filterA.highpass(noise))
            return band * (0.3 + 0.9 * grain) * 0.85
        case .snow:
            if rng.uniform() < grainProbability { grain = max(grain, 0.2 + 0.3 * rng.uniform()) }
            grain *= grainDecay
            let soft = filterB.lowpass(filterA.lowpass(noise))
            bassState += (soft - bassState) * bassCoefficient
            return (soft - bassState) * (0.7 + 0.6 * slow + 0.6 * grain) * 1.4
        case .frost:
            if rng.uniform() < grainProbability { grain = max(grain, 0.5 + 0.5 * rng.uniform()) }
            grain *= grainDecay
            let hiss = filterA.bandpass(noise)
            let squeak = filterB.resonator(noise * grain)
            return hiss * 0.28 + squeak * 0.5
        case .paper:
            if rng.uniform() < grainProbability {
                let u = rng.uniform()
                grain = max(grain, 0.15 + 0.85 * u * u * u)
                grainDecay = exp(-1 / ((0.002 + 0.008 * rng.uniform()) * sampleRate))
            }
            grain *= grainDecay
            let band = filterB.bandpass(filterA.highpass(noise))
            return band * (0.12 + 1.1 * grain) * 1.6
        }
    }
}

// MARK: - Whoosh

/// Souffle bref dont la bande descend : des morceaux qui se détachent et tombent.
nonisolated struct WhooshVoice: Sendable {
    let sampleRate: Float
    private var rng = FeedbackRandom(seed: 0xB10B_5EED)
    private var filter = StateVariableFilter()
    private var envelope: Float = 0
    private var peak: Float = 0
    private var attackStep: Float = 0
    private var attacking = false
    private var decay: Float = 0.999
    private var cutoff: Float = 1000
    private var cutoffEnd: Float = 300
    private var blockSweep: Float = 1
    private var q: Float = 0.9
    private(set) var isActive = false

    init(sampleRate: Float) {
        self.sampleRate = sampleRate
    }

    mutating func trigger(amplitude: Float, timbre: FeedbackTimbre) {
        let from: Float, to: Float, tau: Float
        switch timbre {
        case .snow: (from, to, q, tau) = (1100, 220, 0.7, 0.11)   // motte sourde
        case .frost: (from, to, q, tau) = (4200, 1500, 1.4, 0.07) // éclats de glace
        case .paper: (from, to, q, tau) = (2600, 600, 0.9, 0.09)  // papier qui tombe
        case .gold: (from, to, q, tau) = (3600, 1100, 1.2, 0.08)  // copeaux
        }
        // Redéclenchement : on repart du niveau courant, sans saut.
        peak = max(envelope, FeedbackCurves.clamp01(amplitude))
        attackStep = max(peak - envelope, 0) / (0.008 * sampleRate)
        attacking = attackStep > 0
        cutoff = from
        cutoffEnd = to
        blockSweep = pow(to / from, Float(ScratchVoice.blockSize) / (0.25 * sampleRate))
        decay = exp(-1 / (tau * sampleRate))
        isActive = true
    }

    mutating func render(into out: UnsafeMutablePointer<Float>, frames: Int) {
        guard isActive else { return }
        var index = 0
        while index < frames {
            let end = min(index + ScratchVoice.blockSize, frames)
            filter.tune(cutoff: cutoff, q: q, sampleRate: sampleRate)
            for i in index..<end {
                if attacking {
                    envelope += attackStep
                    if envelope >= peak {
                        envelope = peak
                        attacking = false
                    }
                } else {
                    envelope *= decay
                }
                out[i] += filter.bandpass(rng.bipolar()) * envelope * 0.9
            }
            cutoff = max(cutoffEnd, cutoff * blockSweep)
            index = end
        }
        if !attacking, envelope < 1e-4 {
            envelope = 0
            isActive = false
            filter.reset()
        }
    }
}
