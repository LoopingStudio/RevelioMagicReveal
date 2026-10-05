import AVFoundation
import Accelerate
import Foundation

/// Déduit des vibrations d'un fichier audio de battements de cœur : on garde les graves (là où sont les
/// coups), on suit leur enveloppe, puis on repère chaque coup (le « boum » puis le « boum » plus faible).
nonisolated enum HeartbeatAnalyzer {
    struct Beat: Equatable, Sendable {
        /// Instant du coup, en secondes depuis le début du fichier.
        var time: Double
        /// Force relative du coup, 0…1 (1 = le plus fort du fichier).
        var strength: Float
    }

    struct Analysis: Sendable {
        var beats: [Beat]
        var duration: Double
        /// Rythme cardiaque estimé (battements complets par minute), 0 si indéterminé.
        var bpm: Double
        /// Enveloppe normalisée (0…1), une valeur toutes les `hop` secondes : sert au débogage et aux tests.
        var envelope: [Float]
        var hop: Double
    }

    struct Parameters: Sendable {
        /// Fréquence de coupure du passe-bas : les coups d'un cœur sont sous ~150 Hz.
        var lowPassHz: Double = 150
        /// Pas de l'enveloppe.
        var hop: Double = 0.01
        /// Un coup doit dépasser cette part du plus fort coup voisin (fenêtre de ±1 s).
        var relativeThreshold: Float = 0.3
        /// Et ce plancher absolu (enveloppe normalisée), pour ignorer le souffle de fond.
        var absoluteThreshold: Float = 0.08
        /// Deux coups ne peuvent pas être plus proches (le « boum-boum » est espacé d'au moins ~0,15 s).
        var minInterval: Double = 0.12
    }

    enum Failure: Error { case unreadable }

    static func analyze(fileAt url: URL, parameters: Parameters = Parameters()) throws -> Analysis {
        let (samples, sampleRate) = try decodeMono(url)
        return analyze(samples: samples, sampleRate: sampleRate, parameters: parameters)
    }

    static func analyze(samples: [Float], sampleRate: Double, parameters: Parameters = Parameters()) -> Analysis {
        let duration = Double(samples.count) / sampleRate
        guard samples.count > 1 else { return Analysis(beats: [], duration: duration, bpm: 0, envelope: [], hop: parameters.hop) }

        // Passe-bas d'ordre 4 (deux biquads de Butterworth en cascade).
        let filtered = lowPass(lowPass(samples, cutoff: parameters.lowPassHz, sampleRate: sampleRate),
                               cutoff: parameters.lowPassHz, sampleRate: sampleRate)

        // Enveloppe RMS par pas de 10 ms, lissée sur 30 ms, normalisée.
        let hopSamples = max(1, Int(parameters.hop * sampleRate))
        var envelope: [Float] = stride(from: 0, to: filtered.count, by: hopSamples).map { start in
            let end = min(filtered.count, start + hopSamples)
            var meanSquare: Float = 0
            filtered.withUnsafeBufferPointer { p in
                vDSP_measqv(p.baseAddress! + start, 1, &meanSquare, vDSP_Length(end - start))
            }
            return meanSquare.squareRoot()
        }
        envelope = smooth(envelope, radius: 1)
        let peak = envelope.max() ?? 0
        guard peak > 0 else { return Analysis(beats: [], duration: duration, bpm: 0, envelope: envelope, hop: parameters.hop) }
        envelope = envelope.map { $0 / peak }

        let bpm = estimateBPM(envelope, hop: parameters.hop)
        // Rythme connu : un coup par cycle, le plus fort (les petites bosses du souffle Doppler ne
        // comptent pas). Sinon, repli sur les maxima locaux.
        let beats = bpm > 0
            ? pickCycleBeats(envelope, hop: parameters.hop, period: 60 / bpm, parameters: parameters)
            : pickBeats(envelope, hop: parameters.hop, parameters: parameters)
        return Analysis(beats: beats, duration: duration, bpm: bpm, envelope: envelope, hop: parameters.hop)
    }

    // MARK: - Étapes

    private static func decodeMono(_ url: URL) throws -> ([Float], Double) {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let frames = AVAudioFrameCount(file.length)
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { throw Failure.unreadable }
        try file.read(into: buffer)
        guard let channels = buffer.floatChannelData else { throw Failure.unreadable }
        let count = Int(buffer.frameLength)
        let channelCount = Int(format.channelCount)
        var mono = [Float](repeating: 0, count: count)
        for c in 0..<channelCount {
            vDSP_vadd(mono, 1, channels[c], 1, &mono, 1, vDSP_Length(count))
        }
        var scale = 1 / Float(channelCount)
        vDSP_vsmul(mono, 1, &scale, &mono, 1, vDSP_Length(count))
        return (mono, format.sampleRate)
    }

    /// Biquad passe-bas de Butterworth (Q = 1/√2).
    private static func lowPass(_ x: [Float], cutoff: Double, sampleRate: Double) -> [Float] {
        let w0 = 2 * Double.pi * cutoff / sampleRate
        let alpha = sin(w0) / (2 * (1 / 2.0.squareRoot()))
        let cosw = cos(w0)
        let a0 = 1 + alpha
        let b0 = Float((1 - cosw) / 2 / a0), b1 = Float((1 - cosw) / a0), b2 = b0
        let a1 = Float(-2 * cosw / a0), a2 = Float((1 - alpha) / a0)
        var y = [Float](repeating: 0, count: x.count)
        var x1: Float = 0, x2: Float = 0, y1: Float = 0, y2: Float = 0
        for i in x.indices {
            let out = b0 * x[i] + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
            x2 = x1; x1 = x[i]
            y2 = y1; y1 = out
            y[i] = out
        }
        return y
    }

    private static func smooth(_ values: [Float], radius: Int) -> [Float] {
        values.indices.map { i in
            let lo = max(0, i - radius), hi = min(values.count - 1, i + radius)
            return values[lo...hi].reduce(0, +) / Float(hi - lo + 1)
        }
    }

    /// Maxima locaux assez forts, par rapport au plancher et aux coups voisins, et assez espacés.
    private static func pickBeats(_ envelope: [Float], hop: Double, parameters: Parameters) -> [Beat] {
        let neighborhood = 3                                   // ±30 ms
        let window = max(1, Int(1.0 / hop))                    // ±1 s pour le seuil relatif
        let minGap = max(1, Int(parameters.minInterval / hop))
        var candidates: [(index: Int, value: Float)] = []
        for i in envelope.indices {
            let value = envelope[i]
            guard value >= parameters.absoluteThreshold else { continue }
            let lo = max(0, i - neighborhood), hi = min(envelope.count - 1, i + neighborhood)
            guard envelope[lo...hi].allSatisfy({ $0 <= value }) else { continue }
            let localMax = envelope[max(0, i - window)...min(envelope.count - 1, i + window)].max() ?? value
            guard value >= parameters.relativeThreshold * localMax else { continue }
            // Plateau : on ne garde que le premier point d'un maximum plat.
            if let last = candidates.last, last.index == i - 1, last.value == value { continue }
            candidates.append((i, value))
        }
        // Espacement minimal : entre deux coups trop proches, on garde le plus fort.
        var kept: [(index: Int, value: Float)] = []
        for candidate in candidates {
            if let last = kept.last, candidate.index - last.index < minGap {
                if candidate.value > last.value { kept[kept.count - 1] = candidate }
            } else {
                kept.append(candidate)
            }
        }
        return kept.map { Beat(time: Double($0.index) * hop, strength: $0.value) }
    }

    /// Un coup par cycle, repéré sur l'attaque : un vrai coup monte d'un coup, les bosses du souffle
    /// montent doucement. On cherche la montée la plus raide de chaque fenêtre de ±45 % de période, puis
    /// on date le coup au sommet qui suit (≤ 60 ms) et on prend sa force à ce sommet.
    private static func pickCycleBeats(_ envelope: [Float], hop: Double, period: Double, parameters: Parameters) -> [Beat] {
        let lag = 2
        let onset: [Float] = envelope.indices.map { i in i >= lag ? max(0, envelope[i] - envelope[i - lag]) : 0 }
        let onsetPeak = onset.max() ?? 0
        guard onsetPeak > 0 else { return [] }
        let half = max(1, Int(0.45 * period / hop))
        let toPeak = max(1, Int(0.06 / hop))
        var beats: [Beat] = []
        var lastIndex = -Int.max / 2
        for i in onset.indices where onset[i] >= 0.1 * onsetPeak {
            let lo = max(0, i - half), hi = min(onset.count - 1, i + half)
            guard let windowMax = onset[lo...hi].max(), onset[i] >= windowMax else { continue }
            let top = (i...min(envelope.count - 1, i + toPeak)).max { envelope[$0] < envelope[$1] } ?? i
            guard envelope[top] >= parameters.absoluteThreshold else { continue }
            // Plateau ou voisin trop proche : on garde le premier.
            guard Double(top - lastIndex) * hop >= 0.6 * period else { continue }
            beats.append(Beat(time: Double(top) * hop, strength: envelope[top]))
            lastIndex = top
        }
        return beats
    }

    /// Autocorrélation de l'enveloppe entre 0,3 et 1,2 s (50 à 200 battements/min).
    private static func estimateBPM(_ envelope: [Float], hop: Double) -> Double {
        let mean = envelope.reduce(0, +) / Float(max(1, envelope.count))
        let centered = envelope.map { $0 - mean }
        let minLag = Int(0.3 / hop), maxLag = min(centered.count - 1, Int(1.2 / hop))
        guard maxLag > minLag else { return 0 }
        var best: Float = 0, bestLag = 0
        centered.withUnsafeBufferPointer { p in
            for lag in minLag...maxLag {
                var dot: Float = 0
                vDSP_dotpr(p.baseAddress!, 1, p.baseAddress! + lag, 1, &dot, vDSP_Length(centered.count - lag))
                if dot > best { best = dot; bestLag = lag }
            }
        }
        return bestLag > 0 ? 60 / (Double(bestLag) * hop) : 0
    }
}

