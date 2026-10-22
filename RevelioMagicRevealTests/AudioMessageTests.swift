import AVFAudio
import Foundation
import Testing
@testable import RevelioMagicReveal

/// Signaux synthétiques pour l'analyse des messages vocaux.
private enum Voice {
    static func tone(_ frequency: Double, seconds: Double, amplitude: Float = 0.5, sampleRate: Double = 48_000) -> [Float] {
        (0..<Int(seconds * sampleRate)).map { amplitude * Float(sin(2 * .pi * frequency * Double($0) / sampleRate)) }
    }

    static func silence(_ seconds: Double, sampleRate: Double = 48_000) -> [Float] {
        [Float](repeating: 0, count: Int(seconds * sampleRate))
    }

    /// Salves de bruit de 150 ms aux instants donnés, sur du silence.
    static func bursts(at times: [Double], seconds: Double, sampleRate: Double = 48_000) -> [Float] {
        var samples = silence(seconds, sampleRate: sampleRate)
        var rng = SeededRandom(seed: 9)
        for time in times {
            let start = Int(time * sampleRate)
            for i in start..<min(samples.count, start + Int(0.15 * sampleRate)) {
                samples[i] = Float.random(in: -0.4...0.4, using: &rng)
            }
        }
        return samples
    }

    static func message(_ samples: [Float], sampleRate: Double = 48_000) -> AudioMessage {
        AudioMessage(samples: samples, sampleRate: sampleRate, source: .recording)
    }
}

struct AudioMessageAnalysisTests {
    @Test(arguments: [16_000.0, 22_050, 44_100, 48_000])
    func everyBandHasAtLeastOneBin(sampleRate: Double) {
        let size = SpectrumAnalyzer.frameSize(for: sampleRate)
        let bins = SpectrumAnalyzer.bandBins(count: AudioMessageAnalysis.bandCount, range: AudioMessageAnalysis.bandRange,
                                             frameSize: size, sampleRate: sampleRate)
        #expect(bins.count == AudioMessageAnalysis.bandCount)
        #expect(bins.allSatisfy { !$0.isEmpty && $0.lowerBound >= 1 && $0.upperBound <= size / 2 })
    }

    @Test func fftCoversFortyMilliseconds() {
        #expect(SpectrumAnalyzer.frameSize(for: 48_000) == 2048)
        #expect(SpectrumAnalyzer.frameSize(for: 44_100) == 2048)
        #expect(SpectrumAnalyzer.frameSize(for: 22_050) == 1024)
    }

    @Test(arguments: [250.0, 1000, 4000])
    func aToneLightsItsOwnBand(frequency: Double) throws {
        let analysis = AudioMessageAnalysis.analyze(Voice.message(Voice.tone(frequency, seconds: 1)))
        let spectrum = analysis.spectrum(at: 0.5)
        let loudest = try #require(spectrum.indices.max { spectrum[$0] < spectrum[$1] })
        let centers = AudioMessageAnalysis.bandCenters
        let nearest = try #require(centers.indices.min { abs(log(centers[$0] / frequency)) < abs(log(centers[$1] / frequency)) })
        #expect(abs(loudest - nearest) <= 1, "bande \(loudest), attendue \(nearest)")
    }

    @Test func silenceGivesNothing() {
        let analysis = AudioMessageAnalysis.analyze(Voice.message(Voice.silence(1)))
        #expect(analysis.frameCount == 100)
        #expect(analysis.level.allSatisfy { $0 == 0 })
        #expect(analysis.bands.allSatisfy { $0 == 0 })
        #expect(analysis.onsets.isEmpty)
        #expect(analysis.overview(bars: 20) == [Float](repeating: 0, count: 20))
        #expect(AudioMessageAnalysis.analyze(Voice.message([])).frameCount == 0)
    }

