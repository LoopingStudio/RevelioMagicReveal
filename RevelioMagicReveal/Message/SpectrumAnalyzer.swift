import Accelerate
import Foundation

/// Spectre de puissance par blocs (FFT vDSP, fenêtre de Hann), même recette que `BlowFeatureExtractor`.
///
/// Réutilise ses tampons : une instance par fil, utilisée par un seul fil à la fois.
nonisolated final class SpectrumAnalyzer: @unchecked Sendable {
    let sampleRate: Double
    let frameSize: Int
    private let log2n: vDSP_Length
    private let fftSetup: FFTSetup
    private var window: [Float]
    private var windowed: [Float]
    private var real: [Float]
    private var imag: [Float]
    private var power: [Float]

    init(sampleRate: Double) {
        self.sampleRate = sampleRate
        frameSize = Self.frameSize(for: sampleRate)
        log2n = vDSP_Length(frameSize.trailingZeroBitCount)
        fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
        window = [Float](repeating: 0, count: frameSize)
        vDSP_hann_window(&window, vDSP_Length(frameSize), Int32(vDSP_HANN_NORM))
        windowed = [Float](repeating: 0, count: frameSize)
        real = [Float](repeating: 0, count: frameSize / 2)
        imag = [Float](repeating: 0, count: frameSize / 2)
        power = [Float](repeating: 0, count: frameSize / 2)
    }

    deinit {
        vDSP_destroy_fftsetup(fftSetup)
    }

    /// Puissance de 2 couvrant au moins 40 ms : 2048 à 44,1 et 48 kHz, 1024 à 22 kHz (voix de synthèse).
    static func frameSize(for sampleRate: Double) -> Int {
        let target = Int((sampleRate * 0.04).rounded(.up))
        var size = 256
        while size < target { size *= 2 }
        return size
    }

    var binHz: Double { sampleRate / Double(frameSize) }

    /// Cases de chaque bande, réparties en échelle logarithmique sur `range`. Chaque bande a au moins une
    /// case : en bas du spectre, deux bandes voisines peuvent partager la même.
    static func bandBins(count: Int, range: ClosedRange<Double>, frameSize: Int, sampleRate: Double) -> [Range<Int>] {
        let binHz = sampleRate / Double(frameSize)
        let lastBin = frameSize / 2 - 1
        let upper = min(range.upperBound, Double(lastBin) * binHz)
        let ratio = upper / range.lowerBound
        return (0..<count).map { band in
            let from = range.lowerBound * pow(ratio, Double(band) / Double(count))
            let to = range.lowerBound * pow(ratio, Double(band + 1) / Double(count))
            let lo = min(lastBin, max(1, Int(from / binHz)))
            let hi = min(lastBin + 1, max(lo + 1, Int(to / binHz)))
            return lo..<hi
        }
    }

    /// Spectre de puissance (non normalisé, `frameSize / 2` cases, case 0 écartée) de `frameSize`
    /// échantillons à partir de `samples`.
    func analyze(_ samples: UnsafePointer<Float>) -> [Float] {
        let n = frameSize
        vDSP_vmul(samples, 1, window, 1, &windowed, 1, vDSP_Length(n))
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
        return power
    }
}
