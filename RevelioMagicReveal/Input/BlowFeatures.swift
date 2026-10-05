import Accelerate
import Foundation

/// Mesures d'un bloc audio (~40 ms) qui distinguent un souffle de la voix.
///
/// - Un souffle sur un micro est un bruit d'air turbulent : spectre plat, beaucoup de graves (le vent
///   sur la membrane), aucune hauteur de note.
/// - La voix a des voyelles périodiques (hauteur 70-400 Hz et ses harmoniques) et un débit haché.
nonisolated struct BlowFeatures: Equatable, Sendable {
    /// Niveau RMS du bloc, en dBFS.
    var levelDB: Float = -120
    /// Platitude spectrale 100-4000 Hz (moyenne géométrique / arithmétique) : ~1 bruit blanc, ~0 son pur.
    var flatness: Float = 0
    /// Pic d'autocorrélation normalisée dans la plage de hauteur de la voix, après pré-accentuation :
    /// élevé pour une voyelle, faible pour un bruit d'air.
    var harmonicity: Float = 0
    /// Part de l'énergie sous 300 Hz (sur 50-8000 Hz).
    var lowRatio: Float = 0
    /// Part de l'énergie au-dessus de 4 kHz (sifflantes « s », « ch »).
    var highRatio: Float = 0
    /// Centre de gravité du spectre, en Hz.
    var centroidHz: Float = 0
    /// Passages par zéro par échantillon.
    var zeroCrossingRate: Float = 0
    /// Hauteur estimée (Hz) quand le bloc est assez harmonique, 0 sinon.
    var pitchHz: Float = 0
    /// Crête du bloc (valeur absolue maximale, 1 = pleine échelle).
    var peak: Float = 0
    /// Part des échantillons écrêtés (|x| ≥ 0,98) : un souffle collé au micro sature.
    var clipRatio: Float = 0

    static let csvHeader = "levelDB,flatness,harmonicity,lowRatio,highRatio,centroidHz,zcr,pitchHz,peak,clipRatio"

    var csvRow: String {
        String(format: "%.2f,%.4f,%.4f,%.4f,%.4f,%.1f,%.4f,%.1f,%.4f,%.4f",
               levelDB, flatness, harmonicity, lowRatio, highRatio, centroidHz, zeroCrossingRate, pitchHz, peak, clipRatio)
    }
}