    @Test func burstsGiveOnsetsAtTheirStart() {
        let starts = [0.5, 1.0, 1.5, 2.0]
        let analysis = AudioMessageAnalysis.analyze(Voice.message(Voice.bursts(at: starts, seconds: 2.5)))
        #expect(analysis.onsets.count == starts.count)
        for (onset, start) in zip(analysis.onsets, starts) {
            #expect(abs(onset.time - start) < 0.04, "attaque à \(onset.time), salve à \(start)")
            #expect(onset.strength > 0 && onset.strength <= 1)
        }
    }

    @Test func levelRisesFastAndFallsSlowly() {
        let analysis = AudioMessageAnalysis.analyze(Voice.message(Voice.bursts(at: [0.5], seconds: 1.5)))
        #expect(analysis.level(at: 0.4) == 0)
        #expect(analysis.level(at: 0.6) > 0.8)
        // 50 ms après la fin de la salve : encore là (retombée lente) ; 600 ms après : éteint.
        #expect(analysis.level(at: 0.7) > 0.4)
        #expect(analysis.level(at: 1.25) < 0.05)
        #expect(analysis.cumulative(at: 1.4) > analysis.cumulative(at: 0.4))
    }

    @Test func overviewIsNormalized() throws {
        let samples = Voice.tone(300, seconds: 0.5, amplitude: 0.1) + Voice.tone(300, seconds: 0.5, amplitude: 0.8)
        let bars = AudioMessageAnalysis.analyze(Voice.message(samples)).overview(bars: 30)
        #expect(bars.count == 30)
        #expect(try #require(bars.max()) == 1)
        #expect(bars.allSatisfy { (0...1).contains($0) })
        #expect(bars[5] < bars[25])
    }

    @Test func scopeSamplesAverageAroundTheTime() {
        let message = Voice.message(Voice.silence(0.5) + [Float](repeating: 0.6, count: 24_000))
        #expect(message.average(at: 0.2, window: 0.001) == 0)
        #expect(abs(message.average(at: 0.8, window: 0.001) - 0.6) < 1e-6)
        // À cheval sur la marche : la moitié de la fenêtre dans le silence.
        #expect(abs(message.average(at: 0.5, window: 0.002) - 0.3) < 0.02)
        #expect(message.average(at: 2, window: 0.001) == 0)
    }

    @Test func scopeLocksOnARisingZeroCrossing() {
        let sampleRate = 48_000.0
        let message = Voice.message(Voice.tone(100, seconds: 0.5, amplitude: 0.5))
        // Le sinus monte en passant par zéro toutes les 10 ms.
        for time in [0.1234, 0.2051, 0.3399] {
            let locked = message.risingZeroCrossing(before: time, within: 0.012)
            #expect(locked <= time && time - locked < 0.0101)
            let index = Int((locked * sampleRate).rounded())
            #expect(message.samples[index - 1] < 0 && message.samples[index] >= 0)
        }
    }
}

struct VoiceCleanupTests {
    @Test func silencesAreTrimmedWithMargins() {
        let sampleRate = 48_000.0
        let samples = Voice.silence(1) + Voice.tone(440, seconds: 0.5) + Voice.silence(1)
        let cleaned = VoiceCleanup.process(samples, sampleRate: sampleRate)
        let seconds = Double(cleaned.count) / sampleRate
        #expect(abs(seconds - (0.5 + 2 * VoiceCleanup.margin)) < 0.03, "\(seconds) s")
    }

    @Test func loudVoiceIsBroughtToTheTargetPeak() {
        let cleaned = VoiceCleanup.normalize(Voice.tone(440, seconds: 0.3, amplitude: 0.3))
        #expect(abs((cleaned.map(abs).max() ?? 0) - VoiceCleanup.targetPeak) < 0.001)
    }

    @Test func gainIsCapped() {
        let cleaned = VoiceCleanup.normalize(Voice.tone(440, seconds: 0.3, amplitude: 0.001))
        let peak = cleaned.map(abs).max() ?? 0
        #expect(abs(peak - 0.001 * VoiceCleanup.maxGain) < 0.0005)
    }

