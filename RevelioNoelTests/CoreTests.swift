import CoreGraphics
import Foundation
import Testing
import simd
@testable import RevelioNoel

struct CoverageFieldTests {
    @Test func startsFullyCovered() {
        let field = CoverageField(columns: 30, aspect: 0.75)
        #expect(field.rows == 40)
        #expect(field.revealedFraction == 0)
    }

    @Test func discErodesTheCenterButNotFarAway() {
        var field = CoverageField(columns: 30, aspect: 0.75)
        let eroded = field.erodeDisc(center: SIMD2(0.5, 0.5), radius: 0.1, strength: 1)
        #expect(!eroded.isEmpty)
        #expect(field.sample(at: SIMD2(0.5, 0.5)) < 0.05)
        #expect(field.sample(at: SIMD2(0.1, 0.1)) == 1)
        #expect(field.revealedFraction > 0)
    }

    @Test func discStaysRoundOnANonSquareCard() {
        var field = CoverageField(columns: 60, aspect: 0.75)
        field.erodeDisc(center: SIMD2(0.5, 0.5), radius: 0.1, strength: 1)
        // 0.08 largeur à droite = 0.08 × aspect en y : même distance physique, même couverture.
        let right = field.sample(at: SIMD2(0.58, 0.5))
        let below = field.sample(at: SIMD2(0.5, 0.5 + 0.08 * 0.75))
        #expect(abs(right - below) < 0.12)
    }

    @Test func strokeLeavesNoGapsAlongTheSegment() {
        var field = CoverageField(columns: 60, aspect: 0.75)
        field.erodeStroke(from: SIMD2(0.1, 0.5), to: SIMD2(0.9, 0.5), radius: 0.05, strength: 1)
        for x in stride(from: Float(0.15), through: 0.85, by: 0.05) {
            #expect(field.sample(at: SIMD2(x, 0.5)) < 0.5, "trou à x = \(x)")
        }
    }

    @Test func valuesOnlyGoDown() {
        var field = CoverageField(columns: 20, aspect: 1)
        field.erodeDisc(center: SIMD2(0.5, 0.5), radius: 0.2, strength: 0.5)
        let before = field.values
        field.erodeDisc(center: SIMD2(0.5, 0.5), radius: 0.2, strength: 0.2)
        for (a, b) in zip(before, field.values) { #expect(b <= a) }
        #expect(field.values.allSatisfy { $0 >= 0 })
    }

    @Test func dissolveEventuallyClearsEverything() {
        var field = CoverageField(columns: 20, aspect: 1)
        for _ in 0..<60 { field.dissolve(by: 0.1) }
        #expect(field.revealedFraction > 0.999)
    }

    @Test func resetCoversAgain() {
        var field = CoverageField(columns: 20, aspect: 1)
        field.erodeDisc(center: SIMD2(0.5, 0.5), radius: 0.3, strength: 1)
        field.reset()
        #expect(field.revealedFraction == 0)
    }
}

struct ThresholdMapTests {
    @Test func blowFrontRevealsTheBottomCenterFirst() {
        let map = ThresholdMap.blowFront(cols: 30, rows: 40, aspect: 0.75, seed: 3)
        var field = CoverageField(cols: 30, rows: 40, aspect: 0.75)
        field.apply(map, progress: 0.3)
        #expect(field.sample(at: SIMD2(0.5, 0.97)) < 0.2)
        #expect(field.sample(at: SIMD2(0.05, 0.03)) == 1)
    }

    @Test func blowFrontCompletesAtItsCompletionProgress() {
        let map = ThresholdMap.blowFront(cols: 30, rows: 40, aspect: 0.75, seed: 3)
        var field = CoverageField(cols: 30, rows: 40, aspect: 0.75)
        field.apply(map, progress: map.completionProgress)
        #expect(field.revealedFraction == 1)
    }

    @Test func shakeChunksFallWholeAndProgressively() {
        let map = ThresholdMap.shakeChunks(cols: 30, rows: 40, aspect: 0.75, seed: 5, chunkCount: 20)
        #expect(Set(map.thresholds).count == 20)
        var field = CoverageField(cols: 30, rows: 40, aspect: 0.75)
        field.apply(map, progress: 0.5)
        let half = field.revealedFraction
        #expect(half > 0.2 && half < 0.8)
        // Bande étroite : les cellules sont soit tombées, soit presque intactes.
        let undecided = field.values.filter { $0 > 0.05 && $0 < 0.95 }.count
        #expect(Float(undecided) / Float(field.count) < 0.1)
    }

