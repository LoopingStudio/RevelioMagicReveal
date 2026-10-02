import Foundation
import Testing
@testable import RevelioNoel

struct FeedbackCurvesTests {
    private let speeds: [Float] = stride(from: 0, through: 1, by: 0.05).map { Float($0) }

    @Test func nothingWhileTheFingerRests() {
        #expect(FeedbackCurves.scratchHapticIntensity(speed: 0, material: 1) == 0)
        #expect(FeedbackCurves.scratchGain(speed: 0, material: 1) == 0)
        #expect(FeedbackCurves.scratchHapticIntensity(speed: FeedbackCurves.restSpeed, material: 1) == 0)
    }

    @Test func scratchFeedbackGrowsWithSpeedAndStaysInRange() {
        for material in [Float(0), 0.5, 1] {
            var lastIntensity: Float = 0, lastGain: Float = 0
            for speed in speeds {
                let intensity = FeedbackCurves.scratchHapticIntensity(speed: speed, material: material)
                let gain = FeedbackCurves.scratchGain(speed: speed, material: material)
                #expect(intensity >= lastIntensity && intensity <= 1, "intensité à v = \(speed)")
                #expect(gain >= lastGain && gain <= 1, "gain à v = \(speed)")
                lastIntensity = intensity
                lastGain = gain
            }
        }
        // Au-delà de 1 (doigt très rapide), on plafonne.
        #expect(FeedbackCurves.scratchHapticIntensity(speed: 3, material: 1) == FeedbackCurves.scratchHapticIntensity(speed: 1, material: 1))
    }

    @Test func erodingMaterialBitesHarderThanRubbingThePhoto() {
        let onMask = FeedbackCurves.scratchHapticIntensity(speed: 0.5, material: 1)
        let onPhoto = FeedbackCurves.scratchHapticIntensity(speed: 0.5, material: 0)
        #expect(onPhoto > 0)
        #expect(onMask > onPhoto * 2)
        #expect(FeedbackCurves.scratchGain(speed: 0.5, material: 1) > FeedbackCurves.scratchGain(speed: 0.5, material: 0) * 4)
    }

    @Test func fasterIsSharperAndBrighter() {
        #expect(FeedbackCurves.scratchHapticSharpness(speed: 1, base: -0.1, slope: 0.3) > FeedbackCurves.scratchHapticSharpness(speed: 0.1, base: -0.1, slope: 0.3))
        #expect(FeedbackCurves.scratchHapticSharpness(speed: 1, base: 0.9, slope: 0.5) <= 1)
        #expect(FeedbackCurves.scratchBrightness(speed: 1) > FeedbackCurves.scratchBrightness(speed: 0.2))
    }

    @Test func rumbleFollowsTheBreathAndStaysSoft() {
        #expect(FeedbackCurves.rumbleIntensity(strength: 0) == 0)
        #expect(FeedbackCurves.rumbleIntensity(strength: 0.02) == 0)
        var last: Float = 0
        for strength in speeds.dropFirst() where strength > 0.03 {
            let rumble = FeedbackCurves.rumbleIntensity(strength: strength)
            #expect(rumble >= last)
            #expect(rumble <= FeedbackCurves.rumbleCeiling)
            last = rumble
        }
        #expect(last == FeedbackCurves.rumbleCeiling)
    }

    @Test func impulsesScaleWithWhatFalls() {
        #expect(FeedbackCurves.chunkIntensity(amount: 400) > FeedbackCurves.chunkIntensity(amount: 50))
        #expect(FeedbackCurves.chunkIntensity(amount: 10_000) <= 1)
        #expect(FeedbackCurves.shakeIntensity(strength: 1) > FeedbackCurves.shakeIntensity(strength: 0.3))
        #expect(FeedbackCurves.whooshAmplitude(amount: 10_000) <= 1)
    }
}

struct FeedbackGatingTests {
    @Test func materialRisesWithErosionAndFadesWithout() {
        var tracker = MaterialTracker()
        for _ in 0..<12 { tracker.update(erodedAmount: 20, dt: 1.0 / 120) }
        #expect(tracker.value > 0.9)
        for _ in 0..<120 { tracker.update(erodedAmount: 0, dt: 1.0 / 120) }
        #expect(tracker.value < 0.01)
    }

    @Test func gateWaitsForTheThresholdAndRespectsTheCadence() {
        var gate = ImpulseGate(threshold: 10, minInterval: 0.05)
        let below = gate.add(6, at: 0)
        let reached = gate.add(6, at: 0.01)
        // Assez de matière, mais trop tôt.
        let tooSoon = gate.add(30, at: 0.03)
        let stillTooSoon = gate.add(30, at: 0.04)
        // L'arriéré est plafonné à 4 seuils.
        let capped = gate.add(0, at: 0.07)
        #expect(below == nil)
        #expect(reached == 12)
        #expect(tooSoon == nil && stillTooSoon == nil)
        #expect(capped == 40)
        gate.reset()
        #expect(gate.accumulated == 0)
        let afterReset = gate.add(10, at: 0.071)
        #expect(afterReset == 10)
    }