    @Test func highPassRemovesTheRumble() {
        let sampleRate = 48_000.0
        let rumble = VoiceCleanup.highPass(Voice.tone(20, seconds: 1, amplitude: 0.5), cutoff: 80, sampleRate: sampleRate)
        let voice = VoiceCleanup.highPass(Voice.tone(1000, seconds: 1, amplitude: 0.5), cutoff: 80, sampleRate: sampleRate)
        // Hors du régime transitoire du début.
        #expect((rumble[24_000...].map(abs).max() ?? 1) < 0.05)
        #expect((voice[24_000...].map(abs).max() ?? 0) > 0.48)
    }
}

struct SpeechSampleTests {
    @Test func int16BuffersAreScaledToFloats() throws {
        let format = try #require(AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 22_050, channels: 1, interleaved: false))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 3))
        buffer.frameLength = 3
        let data = try #require(buffer.int16ChannelData)
        data[0][0] = 16_384
        data[0][1] = -32_768
        data[0][2] = 0
        #expect(SpeechSample.floats(from: buffer) == [0.5, -1, 0])
    }

    @Test func float32BuffersPassThrough() throws {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 22_050, channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 2))
        buffer.frameLength = 2
        let data = try #require(buffer.floatChannelData)
        data[0][0] = 0.25
        data[0][1] = -0.75
        #expect(SpeechSample.floats(from: buffer) == [0.25, -0.75])
    }
}

struct VoiceHapticsTests {
    @Test func voiceScriptIsSortedSpacedAndCapped() {
        let analysis = AudioMessageAnalysis.analyze(Voice.message(Voice.bursts(at: [0.3, 0.6, 0.9, 1.2], seconds: 1.6)))
        let events = HapticScripts.voice(analysis)
        #expect(!events.isEmpty)
        #expect(events.map(\.time) == events.map(\.time).sorted())
        let taps = events.filter { $0.kind == .transient }
        #expect(taps.count == 4)
        #expect(zip(taps.dropFirst(), taps).allSatisfy { $0.time - $1.time >= 0.08 })
        #expect(taps.allSatisfy { $0.intensity <= HapticScripts.voiceTapMax + 1e-6 })
        #expect(events.filter { $0.kind != .transient }.allSatisfy { $0.intensity <= HapticScripts.voiceLayerMax })
        #expect(events.allSatisfy { $0.end <= analysis.duration + 0.05 })
    }

    @Test func sliceShiftsAndClipsAtTheOffset() {
        let events = [
            HapticEventSpec(kind: .continuous(duration: 0.2), time: 0.9, intensity: 0.4, sharpness: 0.2),
            HapticEventSpec(kind: .transient, time: 0.95, intensity: 0.6, sharpness: 0.4),
            HapticEventSpec(kind: .continuous(duration: 0.05), time: 0.92, intensity: 0.3, sharpness: 0.2),
            HapticEventSpec(kind: .transient, time: 1.2, intensity: 0.6, sharpness: 0.4),
            HapticEventSpec(kind: .continuous(duration: 0.03), time: 1.5, intensity: 0.5, sharpness: 0.1),
        ]
        let sliced = HapticScripts.slice(events, from: 1.0)
        #expect(sliced.count == 3)
        // Nappe à cheval : coupée à l'instant de reprise, il lui reste 0,1 s.
        #expect(sliced[0].time == 0)
        if case .continuous(let duration) = sliced[0].kind {
            #expect(abs(duration - 0.1) < 1e-9)
        } else {
            Issue.record("la nappe à cheval devrait rester continue")
        }
        #expect(abs(sliced[1].time - 0.2) < 1e-9)
        #expect(abs(sliced[2].time - 0.5) < 1e-9)
        #expect(HapticScripts.slice(events, from: 0) == events)
    }
}
