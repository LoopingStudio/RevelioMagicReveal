import Accelerate
import Foundation

/// Un message vocal : la voix en mono, prête à lire et à analyser.
nonisolated struct AudioMessage: Sendable, Identifiable {
    enum Source: Sendable, Equatable { case recording, sample }

    let id = UUID()
    let samples: [Float]
    let sampleRate: Double
    let source: Source

    var duration: Double { sampleRate > 0 ? Double(samples.count) / sampleRate : 0 }

    /// Moyenne du signal sur `window` secondes autour de `time` (0 hors du message) : un point
    /// d'oscilloscope, lissé juste ce qu'il faut pour l'échelle de temps où on le dessine.
    func average(at time: Double, window: Double) -> Float {
        let center = Int((time * sampleRate).rounded())
        let half = max(0, Int(window * sampleRate / 2))
        let from = max(0, center - half), to = min(samples.count, center + half + 1)
        guard from < to else { return 0 }
        var sum: Float = 0
        for i in from..<to { sum += samples[i] }
        return sum / Float(to - from)
    }

    /// Dernier passage par zéro montant avant `time` (cherché sur `within` secondes) : caler
    /// l'oscilloscope dessus le fait tenir en place au lieu de trembler d'une image à l'autre.
    func risingZeroCrossing(before time: Double, within: Double) -> Double {
        let end = min(samples.count - 1, Int(time * sampleRate))
        let start = max(1, end - Int(within * sampleRate))
        guard start < end else { return time }
        for i in stride(from: end, through: start, by: -1) where samples[i - 1] < 0 && samples[i] >= 0 {
            return Double(i) / sampleRate
        }
        return time
    }
}

