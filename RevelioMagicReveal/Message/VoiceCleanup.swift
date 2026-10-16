import Accelerate
import Foundation

/// Mise en forme d'une voix captée en mode « mesure » (sans gain automatique) : souvent faible, avec du
/// grondement et des silences au début et à la fin.
nonisolated enum VoiceCleanup {
    /// Crête visée après normalisation.
    static let targetPeak: Float = 0.9
    /// Gain maximal (+24 dB) : au-delà, on ne ferait que monter le bruit de fond d'une prise ratée.
    static let maxGain: Float = 15.85
    /// Marge gardée autour de la voix quand on rogne les silences.
    static let margin = 0.15

    /// Passe-haut 80 Hz, silences rognés (marges de 150 ms), crête ramenée à 0,9 avec un gain plafonné.
    static func process(_ samples: [Float], sampleRate: Double) -> [Float] {
        guard !samples.isEmpty, sampleRate > 0 else { return [] }
        let filtered = highPass(samples, cutoff: 80, sampleRate: sampleRate)
        return normalize(trim(filtered, sampleRate: sampleRate))
    }

    /// Passe-haut de Butterworth du 2ᵉ ordre (continu, grondement, vent de la pièce).
    static func highPass(_ x: [Float], cutoff: Double, sampleRate: Double) -> [Float] {
        let w0 = 2 * Double.pi * cutoff / sampleRate
        let alpha = sin(w0) / (2 * 0.7071)
        let cosw = cos(w0)
        let a0 = 1 + alpha
        let b0 = Float((1 + cosw) / 2 / a0), b1 = Float(-(1 + cosw) / a0), b2 = b0
        let a1 = Float(-2 * cosw / a0), a2 = Float((1 - alpha) / a0)
        var out = [Float](repeating: 0, count: x.count)
        var x1: Float = 0, x2: Float = 0, y1: Float = 0, y2: Float = 0
        for i in x.indices {
            let y = b0 * x[i] + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
            x2 = x1; x1 = x[i]
            y2 = y1; y1 = y
            out[i] = y
        }
        return out
    }

    /// Garde la partie où l'on parle : des blocs de 10 ms à plus de −30 dB du bloc le plus fort, avec une
    /// marge de chaque côté. Rien d'assez fort : on rend le signal tel quel.
    static func trim(_ x: [Float], sampleRate: Double) -> [Float] {
        let hop = max(1, Int(sampleRate * 0.01))
        let blocks = (x.count + hop - 1) / hop
        var rms = [Float](repeating: 0, count: blocks)
        x.withUnsafeBufferPointer { p in
            for b in 0..<blocks {
                var meanSquare: Float = 0
                vDSP_measqv(p.baseAddress! + b * hop, 1, &meanSquare, vDSP_Length(min(hop, x.count - b * hop)))
                rms[b] = meanSquare.squareRoot()
            }
        }
        let threshold = (rms.max() ?? 0) * 0.0316
        guard threshold > 0, let first = rms.firstIndex(where: { $0 > threshold }),
              let last = rms.lastIndex(where: { $0 > threshold }) else { return x }
        let pad = Int(margin * sampleRate)
        let from = max(0, first * hop - pad)
        let to = min(x.count, (last + 1) * hop + pad)
        return Array(x[from..<to])
    }

    static func normalize(_ x: [Float]) -> [Float] {
        guard !x.isEmpty else { return x }
        var peak: Float = 0
        vDSP_maxmgv(x, 1, &peak, vDSP_Length(x.count))
        guard peak > 0 else { return x }
        var gain = min(targetPeak / peak, maxGain)
        var out = [Float](repeating: 0, count: x.count)
        vDSP_vsmul(x, 1, &gain, &out, 1, vDSP_Length(x.count))
        return out
    }
}