    @Test func throttleLimitsTheRateButNeverDelaysSilence() {
        var throttle = ParameterThrottle(minInterval: 1.0 / 60)
        let decisions = [
            throttle.shouldSend(SIMD2(0.5, 0), at: 0),
            throttle.shouldSend(SIMD2(0.6, 0), at: 0.005), // trop tôt
            throttle.shouldSend(SIMD2(0.6, 0), at: 0.02),
            throttle.shouldSend(SIMD2(0.6, 0), at: 0.05), // valeur inchangée
            throttle.shouldSend(SIMD2(0, 0), at: 0.051), // le silence part tout de suite
        ]
        #expect(decisions == [true, false, true, false, true])
    }
}

struct HapticDesignTests {
    private func grains(_ timbre: FeedbackTimbre) -> [HapticEventSpec] {
        MaskFeel.of(timbre).texture.events().filter { $0.kind == .transient }
    }

    @Test func texturesAreWellFormedLoops() {
        for timbre in FeedbackTimbre.allCases {
            let texture = MaskFeel.of(timbre).texture
            let events = texture.events()
            #expect(events.first?.kind == .continuous(duration: texture.loopDuration))
            #expect(events.allSatisfy { $0.time >= 0 && $0.end <= texture.loopDuration })
            #expect(events.allSatisfy { (0...1).contains($0.intensity) && (0...1).contains($0.sharpness) })
            let times = events.dropFirst().map(\.time)
            #expect(times == times.sorted(), "\(timbre)")
            #expect(texture.events() == events, "motif déterministe")
        }
    }

    @Test func goldIsGrittierAndCrisperThanSnow() {
        let gold = grains(.gold), snow = grains(.snow)
        #expect(gold.count > snow.count * 2)
        let meanSharpness = { (events: [HapticEventSpec]) in events.map(\.sharpness).reduce(0, +) / Float(events.count) }
        #expect(meanSharpness(gold) > meanSharpness(snow) + 0.5)
        #expect(MaskFeel.of(.snow).texture.bodySharpness < 0.2)
    }

    @Test func paperCrinklesInClustersAndFrostCracks() {
        let paper = grains(.paper).map(\.time)
        let gaps = zip(paper.dropFirst(), paper).map { $0 - $1 }
        #expect(gaps.contains { $0 < 0.03 }, "grains serrés d'une même grappe")
        #expect(gaps.contains { $0 > 0.04 }, "silences entre grappes")
        #expect(MaskFeel.of(.paper).crinkle != nil)
        #expect(grains(.frost).contains { $0.intensity >= 0.85 && $0.sharpness == 1 }, "craquements")
    }

    @Test func celebrationRisesThenSparkles() {
        let events = HapticScripts.celebration()
        #expect(events.map(\.time) == events.map(\.time).sorted())
        #expect(events.allSatisfy { (0...1).contains($0.intensity) && (0...1).contains($0.sharpness) })
        let onsets = CelebrationScore.onsets(of: CelebrationScore.notes)
        let arpeggio = events.filter { $0.kind == .transient && onsets.dropLast().contains($0.time) }
        #expect(arpeggio.count == onsets.count - 1)
        #expect(zip(arpeggio.dropFirst(), arpeggio).allSatisfy { $0.intensity > $1.intensity && $0.sharpness > $1.sharpness })
        #expect(events.contains { $0.time == onsets.last && $0.intensity == 1 }, "accord final au maximum")
        #expect((events.last?.time ?? 0) > (onsets.last ?? 0), "scintillements après l'accord")
    }
}

struct ChimeTests {
    private func rms(_ samples: ArraySlice<Float>) -> Float {
        (samples.reduce(0) { $0 + $1 * $1 } / Float(samples.count)).squareRoot()
    }

    @Test func chimeIsAudibleBoundedAndDecays() {
        let chime = ChimeSynth.render()
        let rate = chime.sampleRate
        #expect(chime.frameCount == Int(ChimeSynth.duration * rate))
        #expect(chime.right.count == chime.frameCount)
        let all = chime.left + chime.right
        #expect(all.allSatisfy { $0.isFinite })
        let peak = all.map(abs).max() ?? 0
        #expect(peak > 0.5 && peak <= 1)
        let early = rms(chime.left[Int(0.5 * rate)..<Int(0.8 * rate)])
        let late = rms(chime.left[Int(2.1 * rate)..<Int(2.4 * rate)])
        #expect(early > 0.05)
        #expect(late < early * 0.25)
        #expect(abs(chime.left.last ?? 1) < 1e-4 && abs(chime.right.last ?? 1) < 1e-4, "fin sans clic")
    }

    @Test func eachNoteStartsWhereTheScoreSaysAndStereoIsUsed() {
        let chime = ChimeSynth.render()
        let rate = chime.sampleRate
        let first = CelebrationScore.notes[0]
        #expect(rms(chime.left[0..<Int(first.time * rate + 0.03 * rate)]) > 0.01)
        // Arpège panoramiqué de gauche à droite : les deux canaux diffèrent.
        #expect(zip(chime.left, chime.right).contains { abs($0 - $1) > 0.01 })
    }
}