/// Tout ce que les visualisations lisent d'un message, calculé une fois (hors fil principal) à 100 trames
/// par seconde. Les vues n'ont plus qu'à interpoler à l'instant de lecture : rendu fluide, sans tap audio
/// en direct, et le même message donne toujours la même image au même instant.
nonisolated struct AudioMessageAnalysis: Sendable {
    static let frameRate = 100.0
    static let bandCount = 32
    /// La voix tient là ; sous 100 Hz, une FFT de 40 ms n'a de toute façon presque plus de cases.
    static let bandRange: ClosedRange<Double> = 100...8000

    struct Onset: Sendable, Equatable {
        var time: Double
        /// 0…1, relatif à l'attaque la plus franche du message.
        var strength: Float
    }

    let duration: Double
    let frameCount: Int
    /// Crête absolue du signal (échelle de l'oscilloscope).
    let peak: Float
    /// Niveau brut par trame (dB ramenés à 0…1) : formes d'onde.
    let envelope: [Float]
    /// Niveau lissé façon vumètre (montée ~10 ms, retombée ~150 ms), 0…1.
    let level: [Float]
    /// `frameCount × bandCount` valeurs lissées comme le niveau, 0…1.
    let bands: [Float]
    /// Crêtes des bandes, qui retombent doucement (égaliseur).
    let peaks: [Float]
    /// Centre de gravité du spectre, 0 (grave) … 1 (aigu), en échelle logarithmique.
    let centroid: [Float]
    /// Niveau lissé cumulé depuis le début (secondes × niveau) : la couronne tourne à mesure que la voix avance.
    let cumulative: [Float]
    /// Attaques de syllabes.
    let onsets: [Onset]

    /// Fréquence centrale de chaque bande (Hz).
    static var bandCenters: [Double] {
        let ratio = bandRange.upperBound / bandRange.lowerBound
        return (0..<bandCount).map { bandRange.lowerBound * pow(ratio, (Double($0) + 0.5) / Double(bandCount)) }
    }

    // MARK: - Lecture à un instant

    func level(at time: Double) -> Float { sample(level, at: time) }
    func envelope(at time: Double) -> Float { sample(envelope, at: time) }
    func centroid(at time: Double) -> Float { sample(centroid, at: time) }
    func cumulative(at time: Double) -> Float { sample(cumulative, at: time) }
    func spectrum(at time: Double) -> [Float] { sampleBands(bands, at: time) }
    func peaks(at time: Double) -> [Float] { sampleBands(peaks, at: time) }

    /// Crête de l'enveloppe sur un intervalle (barres d'une forme d'onde qui défile).
    func envelopePeak(in range: ClosedRange<Double>) -> Float {
        guard frameCount > 0 else { return 0 }
        let from = max(0, Int(range.lowerBound * Self.frameRate))
        let to = min(frameCount - 1, Int(range.upperBound * Self.frameRate))
        guard from <= to else { return 0 }
        return envelope[from...to].max() ?? 0
    }

    /// Attaques comprises dans l'intervalle (les plus anciennes d'abord).
    func onsets(in range: ClosedRange<Double>) -> [Onset] {
        onsets.filter { range.contains($0.time) }
    }

    /// Vue d'ensemble du message en `bars` barres (crête de l'enveloppe sur chaque tranche, en hauteur
    /// d'onde), la plus haute ramenée à 1 : la forme d'onde des messages vocaux.
    func overview(bars: Int) -> [Float] {
        guard bars > 0 else { return [] }
        guard frameCount > 0 else { return [Float](repeating: 0, count: bars) }
        var out = [Float](repeating: 0, count: bars)
        for bar in 0..<bars {
            let from = bar * frameCount / bars
            let to = min(frameCount, max(from + 1, (bar + 1) * frameCount / bars))
            for i in from..<to { out[bar] = max(out[bar], envelope[i]) }
        }
        out = out.map(Self.waveHeight)
        let top = out.max() ?? 0
        return top > 0 ? out.map { $0 / top } : out
    }

    /// Hauteur d'une barre de forme d'onde pour un niveau 0…1 (dB) : on revient vers l'amplitude, sinon
    /// une voix régulière donne des barres presque toutes égales.
    static func waveHeight(_ level: Float) -> Float {
        level > 0 ? pow(pow(10, (level - 1) * 48 / 20), 0.7) : 0
    }

    private func position(_ time: Double) -> (Int, Int, Float)? {
        guard frameCount > 0 else { return nil }
        let x = min(max(time * Self.frameRate, 0), Double(frameCount - 1))
        let i0 = Int(x)
        return (i0, min(i0 + 1, frameCount - 1), Float(x - Double(i0)))
    }

    private func sample(_ values: [Float], at time: Double) -> Float {
        guard let (i0, i1, f) = position(time) else { return 0 }
        return values[i0] + (values[i1] - values[i0]) * f
    }

    private func sampleBands(_ values: [Float], at time: Double) -> [Float] {
        let count = Self.bandCount
        guard let (i0, i1, f) = position(time) else { return [Float](repeating: 0, count: count) }
        return (0..<count).map { b in
            let a = values[i0 * count + b]
            return a + (values[i1 * count + b] - a) * f
        }
    }

    // MARK: - Analyse

    static func analyze(_ message: AudioMessage) -> AudioMessageAnalysis {
        let samples = message.samples
        let sampleRate = message.sampleRate
        let hop = max(1, Int((sampleRate / frameRate).rounded()))
        let frames = samples.isEmpty ? 0 : (samples.count + hop - 1) / hop
        guard frames > 0 else { return silent(frames: 0, duration: message.duration) }

        let spectrum = SpectrumAnalyzer(sampleRate: sampleRate)
        let n = spectrum.frameSize
        let bins = SpectrumAnalyzer.bandBins(count: bandCount, range: bandRange, frameSize: n, sampleRate: sampleRate)
        // Marges de silence : chaque fenêtre d'analyse, centrée sur sa trame, tient dans le tampon.
        var padded = [Float](repeating: 0, count: samples.count + 2 * n)
        padded.replaceSubrange(n..<(n + samples.count), with: samples)

        var levelDB = [Float](repeating: -.infinity, count: frames)
        var bandDB = [Float](repeating: -.infinity, count: frames * bandCount)
        var centroid = [Float](repeating: 0, count: frames)
        let centroidBins = bins[0].lowerBound..<bins[bandCount - 1].upperBound
        let octaves = log2(bandRange.upperBound / bandRange.lowerBound)

        padded.withUnsafeBufferPointer { buffer in
            let base = buffer.baseAddress! + n
            for i in 0..<frames {
                let start = i * hop
                var meanSquare: Float = 0
                vDSP_measqv(base + start, 1, &meanSquare, vDSP_Length(min(hop, samples.count - start)))
                if meanSquare > 1e-12 { levelDB[i] = 10 * log10(meanSquare) }

                let power = spectrum.analyze(base + start + hop / 2 - n / 2)
                for (b, range) in bins.enumerated() {
                    var sum: Float = 0
                    for k in range { sum += power[k] }
                    if sum > 1e-12 { bandDB[i * bandCount + b] = 10 * log10(sum) }
                }
                var total: Double = 0, weighted: Double = 0
                for k in centroidBins {
                    total += Double(power[k])
                    weighted += Double(power[k]) * Double(k)
                }
                if total > 1e-12 {
                    let hz = weighted / total * spectrum.binHz
                    centroid[i] = Float(min(max(log2(hz / bandRange.lowerBound) / octaves, 0), 1))
                }
            }
        }

        // Échelles propres au message : le haut est son 99ᵉ centile, pas une valeur absolue (un vocal
        // enregistré sans gain automatique et la voix de synthèse n'ont pas du tout le même niveau).
        guard let levelTop = percentile(levelDB, 0.99), let bandTop = percentile(bandDB, 0.99) else {
            return silent(frames: frames, duration: message.duration)
        }
        let envelope = levelDB.map { normalize($0, top: levelTop, range: 48) }
        let rawBands = bandDB.map { normalize($0, top: bandTop, range: 60) }
        let level = meter(envelope, channels: 1)
        let bands = meter(rawBands, channels: bandCount)

        var peaks = bands
        var hold = [Float](repeating: 0, count: bandCount)
        for i in 0..<frames {
            for b in 0..<bandCount {
                hold[b] = max(bands[i * bandCount + b], hold[b] - 0.008)
                peaks[i * bandCount + b] = hold[b]
            }
        }

        var cumulative = [Float](repeating: 0, count: frames)
        var sum: Float = 0
        for i in 0..<frames {
            sum += level[i] / Float(frameRate)
            cumulative[i] = sum
        }

        var peak: Float = 0
        vDSP_maxmgv(samples, 1, &peak, vDSP_Length(samples.count))

        return AudioMessageAnalysis(duration: message.duration, frameCount: frames, peak: peak, envelope: envelope,
                                    level: level, bands: bands, peaks: peaks, centroid: centroid,
                                    cumulative: cumulative,
                                    onsets: detectOnsets(envelope: envelope, bands: rawBands, frames: frames))
    }

    /// Attaques : flux spectral (bandes qui montent) et montée du niveau, au-dessus d'un seuil qui suit la
    /// moyenne locale ; au moins 120 ms entre deux, et seulement quand le niveau est déjà franc.
    private static func detectOnsets(envelope: [Float], bands: [Float], frames: Int) -> [Onset] {
        guard frames > 2 else { return [] }
        var strength = [Float](repeating: 0, count: frames)
        for i in 1..<frames {
            var flux: Float = 0
            for b in 0..<bandCount {
                flux += max(0, bands[i * bandCount + b] - bands[(i - 1) * bandCount + b])
            }
            let rise = max(0, envelope[i] - envelope[max(0, i - 3)])
            strength[i] = 0.5 * flux / Float(bandCount) + 0.5 * rise
        }
        var found: [(frame: Int, value: Float)] = []
        var last = Int.min / 2
        for i in 1..<(frames - 1) {
            let from = max(0, i - 30), to = min(frames, i + 10)
            var mean: Float = 0
            for j in from..<to { mean += strength[j] }
            mean /= Float(to - from)
            guard strength[i] > mean * 1.4 + 0.03, strength[i] >= strength[i - 1], strength[i] >= strength[i + 1],
                  envelope[i] > 0.25, i - last >= 12 else { continue }
            found.append((i, strength[i]))
            last = i
        }
        let top = found.map(\.value).max() ?? 1
        return found.map { Onset(time: Double($0.frame) / frameRate, strength: $0.value / top) }
    }

    private static func silent(frames: Int, duration: Double) -> AudioMessageAnalysis {
        let zeros = [Float](repeating: 0, count: frames)
        let zeroBands = [Float](repeating: 0, count: frames * bandCount)
        return AudioMessageAnalysis(duration: duration, frameCount: frames, peak: 0, envelope: zeros, level: zeros,
                                    bands: zeroBands, peaks: zeroBands, centroid: zeros, cumulative: zeros, onsets: [])
    }

    private static func percentile(_ values: [Float], _ p: Double) -> Float? {
        let finite = values.filter(\.isFinite).sorted()
        guard !finite.isEmpty else { return nil }
        return finite[min(finite.count - 1, Int(Double(finite.count - 1) * p))]
    }

    private static func normalize(_ db: Float, top: Float, range: Float) -> Float {
        guard db.isFinite else { return 0 }
        return min(max((db - (top - range)) / range, 0), 1)
    }

    /// Lissage de vumètre, canal par canal : montée rapide (~10 ms), retombée lente (~150 ms).
    private static func meter(_ raw: [Float], channels: Int) -> [Float] {
        let attack = Float(1 - exp(-1 / (frameRate * 0.01)))
        let release = Float(1 - exp(-1 / (frameRate * 0.15)))
        var out = raw
        var state = [Float](repeating: 0, count: channels)
        for i in 0..<(raw.count / channels) {
            for c in 0..<channels {
                let x = raw[i * channels + c]
                state[c] += (x - state[c]) * (x > state[c] ? attack : release)
                out[i * channels + c] = state[c]
            }
        }
        return out
    }
}