extension HapticScripts {
    /// Vibrations déduites d'un son analysé : un « boum » sourd par coup détecté (intensité selon sa
    /// force) et une nappe douce qui suit l'enveloppe du son (le souffle de l'échographie, le second
    /// battement plus faible), coupée juste après chaque coup pour ne pas l'épaissir.
    static func audioDriven(_ analysis: HeartbeatAnalyzer.Analysis) -> [HapticEventSpec] {
        var events: [HapticEventSpec] = []
        for beat in analysis.beats {
            let force = pow(beat.strength, 0.7)
            events.append(HapticEventSpec(kind: .transient, time: beat.time, intensity: 0.5 + 0.5 * force, sharpness: 0.18))
            events.append(HapticEventSpec(kind: .continuous(duration: 0.08), time: beat.time + 0.005,
                                          intensity: 0.3 + 0.35 * force, sharpness: 0.08))
        }
        // Nappe : un palier toutes les 40 ms, hors des 90 ms qui suivent un coup.
        let step = 0.04
        let beatTimes = analysis.beats.map(\.time)
        var time = 0.0
        var nextBeat = 0
        while time < analysis.duration {
            while nextBeat < beatTimes.count, beatTimes[nextBeat] + 0.09 < time { nextBeat += 1 }
            let nearBeat = nextBeat < beatTimes.count && time >= beatTimes[nextBeat] && time < beatTimes[nextBeat] + 0.09
            let index = Int(time / analysis.hop)
            if !nearBeat, index < analysis.envelope.count {
                let level = analysis.envelope[index]
                if level >= 0.06 {
                    events.append(HapticEventSpec(kind: .continuous(duration: step), time: time,
                                                  intensity: min(0.45, 0.5 * pow(level, 0.8)), sharpness: 0.05))
                }
            }
            time += step
        }
        return events.sorted { $0.time < $1.time }
    }
}