struct SynthTests {
    private let rate: Float = 48_000

    private func render(_ renderer: SynthRenderer, frames: Int) -> (samples: [Float], silent: Bool) {
        var out = [Float](repeating: 1, count: frames)
        let silent = out.withUnsafeMutableBufferPointer { renderer.render(into: $0.baseAddress!, frames: frames) }
        return (out, silent)
    }

    @Test func silentUntilAFingerMoves() {
        let renderer = SynthRenderer(parameters: SynthParameters(), sampleRate: rate)
        let result = render(renderer, frames: 512)
        #expect(result.silent)
        #expect(result.samples.allSatisfy { $0 == 0 })
    }

    @Test func everyTimbreScratchesWithinBounds() {
        for timbre in FeedbackTimbre.allCases {
            let parameters = SynthParameters()
            let renderer = SynthRenderer(parameters: parameters, sampleRate: rate)
            var energy: Float = 0
            for _ in 0..<40 {
                parameters.setScratch(gain: 1, brightness: 1, timbre: timbre)
                let result = render(renderer, frames: 480)
                #expect(!result.silent)
                #expect(result.samples.allSatisfy { $0.isFinite && abs($0) <= 1 })
                energy += result.samples.reduce(0) { $0 + $1 * $1 }
            }
            #expect(energy > 1, "\(timbre) inaudible")
        }
    }

    @Test func gainRampsInsteadOfJumping() {
        let parameters = SynthParameters()
        let renderer = SynthRenderer(parameters: parameters, sampleRate: rate)
        parameters.setScratch(gain: 1, brightness: 0.5, timbre: .snow)
        let start = render(renderer, frames: 64).samples
        for _ in 0..<5 {
            parameters.setScratch(gain: 1, brightness: 0.5, timbre: .snow)
            _ = render(renderer, frames: 960)
        }
        parameters.setScratch(gain: 1, brightness: 0.5, timbre: .snow)
        let later = render(renderer, frames: 960).samples
        // 64 échantillons ≈ 1,3 ms : l'attaque (10 ms) n'a pas encore ouvert le gain.
        #expect((start.map(abs).max() ?? 1) < (later.map(abs).max() ?? 0) * 0.4)
    }

    @Test func fallsSilentWhenUpdatesStop() {
        let parameters = SynthParameters()
        let renderer = SynthRenderer(parameters: parameters, sampleRate: rate)
        parameters.setScratch(gain: 0.8, brightness: 0.6, timbre: .gold)
        #expect(!render(renderer, frames: 2048).silent)
        // Plus de mise à jour pendant 1 s (doigt immobile, main actor bloqué) : la voix se tait seule.
        var silent = false
        for _ in 0..<100 { silent = render(renderer, frames: 480).silent }
        #expect(silent)
    }

    @Test func whooshBurstsThenFades() {
        let parameters = SynthParameters()
        let renderer = SynthRenderer(parameters: parameters, sampleRate: rate)
        parameters.triggerWhoosh(amplitude: 0.7, timbre: .snow)
        let burst = render(renderer, frames: 4800)
        #expect(!burst.silent)
        #expect(burst.samples.map(abs).max() ?? 0 > 0.05)
        var silent = false
        for _ in 0..<200 { silent = render(renderer, frames: 480).silent }
        #expect(silent)
    }
}

@MainActor
struct FeedbackCenterTests {
    private func exercise(_ center: FeedbackCenter) {
        for mask in MaskKind.allCases {
            center.scratchBegan(mask: mask)
            for step in 0..<30 { center.scratchMoved(speed: Float(step) / 30, erodedAmount: 12, mask: mask) }
            center.scratchEnded()
            for step in 0..<30 { center.blow(strength: Float(step % 10) / 10, mask: mask) }
            center.blow(strength: 0, mask: mask)
            center.shake(strength: 0.9, mask: mask)
            for _ in 0..<10 { center.chunk(amount: 120, mask: mask) }
            center.revealCompleted(mask: mask)
            center.reset()
        }
    }

    @Test func everythingIsSafeWhenDisabled() {
        let center = FeedbackCenter()
        center.hapticsEnabled = false
        center.soundEnabled = false
        center.prepare()
        exercise(center)
    }

    @Test func hapticsWithoutHardwareStayInert() {
        // Simulateur : pas de moteur haptique. Le chemin haptique doit s'éteindre sans bruit.
        let center = FeedbackCenter()
        center.soundEnabled = false
        center.prepare()
        exercise(center)
        center.hapticsEnabled = false
        center.hapticsEnabled = true
        exercise(center)
    }

    @Test func callsBeforePrepareAreIgnored() {
        // C'est le cas des tests du moteur : un centre jamais préparé ne doit rien démarrer.
        let center = FeedbackCenter()
        exercise(center)
        center.hapticsEnabled = false
        center.soundEnabled = false
        center.hapticsEnabled = true
        exercise(center)
    }
}
