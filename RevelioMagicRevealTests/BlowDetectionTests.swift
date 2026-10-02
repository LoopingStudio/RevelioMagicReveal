import AVFoundation
import Foundation
import Testing
@testable import RevelioMagicReveal

/// Signaux de synthèse qui imitent un souffle sur le micro, une voyelle et une sifflante.
private enum Signal {
    static let sampleRate: Float = 48_000
    static let frame = 2048

    static func whiteNoise(amplitude: Float, count: Int = frame, seed: UInt32 = 1) -> [Float] {
        var rng = SeededRandom(seed: seed)
        return (0..<count).map { _ in Float.random(in: -1...1, using: &rng) * amplitude }
    }

    /// Bruit de vent : bruit blanc fortement filtré passe-bas (~150 Hz), comme l'air sur la membrane.
    static func wind(amplitude: Float, count: Int = frame, seed: UInt32 = 2) -> [Float] {
        let noise = whiteNoise(amplitude: 1, count: count + 2000, seed: seed)
        let a = exp(-2 * Float.pi * 150 / sampleRate)
        var y: Float = 0
        var out: [Float] = []
        out.reserveCapacity(noise.count)
        for x in noise {
            y = a * y + (1 - a) * x
            out.append(y)
        }
        let tail = Array(out.suffix(count))
        let peak = tail.map(abs).max() ?? 1
        return tail.map { $0 / peak * amplitude }
    }

    /// Voyelle : fondamentale `f0` et ses harmoniques décroissantes.
    static func vowel(f0: Float, amplitude: Float, count: Int = frame) -> [Float] {
        (0..<count).map { i in
            let t = Float(i) / sampleRate
            var v: Float = 0
            for h in 1...12 { v += sin(2 * .pi * f0 * Float(h) * t) / Float(h) }
            return v * amplitude * 0.35
        }
    }

    /// Sifflante « sss » : bruit blanc passe-haut (> 4 kHz environ).
    static func hiss(amplitude: Float, count: Int = frame) -> [Float] {
        let noise = whiteNoise(amplitude: 1, count: count + 1, seed: 9)
        var out: [Float] = []
        for i in 1..<noise.count {
            // Différence d'ordre 3 : coupe fortement les graves et les médiums.
            let prev2 = i >= 2 ? noise[i - 2] : 0
            let prev3 = i >= 3 ? noise[i - 3] : 0
            out.append((noise[i] - 3 * noise[i - 1] + 3 * prev2 - prev3) * amplitude * 0.15)
        }
        return Array(out.prefix(count))
    }

    static func features(_ samples: [Float]) -> BlowFeatures {
        let extractor = BlowFeatureExtractor(frameSize: frame, sampleRate: sampleRate)
        return samples.withUnsafeBufferPointer { extractor.analyze($0) }
    }
}

struct BlowFeatureTests {
    @Test func levelMatchesTheSignal() {
        let f = Signal.features(Signal.vowel(f0: 200, amplitude: 0.5))
        #expect(f.levelDB > -20 && f.levelDB < -3)
        let silence = Signal.features([Float](repeating: 0, count: Signal.frame))
        #expect(silence.levelDB < -100)
    }

    @Test func vowelIsHarmonicWithItsPitch() {
        let f = Signal.features(Signal.vowel(f0: 150, amplitude: 0.5))
        #expect(f.harmonicity > 0.7)
        #expect(abs(f.pitchHz - 150) < 12)
        #expect(f.flatness < 0.2)
    }

    @Test func windIsNotHarmonicButFullOfLows() {
        let f = Signal.features(Signal.wind(amplitude: 0.6))
        #expect(f.harmonicity < 0.5, "harmonicité \(f.harmonicity)")
        #expect(f.lowRatio > 0.5, "graves \(f.lowRatio)")
        #expect(f.highRatio < 0.1)
    }

    @Test func whiteNoiseIsFlatAndNotHarmonic() {
        let f = Signal.features(Signal.whiteNoise(amplitude: 0.3))
        #expect(f.flatness > 0.5)
        #expect(f.harmonicity < 0.35)
    }

    @Test func hissIsMostlyHigh() {
        let f = Signal.features(Signal.hiss(amplitude: 0.5))
        #expect(f.highRatio > 0.5, "aigus \(f.highRatio)")
        #expect(f.lowRatio < 0.05)
    }
}

struct BlowClassifierTests {
    let classifier = BlowClassifier()

    @Test func loudWindIsABlow() {
        #expect(classifier.isBlowLike(Signal.features(Signal.wind(amplitude: 0.6)), thresholdDB: -30))
    }

