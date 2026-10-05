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

    /// Bruit de vent : bruit blanc filtré par deux passe-bas en cascade (170 Hz, −12 dB/octave), comme
    /// l'air sur la membrane. Calé sur les prises réelles : harmonicité ~0,3-0,5, centre ~110-130 Hz,
    /// graves ~95 % (plus de filtrage rend le bruit presque périodique, donc « harmonique »).
    static func wind(amplitude: Float, count: Int = frame, seed: UInt32 = 2) -> [Float] {
        var out = whiteNoise(amplitude: 1, count: count + 4000, seed: seed)
        let a = exp(-2 * Float.pi * 170 / sampleRate)
        for _ in 0..<2 {
            var y: Float = 0
            for i in out.indices {
                y = a * y + (1 - a) * out[i]
                out[i] = y
            }
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
        #expect(f.lowRatio > 0.75, "graves \(f.lowRatio)")
        #expect(f.centroidHz < 200, "centre \(f.centroidHz)")
        #expect(f.highRatio < 0.05)
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

    /// Souffle collé au micro : on amplifie puis on écrête, comme un micro qui sature.
    private func saturated(_ samples: [Float], gain: Float) -> BlowFeatures {
        Signal.features(samples.map { max(-1, min(1, $0 * gain)) })
    }

    @Test func saturatedBlowStraightIntoTheMicIsStillABlow() {
        let f = saturated(Signal.wind(amplitude: 1), gain: 4)
        #expect(f.clipRatio > 0.05)
        #expect(classifier.isBlowLike(f, thresholdDB: -45))
    }

    @Test func voiceShoutedIntoTheMicIsNotABlowEvenSaturated() {
        for f0: Float in [120, 220] {
            let f = saturated(Signal.vowel(f0: f0, amplitude: 1), gain: 4)
            #expect(f.clipRatio > 0.05)
            #expect(!classifier.isBlowLike(f, thresholdDB: -45), "voix \(f0) Hz")
        }
    }

    @Test func directPathOnlyAppliesToVeryLoudSounds() {
        // Spectre trop haut pour un souffle normal (centre 300 Hz), mais plausible pour un souffle saturé.
        var f = BlowFeatures()
        f.levelDB = -12
        f.harmonicity = 0.5
        f.lowRatio = 0.7
        f.highRatio = 0.08
        f.centroidHz = 300
        #expect(!classifier.isNormalBlow(f, thresholdDB: -45))
        #expect(classifier.isDirectBlow(f))
        f.levelDB = -30
        #expect(!classifier.isBlowLike(f, thresholdDB: -45))
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
        // Une pointe isolée pendant le souffle ne referme pas la porte…
        _ = gate.process(voice, thresholdDB: -30, dt: dt)
        #expect(gate.isOpen)
        // … mais cinq blocs de voix (~210 ms) la referment.
        for _ in 0..<5 { _ = gate.process(voice, thresholdDB: -30, dt: dt) }
        #expect(!gate.isOpen)
    }

    @Test func scatteredBlowLikeBlocksDoNotAddUp() {
        // Cas réel (prise « voix » du 2026-10-02) : fins de mots graves dispersées entre des syllabes.
        var gate = BlowGate()
        let blow = Signal.features(Signal.wind(amplitude: 0.6))
        let voice = Signal.features(Signal.vowel(f0: 150, amplitude: 0.6))
        let dt = Float(Signal.frame) / Signal.sampleRate
        for frame in [blow, blow, voice, voice, voice, blow, voice, blow, blow, voice] {
            _ = gate.process(frame, thresholdDB: -30, dt: dt)
            #expect(!gate.isOpen)
        }
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
        #expect(lines.count == 5 + 5)
        #expect(lines[4].hasPrefix("t,levelDB,flatness"))
        #expect(wav.lastPathComponent.hasPrefix("autre_"))
    }
}

/// Prises réelles (iPhone, micro du bas, 2026-10-02) : seules les mesures sont gardées, pas l'audio.
/// `voix-2` contient des fins de mots graves qui ouvraient la porte avant l'hystérésis.
private final class FixtureToken {}

struct RecordedTakesTests {
    private func openTime(_ name: String) throws -> Float {
        let url = try #require(Bundle(for: FixtureToken.self).url(forResource: name, withExtension: "csv"))
        let lines = try String(contentsOf: url, encoding: .utf8)
            .split(separator: "\n")
            .filter { !$0.hasPrefix("#") }
        let header = lines[0].split(separator: ",").map(String.init)
        var gate = BlowGate()
        var open: Float = 0
        let dt: Float = 2048.0 / 48_000
        for line in lines.dropFirst() {
            let values = Dictionary(uniqueKeysWithValues: zip(header, line.split(separator: ",").map { Float($0) ?? 0 }))
            var f = BlowFeatures()
            f.levelDB = values["levelDB"]!
            f.flatness = values["flatness"]!
            f.harmonicity = values["harmonicity"]!
            f.lowRatio = values["lowRatio"]!
            f.highRatio = values["highRatio"]!
            f.centroidHz = values["centroidHz"]!
            if gate.process(f, thresholdDB: -45, dt: dt) { open += dt }
        }
        return open
    }

    @Test(arguments: ["souffle-1", "souffle-2", "souffle-3"])
    func realBlowsAreRecognized(_ take: String) throws {
        // Chaque prise contient ~2 s de souffle effectif.
        #expect(try openTime(take) > 1.5)
    }

    @Test(arguments: ["voix-1", "voix-2", "autre-1", "autre-2"])
    func realVoiceAndNoiseAreIgnored(_ take: String) throws {
        #expect(try openTime(take) == 0)
    }
}

struct StereoBlowTests {
    let wind = Signal.features(Signal.wind(amplitude: 0.6))
    let voice = Signal.features(Signal.vowel(f0: 120, amplitude: 0.6))
    let quietVoice = Signal.features(Signal.vowel(f0: 120, amplitude: 0.05))

    @Test func chooserFollowsTheChannelThatBlows() {
        // On souffle vers le haut pendant que le micro du bas entend surtout la voix.
        #expect(BlowChannelChooser.choose([voice, wind], classifier: BlowClassifier(), thresholdDB: -48) == 1)
        #expect(BlowChannelChooser.choose([wind, voice], classifier: BlowClassifier(), thresholdDB: -48) == 0)
    }

    @Test func withoutABlowTheLouderChannelIsShown() {
        #expect(BlowChannelChooser.choose([quietVoice, voice], classifier: BlowClassifier(), thresholdDB: -48) == 1)
    }

    @MainActor
    @Test func engineRevealsWhenEitherMicrophoneHearsABlow() {
        let settings = RevealSettings(defaults: UserDefaults(suiteName: "StereoBlowTests-\(UUID().uuidString)")!)
        settings.autoFinishThreshold = 1
        let engine = RevealEngine(settings: settings, feedback: FeedbackCenter(), mask: .snow, gesture: .blow)
        engine.cardSize = CGSize(width: 300, height: 400)
        for _ in 0..<20 { engine.microphoneFrame([voice, voice], dt: 0.043); engine.tick(dt: 0.043) }
        #expect(engine.revealed == 0)
        for _ in 0..<20 { engine.microphoneFrame([voice, wind], dt: 0.043); engine.tick(dt: 0.043) }
        #expect(engine.blowChannel == 1)
        #expect(engine.revealed > 0.02)
    }

    @Test func stereoTakeKeepsBothChannels() async throws {
        let written: URL? = await withCheckedContinuation { continuation in
            let recorder = BlowRecorder { url in continuation.resume(returning: url) }
            recorder.start(BlowRecorder.Context(label: .souffle, seconds: 0.1, micSource: "test",
                                                thresholdDB: -48, classifier: BlowClassifier()),
                           sampleRate: Double(Signal.sampleRate))
            let bottom = Signal.vowel(f0: 120, amplitude: 0.5), top = Signal.wind(amplitude: 0.5)
            for _ in 0..<3 {
                recorder.append([bottom, top], features: [Signal.features(bottom), Signal.features(top)])
            }
        }
        let wav = try #require(written)
        let csvURL = wav.deletingPathExtension().appendingPathExtension("csv")
        defer {
            try? FileManager.default.removeItem(at: wav)
            try? FileManager.default.removeItem(at: csvURL)
        }
        let file = try AVAudioFile(forReading: wav)
        #expect(file.fileFormat.channelCount == 2)
        let csv = try String(contentsOf: csvURL, encoding: .utf8)
        #expect(csv.contains("levelDB_c1"))
        // Colonne « canal » : le canal 1 (vent) est suivi.
        let firstRow = try #require(csv.split(separator: "\n").first { $0.hasPrefix("0.000,") })
        // t + 10 mesures + blowLike + gateOpen → « canal » est la 14ᵉ colonne.
        #expect(firstRow.split(separator: ",")[13] == "1")
    }
}
