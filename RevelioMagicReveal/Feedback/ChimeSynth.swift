import Foundation

/// Carillon de fin synthétisé hors ligne : un glockenspiel de Noël (lames frappées aux partiels
/// inharmoniques, décroissance exponentielle), un léger battement sur la fondamentale et un écho.
nonisolated enum ChimeSynth {
    static let sampleRate: Double = 48_000
    static let duration: Double = 2.8
    /// Les dernières secondes s'éteignent en fondu : le tampon finit exactement à zéro.
    static let fadeOut: Double = 0.35
    static let peakLevel: Float = 0.7

    struct Samples: Sendable {
        var left: [Float]
        var right: [Float]
        var sampleRate: Double
        var frameCount: Int { left.count }
    }

    /// Partiels d'une lame libre-libre (rapports du glockenspiel) ; `decay` en secondes pour un sol 5.
    struct Partial: Sendable {
        var ratio: Double
        var amplitude: Double
        var decay: Double
    }

    static let partials: [Partial] = [
        Partial(ratio: 1, amplitude: 1, decay: 0.9),
        Partial(ratio: 2.756, amplitude: 0.38, decay: 0.32),
        Partial(ratio: 5.404, amplitude: 0.16, decay: 0.12),
        Partial(ratio: 8.933, amplitude: 0.07, decay: 0.05),
    ]

    static func render(score: [CelebrationNote] = CelebrationScore.notes, duration: Double = duration,
                       sampleRate: Double = sampleRate) -> Samples {
        let count = Int(duration * sampleRate)
        var left = [Float](repeating: 0, count: count)
        var right = [Float](repeating: 0, count: count)
        left.withUnsafeMutableBufferPointer { l in
            right.withUnsafeMutableBufferPointer { r in
                var rng = FeedbackRandom(seed: 0xC41E)
                for note in score {
                    addNote(note, left: l, right: r, sampleRate: sampleRate, rng: &rng)
                }
                addEcho(left: l, right: r, sampleRate: sampleRate)
                finish(left: l, right: r, sampleRate: sampleRate)
            }
        }
        return Samples(left: left, right: right, sampleRate: sampleRate)
    }

    private static func addNote(_ note: CelebrationNote, left: UnsafeMutableBufferPointer<Float>,
                                right: UnsafeMutableBufferPointer<Float>, sampleRate: Double,
                                rng: inout FeedbackRandom) {
        let start = Int(note.time * sampleRate)
        guard start < left.count else { return }
        // Panoramique à puissance constante.
        let angle = Double(note.pan + 1) * .pi / 4
        let gainL = cos(angle), gainR = sin(angle)
        // Les notes aiguës s'éteignent plus vite, comme sur un vrai glockenspiel.
        let decayScale = (783.99 / note.frequency).squareRoot()
        let attackSamples = 0.0015 * sampleRate

        for partial in partials {
            let frequency = note.frequency * partial.ratio
            guard frequency < 0.45 * sampleRate else { continue }
            let amplitude = Double(note.velocity) * partial.amplitude
            // La fondamentale est doublée d'un oscillateur à peine désaccordé : un battement lent qui scintille.
            let voices: [(detune: Double, share: Double)] = partial.ratio == 1 ? [(1, 0.62), (1.0021, 0.38)] : [(1, 1)]
            for voice in voices {
                let omega = 2 * Double.pi * frequency * voice.detune / sampleRate
                let rotationCos = cos(omega), rotationSin = sin(omega)
                let decay = exp(-1 / (partial.decay * decayScale * sampleRate))
                var level = amplitude * voice.share
                // Oscillateur récursif (rotation complexe) : pas de sin() par échantillon.
                var re = 1.0, im = 0.0
                var i = start
                while i < left.count, level > 1e-5 {
                    let attack = min(1, Double(i - start) / attackSamples)
                    let value = im * level * attack
                    left[i] += Float(value * gainL)
                    right[i] += Float(value * gainR)
                    let nextRe = re * rotationCos - im * rotationSin
                    im = re * rotationSin + im * rotationCos
                    re = nextRe
                    level *= decay
                    i += 1
                    if (i - start) & 1023 == 0 {
                        let norm = 1 / (re * re + im * im).squareRoot()
                        re *= norm
                        im *= norm
                    }
                }
            }
        }

        // Le maillet : un petit clic de bruit aigu, très bref.
        var previous: Float = 0
        var level = 0.07 * note.velocity
        let clickDecay = Float(exp(-1 / (0.0015 * sampleRate)))
        var i = start
        while i < left.count, level > 1e-4 {
            let noise = rng.bipolar()
            let high = noise - previous
            previous = noise
            left[i] += high * level * Float(gainL)
            right[i] += high * level * Float(gainR)
            level *= clickDecay
            i += 1
        }
    }

    /// Écho ping-pong discret, amorti dans les aigus : un peu d'espace autour des lames.
    private static func addEcho(left: UnsafeMutableBufferPointer<Float>, right: UnsafeMutableBufferPointer<Float>, sampleRate: Double) {
        let delay = Int(0.13 * sampleRate)
        let count = left.count
        guard delay < count else { return }
        let feedback: Float = 0.28, wet: Float = 0.22, damping: Float = 0.35
        var lineL = [Float](repeating: 0, count: count)
        var lineR = [Float](repeating: 0, count: count)
        var lowL: Float = 0, lowR: Float = 0
        for i in 0..<count {
            let tapL = i >= delay ? lineL[i - delay] : 0
            let tapR = i >= delay ? lineR[i - delay] : 0
            lowL += (tapL - lowL) * damping
            lowR += (tapR - lowR) * damping
            lineL[i] = left[i] + feedback * lowR
            lineR[i] = right[i] + feedback * lowL
            left[i] += wet * lowR
            right[i] += wet * lowL
        }
    }

    /// Normalise la crête et termine par un fondu en cosinus.
    private static func finish(left: UnsafeMutableBufferPointer<Float>, right: UnsafeMutableBufferPointer<Float>, sampleRate: Double) {
        var peak: Float = 0
        for i in 0..<left.count { peak = max(peak, abs(left[i]), abs(right[i])) }
        let scale = peak > 0 ? peakLevel / peak : 0
        let fadeSamples = Int(fadeOut * sampleRate)
        let fadeStart = left.count - fadeSamples
        for i in 0..<left.count {
            var gain = scale
            if i >= fadeStart {
                let t = Float(i - fadeStart) / Float(max(fadeSamples - 1, 1))
                gain *= 0.5 * (1 + cos(.pi * t))
            }
            left[i] *= gain
            right[i] *= gain
        }
    }
}