    @Test func mapsAreDeterministicForASeed() {
        let a = ThresholdMap.shakeChunks(cols: 20, rows: 20, aspect: 1, seed: 9)
        let b = ThresholdMap.shakeChunks(cols: 20, rows: 20, aspect: 1, seed: 9)
        #expect(a.thresholds == b.thresholds)
    }
}

struct AnalyzerTests {
    @Test func decibelsOfFullScaleSineAreAboutMinusThree() {
        let samples = (0..<4800).map { Float(sin(Double($0) * 2 * .pi * 440 / 48000)) }
        let rms = samples.withUnsafeBufferPointer { BlowAnalyzer.rms($0) }
        #expect(abs(BlowAnalyzer.decibels(rms: rms) + 3.01) < 0.1)
    }

    @Test func blowStaysAtZeroBelowThreshold() {
        var analyzer = BlowAnalyzer(thresholdDB: -26)
        for _ in 0..<50 { analyzer.process(levelDB: -40, dt: 0.02) }
        #expect(analyzer.strength == 0)
    }

    @Test func blowRisesQuicklyAndFallsSlowly() {
        var analyzer = BlowAnalyzer(thresholdDB: -26)
        for _ in 0..<10 { analyzer.process(levelDB: -2, dt: 0.02) }
        #expect(analyzer.strength > 0.9)
        analyzer.process(levelDB: -80, dt: 0.02)
        #expect(analyzer.strength > 0.8)
        for _ in 0..<100 { analyzer.process(levelDB: -80, dt: 0.02) }
        #expect(analyzer.strength == 0)
    }

    @Test func shakeIgnoresGentleMotion() {
        var analyzer = ShakeAnalyzer(thresholdG: 1.1)
        #expect(analyzer.process(acceleration: SIMD3(0.4, 0.3, 0.1), dt: 1.0 / 60) == nil)
    }

    @Test func shakeImpulseHasScreenDirectionAndCooldown() {
        var analyzer = ShakeAnalyzer(thresholdG: 1.0)
        let impulse = analyzer.process(acceleration: SIMD3(0, 2, 0), dt: 1.0 / 60)
        #expect(impulse != nil)
        // Accélération vers le haut de l'appareil = vers le haut de l'écran (y négatif).
        #expect(impulse!.direction.y < -0.99)
        #expect(analyzer.process(acceleration: SIMD3(0, 2, 0), dt: 1.0 / 60) == nil)
        #expect(analyzer.process(acceleration: SIMD3(0, 2, 0), dt: 0.2) != nil)
    }
}

struct ParticleSystemTests {
    @Test func gravityPullsParticlesDown() {
        var system = ParticleSystem()
        system.emit(Particle(kind: .powder, position: SIMD2(100, 100), life: 2, maxLife: 2, drag: 0))
        for _ in 0..<10 {
            system.step(dt: 1.0 / 60, gravity: SIMD2(0, 1), time: 0, bounds: CGRect(x: -500, y: -500, width: 2000, height: 2000))
        }
        #expect(system.particles[0].position.y > 100)
    }

    @Test func deadAndEscapedParticlesAreRemoved() {
        var system = ParticleSystem()
        system.emit(Particle(kind: .powder, position: SIMD2(0, 0), life: 0.01, maxLife: 0.01))
        system.emit(Particle(kind: .powder, position: SIMD2(0, 0), velocity: SIMD2(100_000, 0), life: 5, maxLife: 5))
        system.emit(Particle(kind: .powder, position: SIMD2(0, 0), life: 5, maxLife: 5, gravityScale: 0))
        system.step(dt: 1.0 / 60, gravity: SIMD2(0, 1), time: 0, bounds: CGRect(x: -100, y: -100, width: 200, height: 200))
        #expect(system.count == 1)
    }

    @Test func emissionIsCapped() {
        var system = ParticleSystem()
        system.maxCount = 5
        system.emit(contentsOf: Array(repeating: Particle(kind: .powder, position: .zero), count: 20))
        #expect(system.count == 5)
    }
}

@MainActor
struct RevealEngineTests {
    private func makeEngine(gesture: RevealGesture = .scratch, autoFinish: Double = 0.7) -> RevealEngine {
        let defaults = UserDefaults(suiteName: "RevealEngineTests-\(UUID().uuidString)")!
        let settings = RevealSettings(defaults: defaults)
        settings.autoFinishThreshold = autoFinish
        let engine = RevealEngine(settings: settings, feedback: FeedbackCenter(), mask: .snow, gesture: gesture)
        engine.cardSize = CGSize(width: 300, height: 400)
        return engine
    }