    @Test func voiceAndHissAreNot() {
        #expect(!classifier.isBlowLike(Signal.features(Signal.vowel(f0: 120, amplitude: 0.6)), thresholdDB: -30))
        #expect(!classifier.isBlowLike(Signal.features(Signal.vowel(f0: 260, amplitude: 0.6)), thresholdDB: -30))
        #expect(!classifier.isBlowLike(Signal.features(Signal.hiss(amplitude: 0.6)), thresholdDB: -30))
    }

    @Test func quietWindIsBelowThreshold() {
        #expect(!classifier.isBlowLike(Signal.features(Signal.wind(amplitude: 0.003)), thresholdDB: -30))
    }

    @Test func gateNeedsASustainedBlow() {
        var gate = BlowGate()
        let blow = Signal.features(Signal.wind(amplitude: 0.6))
        let voice = Signal.features(Signal.vowel(f0: 150, amplitude: 0.6))
        let dt = Float(Signal.frame) / Signal.sampleRate   // ≈ 43 ms
        // Deux blocs (~85 ms) : trop court, c'est peut-être une plosive.
        let first = gate.process(blow, thresholdDB: -30, dt: dt)
        let second = gate.process(blow, thresholdDB: -30, dt: dt)
        #expect(!first && !second)
        // Un troisième (~130 ms) : souffle soutenu.
        let third = gate.process(blow, thresholdDB: -30, dt: dt)
        #expect(third)
        // Quatre blocs de voix (~170 ms) referment la porte.
        for _ in 0..<4 { _ = gate.process(voice, thresholdDB: -30, dt: dt) }
        #expect(!gate.isOpen)
    }
}

@MainActor
struct SignatureModeEngineTests {
    private func makeEngine(signature: Bool) -> RevealEngine {
        let settings = RevealSettings(defaults: UserDefaults(suiteName: "SignatureModeEngineTests-\(UUID().uuidString)")!)
        settings.blowSignature = signature
        settings.blowThresholdDB = -30
        settings.autoFinishThreshold = 1
        let engine = RevealEngine(settings: settings, feedback: FeedbackCenter(), mask: .snow, gesture: .blow)
        engine.cardSize = CGSize(width: 300, height: 400)
        return engine
    }

    @Test func talkingDoesNotRevealInSignatureMode() {
        let engine = makeEngine(signature: true)
        let voice = Signal.features(Signal.vowel(f0: 140, amplitude: 0.6))
        for _ in 0..<30 { engine.microphoneFrame(voice, dt: 0.043); engine.tick(dt: 0.043) }
        #expect(engine.blowStrength == 0)
        #expect(engine.revealed == 0)
    }

    @Test func blowingRevealsInSignatureMode() {
        let engine = makeEngine(signature: true)
        let blow = Signal.features(Signal.wind(amplitude: 0.6))
        for _ in 0..<30 { engine.microphoneFrame(blow, dt: 0.043); engine.tick(dt: 0.043) }
        #expect(engine.blowGateOpen)
        #expect(engine.blowStrength > 0.5)
        #expect(engine.revealed > 0.05)
    }

    @Test func levelModeStillReactsToAnyLoudSound() {
        let engine = makeEngine(signature: false)
        let voice = Signal.features(Signal.vowel(f0: 140, amplitude: 0.6))
        for _ in 0..<10 { engine.microphoneFrame(voice, dt: 0.043) }
        #expect(engine.blowStrength > 0.3)
    }
}

struct BlowRecorderTests {
    @Test func takeIsWrittenAsWavAndCsv() async throws {
        let written: URL? = await withCheckedContinuation { continuation in
            let recorder = BlowRecorder { url in continuation.resume(returning: url) }
            recorder.start(BlowRecorder.Context(label: .autre, seconds: 0.2, micSource: "test",
                                                thresholdDB: -30, classifier: BlowClassifier()),
                           sampleRate: Double(Signal.sampleRate))
            let block = Signal.wind(amplitude: 0.5)
            let features = Signal.features(block)
            for _ in 0..<6 {
                block.withUnsafeBufferPointer { recorder.append($0, features: features) }
            }
        }
        let wav = try #require(written)
        defer {
            try? FileManager.default.removeItem(at: wav)
            try? FileManager.default.removeItem(at: wav.deletingPathExtension().appendingPathExtension("csv"))
        }
        let file = try AVAudioFile(forReading: wav)
        #expect(file.fileFormat.sampleRate == Double(Signal.sampleRate))
        // 0,2 s arrondi au bloc supérieur : 5 blocs de 2048.
        #expect(file.length == AVAudioFramePosition(5 * Signal.frame))
        let csv = try String(contentsOf: wav.deletingPathExtension().appendingPathExtension("csv"), encoding: .utf8)
        let lines = csv.split(separator: "\n")
        #expect(lines.count == 3 + 5)
        #expect(lines[2].hasPrefix("t,levelDB,flatness"))
        #expect(wav.lastPathComponent.hasPrefix("autre_"))
    }
}