/// Calcule les mesures par blocs de `frameSize` échantillons. Réutilise ses tampons : une instance par
/// flux audio, utilisée depuis un seul fil à la fois (le tap du micro).
nonisolated final class BlowFeatureExtractor: @unchecked Sendable {
    let frameSize: Int
    let sampleRate: Float
    private let log2n: vDSP_Length
    private let fftSetup: FFTSetup
    private var window: [Float]
    private var windowed: [Float]
    private var emphasized: [Float]
    private var real: [Float]
    private var imag: [Float]
    private var power: [Float]
    /// Autocorrélation normalisée de la fenêtre : une voyelle fenêtrée perd de la corrélation avec le
    /// décalage à cause de la fenêtre seule ; on divise par celle-ci (méthode de Boersma).
    private var windowCorrelation: [Float]

    init(frameSize: Int = 2048, sampleRate: Float) {
        precondition(frameSize.nonzeroBitCount == 1, "frameSize doit être une puissance de 2")
        self.frameSize = frameSize
        self.sampleRate = sampleRate
        log2n = vDSP_Length(frameSize.trailingZeroBitCount)
        fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
        window = [Float](repeating: 0, count: frameSize)
        vDSP_hann_window(&window, vDSP_Length(frameSize), Int32(vDSP_HANN_NORM))
        windowed = [Float](repeating: 0, count: frameSize)
        emphasized = [Float](repeating: 0, count: frameSize)
        real = [Float](repeating: 0, count: frameSize / 2)
        imag = [Float](repeating: 0, count: frameSize / 2)
        power = [Float](repeating: 0, count: frameSize / 2)
        windowCorrelation = [Float](repeating: 0, count: frameSize / 2 + 1)
        var w0: Float = 0
        vDSP_svesq(window, 1, &w0, vDSP_Length(frameSize))
        window.withUnsafeBufferPointer { w in
            for lag in 0...(frameSize / 2) {
                var dot: Float = 0
                vDSP_dotpr(w.baseAddress!, 1, w.baseAddress! + lag, 1, &dot, vDSP_Length(frameSize - lag))
                windowCorrelation[lag] = dot / w0
            }
        }
    }

    deinit {
        vDSP_destroy_fftsetup(fftSetup)
    }

    /// Analyse exactement `frameSize` échantillons.
    func analyze(_ samples: UnsafeBufferPointer<Float>) -> BlowFeatures {
        precondition(samples.count >= frameSize)
        let n = frameSize
        let base = samples.baseAddress!
        var features = BlowFeatures()

        var meanSquare: Float = 0
        vDSP_measqv(base, 1, &meanSquare, vDSP_Length(n))
        features.levelDB = 20 * log10(max(meanSquare.squareRoot(), 1e-7))

        var crossings = 0
        var clipped = 0
        for i in 0..<n {
            if abs(samples[i]) >= 0.98 { clipped += 1 }
            if i > 0, (samples[i] >= 0) != (samples[i - 1] >= 0) { crossings += 1 }
        }
        features.zeroCrossingRate = Float(crossings) / Float(n)
        features.clipRatio = Float(clipped) / Float(n)
        var peak: Float = 0
        vDSP_maxmgv(base, 1, &peak, vDSP_Length(n))
        features.peak = peak

        // Spectre de puissance (fenêtre de Hann).
        vDSP_vmul(base, 1, window, 1, &windowed, 1, vDSP_Length(n))
        real.withUnsafeMutableBufferPointer { rp in
            imag.withUnsafeMutableBufferPointer { ip in
                var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                windowed.withUnsafeBufferPointer { wp in
                    wp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: n / 2) { complex in
                        vDSP_ctoz(complex, 2, &split, 1, vDSP_Length(n / 2))
                    }
                }
                vDSP_fft_zrip(fftSetup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                // La case 0 mélange continu et Nyquist : on l'écarte.
                split.imagp[0] = 0
                split.realp[0] = 0
                vDSP_zvmags(&split, 1, &power, 1, vDSP_Length(n / 2))
            }
        }

        let binHz = sampleRate / Float(n)
        func bin(_ hz: Float) -> Int { min(n / 2 - 1, max(1, Int((hz / binHz).rounded()))) }
        let eps: Float = 1e-12

        // Platitude 100-4000 Hz.
        let lo = bin(100), hi = bin(4000)
        var logSum: Float = 0, sum: Float = 0
        for k in lo...hi {
            let p = power[k] + eps
            logSum += log(p)
            sum += p
        }
        let count = Float(hi - lo + 1)
        features.flatness = exp(logSum / count) / (sum / count)

        // Répartition de l'énergie et centre de gravité, 50-8000 Hz.
        let total0 = bin(50), total1 = bin(8000), low1 = bin(300), high0 = bin(4000)
        var total: Float = eps, low: Float = 0, high: Float = 0, weighted: Float = 0
        for k in total0...total1 {
            let p = power[k]
            total += p
            weighted += p * Float(k) * binHz
            if k <= low1 { low += p }
            if k >= high0 { high += p }
        }
        features.lowRatio = low / total
        features.highRatio = high / total
        features.centroidHz = weighted / total

        // Harmonicité : pré-accentuation (blanchit le grondement du vent), puis autocorrélation
        // normalisée sur les décalages d'une voix (70-400 Hz).
        emphasized[0] = samples[0]
        for i in 1..<n { emphasized[i] = samples[i] - 0.97 * samples[i - 1] }
        vDSP_vmul(emphasized, 1, window, 1, &emphasized, 1, vDSP_Length(n))
        var energy: Float = 0
        vDSP_svesq(emphasized, 1, &energy, vDSP_Length(n))
        if energy > 1e-9 {
            // Au-delà de ~n/3, la fenêtre a perdu trop de corrélation pour qu'on puisse la compenser.
            let minLag = Int(sampleRate / 400), maxLag = min(n / 3, Int(sampleRate / 70))
            var best: Float = 0, bestLag = 0
            emphasized.withUnsafeBufferPointer { e in
                for lag in minLag...maxLag {
                    var dot: Float = 0
                    vDSP_dotpr(e.baseAddress!, 1, e.baseAddress! + lag, 1, &dot, vDSP_Length(n - lag))
                    let r = dot / energy / max(windowCorrelation[lag], 1e-3)
                    if r > best { best = r; bestLag = lag }
                }
            }
            features.harmonicity = min(1, max(0, best))
            features.pitchHz = best > 0.4 && bestLag > 0 ? sampleRate / Float(bestLag) : 0
        }
        return features
    }
}