    @Test func scratchingRevealsAndEmitsParticles() {
        let engine = makeEngine()
        engine.scratch(at: CGPoint(x: 50, y: 200), time: 0)
        engine.scratch(at: CGPoint(x: 250, y: 200), time: 0.1)
        engine.endScratch()
        engine.tick(dt: 1.0 / 60)
        #expect(engine.revealed > 0.02)
        #expect(!engine.particles.isEmpty)
    }

    @Test func scratchIsIgnoredWhenAnotherGestureIsSelected() {
        let engine = makeEngine(gesture: .blow)
        engine.scratch(at: CGPoint(x: 150, y: 200), time: 0)
        engine.tick(dt: 1.0 / 60)
        #expect(engine.revealed == 0)
    }

    @Test func simulatedBlowRevealsFromTheBottom() {
        let engine = makeEngine(gesture: .blow, autoFinish: 1)
        engine.simulatedBlow = 1
        for _ in 0..<60 { engine.tick(dt: 1.0 / 60) }
        #expect(engine.field.sample(at: SIMD2(0.5, 0.97)) < 0.1)
        #expect(engine.field.sample(at: SIMD2(0.05, 0.03)) == 1)
    }

    @Test func shakeImpulsesDropChunks() {
        let engine = makeEngine(gesture: .shake, autoFinish: 1)
        for _ in 0..<3 {
            engine.shakeImpulse(ShakeImpulse(strength: 1, direction: SIMD2(1, 0)))
            for _ in 0..<20 { engine.tick(dt: 1.0 / 60) }
        }
        #expect(engine.revealed > 0.2)
    }

    @Test func autoFinishCompletesTheReveal() {
        let engine = makeEngine(gesture: .blow, autoFinish: 0.5)
        engine.simulatedBlow = 1
        var ticks = 0
        while engine.phase == .covered, ticks < 600 { engine.tick(dt: 1.0 / 60); ticks += 1 }
        #expect(engine.phase == .finishing)
        engine.simulatedBlow = 0
        for _ in 0..<120 { engine.tick(dt: 1.0 / 60) }
        #expect(engine.phase == .revealed)
        #expect(engine.revealed == 1)
    }

    @Test func autoFinishCanBeDisabled() {
        let engine = makeEngine(gesture: .blow, autoFinish: 1)
        engine.simulatedBlow = 1
        for _ in 0..<120 { engine.tick(dt: 1.0 / 60) }
        #expect(engine.phase == .covered)
    }

    @Test func paperAutoFinishTearsFromTheCenterOutward() {
        let engine = makeEngine()
        engine.mask = .paper
        engine.revealAll()
        // 0,2 s après le début de la fin : la vague (0,3 s) n'a pas encore atteint les bords,
        // même si la carte, elle, se dissout bien plus vite.
        for _ in 0..<12 { engine.tick(dt: 1.0 / 60) }
        let sheet = engine.paper
        let center = SIMD2<Float>(0.5, 0.5 / sheet.aspect)
        let distances = sheet.pieces.map { simd_distance($0.centroid, center) }
        let attached = sheet.pieces.indices.filter { sheet.attached[$0] }
        let detached = sheet.pieces.indices.filter { !sheet.attached[$0] }
        #expect(!attached.isEmpty)
        #expect(!detached.isEmpty)
        let meanAttached = attached.map { distances[$0] }.reduce(0, +) / Float(attached.count)
        let meanDetached = detached.map { distances[$0] }.reduce(0, +) / Float(detached.count)
        #expect(meanAttached > meanDetached)
        for _ in 0..<30 { engine.tick(dt: 1.0 / 60) }
        #expect(engine.paper.attachedCount == 0)
    }

    @Test func frameRateDropsWhenNothingMoves() {
        let engine = makeEngine()
        engine.tick(dt: 1.0 / 60)
        #expect(!engine.needsFullFrameRate)
        engine.scratch(at: CGPoint(x: 150, y: 200), time: 0)
        #expect(engine.needsFullFrameRate)
        engine.endScratch()
        for _ in 0..<240 { engine.tick(dt: 1.0 / 60) }
        #expect(!engine.needsFullFrameRate)
    }

    @Test func changingMaskCoversThePhotoAgain() {
        let engine = makeEngine()
        engine.scratch(at: CGPoint(x: 150, y: 200), time: 0)
        engine.tick(dt: 1.0 / 60)
        #expect(engine.revealed > 0)
        engine.mask = .gold
        engine.tick(dt: 1.0 / 60)
        #expect(engine.revealed == 0)
        #expect(engine.particles.isEmpty)
    }
}
