import Foundation
import Testing
@testable import RevelioMagicReveal

struct HeartbeatAnalyzerTests {
    /// Battements synthétiques : « boum » grave (60 Hz, 80 ms) puis « boum » plus faible 0,16 s après,
    /// sur un léger bruit de fond.
    private func syntheticHeartbeat(bpm: Double, seconds: Double, sampleRate: Double = 44_100) -> [Float] {
        var samples = [Float](repeating: 0, count: Int(seconds * sampleRate))
        var rng = SeededRandom(seed: 4)
        for i in samples.indices { samples[i] = Float.random(in: -0.01...0.01, using: &rng) }
        let period = 60 / bpm
        func thump(at time: Double, amplitude: Float) {
            let start = Int(time * sampleRate), length = Int(0.08 * sampleRate)
            for n in 0..<length where start + n < samples.count {
                let t = Double(n) / sampleRate
                samples[start + n] += amplitude * Float(sin(2 * .pi * 60 * t) * exp(-t / 0.025))
            }
        }
        var time = 0.2
        while time < seconds - 0.3 {
            thump(at: time, amplitude: 0.8)
            thump(at: time + 0.16, amplitude: 0.45)
            time += period
        }
        return samples
    }

    @Test func findsTheHeartRateAndOneBeatPerCycle() {
        let analysis = HeartbeatAnalyzer.analyze(samples: syntheticHeartbeat(bpm: 120, seconds: 10), sampleRate: 44_100)
        #expect(abs(analysis.bpm - 120) < 6, "bpm \(analysis.bpm)")
        // ~19 cycles entre 0,2 s et 9,7 s.
        #expect((18...20).contains(analysis.beats.count), "\(analysis.beats.count) coups")
        let gaps = zip(analysis.beats.dropFirst(), analysis.beats).map { $0.time - $1.time }
        #expect(gaps.allSatisfy { abs($0 - 0.5) < 0.06 }, "écarts \(gaps)")
    }

    @Test func silenceGivesNoBeats() {
        let analysis = HeartbeatAnalyzer.analyze(samples: [Float](repeating: 0, count: 44_100), sampleRate: 44_100)
        #expect(analysis.beats.isEmpty)
    }

    /// Le vrai bruitage d'échographie embarqué : l'analyse, faite par l'app, doit trouver un cœur
    /// d'environ 111 battements/min et un coup régulier par cycle.
    @Test func bundledEchographySound() throws {
        let url = try #require(Bundle.main.url(forResource: "coeur-echographie", withExtension: "mp3"))
        let analysis = try HeartbeatAnalyzer.analyze(fileAt: url)
        #expect(abs(analysis.bpm - 111) < 8, "bpm \(analysis.bpm)")
        #expect((32...40).contains(analysis.beats.count), "\(analysis.beats.count) coups")
        let gaps = zip(analysis.beats.dropFirst(), analysis.beats).map { $0.time - $1.time }
        #expect(gaps.allSatisfy { $0 > 0.4 && $0 < 0.7 }, "écarts \(gaps)")
    }

    @Test func hapticsFollowTheAnalysis() {
        let analysis = HeartbeatAnalyzer.analyze(samples: syntheticHeartbeat(bpm: 120, seconds: 5), sampleRate: 44_100)
        let events = HapticScripts.audioDriven(analysis)
        let thumps = events.filter { $0.kind == .transient }
        #expect(thumps.count == analysis.beats.count)
        for (thump, beat) in zip(thumps, analysis.beats) {
            #expect(abs(thump.time - beat.time) < 1e-9)
            #expect(thump.sharpness < 0.3)   // un « boum » sourd, pas un clic
        }
        // La nappe existe (le second battement est porté par elle) et reste plus douce que les coups.
        let layer = events.filter { if case .continuous(let d) = $0.kind { return d == 0.04 } else { return false } }
        #expect(!layer.isEmpty)
        #expect(layer.allSatisfy { $0.intensity <= 0.45 })
        #expect(events.map(\.time) == events.map(\.time).sorted())
    }
}
