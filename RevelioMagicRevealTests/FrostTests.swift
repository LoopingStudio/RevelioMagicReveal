import CoreGraphics
import Foundation
import Testing
import simd
@testable import RevelioMagicReveal

struct FrostRecipeTests {
    private let card = CGSize(width: 300, height: 400)

    /// Une érosion de `count` cellules réparties sur la carte, chacune de `amount`.
    private func event(_ source: ErosionEvent.Source, cells count: Int, amount: Float = 0.5,
                       direction: SIMD2<Float> = SIMD2(1, 0), intensity: Float = 0.9) -> ErosionEvent {
        let cells = (0..<count).map { i in
            ErodedCell(position: SIMD2(Float(i % 20) / 20 + 0.025, Float(i / 20 % 20) / 20 + 0.025), amount: amount)
        }
        return ErosionEvent(source: source, cells: cells, cardSize: card, direction: direction, intensity: intensity)
    }

    @Test(arguments: [ErosionEvent.Source.scratch, .blow, .shake, .finish])
    func emptyErosionEmitsNothing(source: ErosionEvent.Source) {
        var rng = SeededRandom(seed: 1)
        #expect(FrostRecipe.particles(for: event(source, cells: 0), rng: &rng).isEmpty)
        #expect(FrostRecipe.particles(for: event(source, cells: 30, amount: 0), rng: &rng).isEmpty)
    }

    @Test func shakeThrowsIceShardsAndPowder() {
        var rng = SeededRandom(seed: 2)
        let particles = FrostRecipe.particles(for: event(.shake, cells: 300), rng: &rng)
        let shards = particles.filter { $0.kind == .shard }
        #expect(!shards.isEmpty)
        #expect(particles.contains { $0.kind == .frostDust })
        // Les éclats partent dans le sens du coup et tournoient.
        #expect(shards.allSatisfy { $0.spin != 0 || $0.flipSpeed != 0 })
        #expect(shards.map(\.velocity.x).reduce(0, +) > 0)
    }

    @Test func shakeEmissionIsCapped() {
        var rng = SeededRandom(seed: 3)
        let particles = FrostRecipe.particles(for: event(.shake, cells: 400, amount: 1), rng: &rng)
        #expect(particles.filter { $0.kind == .shard }.count <= 8)
        #expect(particles.count <= 22)
    }

    @Test func scratchRaisesOnlyFrostPowder() {
        var rng = SeededRandom(seed: 4)
        let particles = FrostRecipe.particles(for: event(.scratch, cells: 12), rng: &rng)
        #expect(!particles.isEmpty)
        #expect(particles.allSatisfy { $0.kind == .frostDust && $0.hue == FrostArt.powderHue })
        #expect(particles.count <= 10)
    }

    @Test func blowDropletsStayOnThePaneWhileTheySlide() {
        var rng = SeededRandom(seed: 5)
        var system = ParticleSystem()
        for _ in 0..<120 {
            system.emit(contentsOf: FrostRecipe.particles(for: event(.blow, cells: 40, direction: SIMD2(0, -1)), rng: &rng))
        }
        let droplets = system.particles.filter { $0.kind == .droplet }
        #expect(!droplets.isEmpty)
        let pane = CGRect(origin: .zero, size: card)
        #expect(droplets.allSatisfy { $0.frostPane == pane })

        // Une seconde plus tard, les gouttes ont glissé vers le bas et savent toujours où est la vitre.
        let before = droplets.map(\.position.y).reduce(0, +) / Float(droplets.count)
        for _ in 0..<60 {
            system.step(dt: 1.0 / 60, gravity: SIMD2(0, 1), time: 0, bounds: pane.insetBy(dx: -400, dy: -400))
        }
        let after = system.particles.filter { $0.kind == .droplet }
        #expect(after.allSatisfy { $0.frostPane == pane })
        #expect(after.map(\.position.y).reduce(0, +) / Float(after.count) > before)
    }

    @Test func blowAddsSomeMistButNoShards() {
        var rng = SeededRandom(seed: 6)
        var all: [Particle] = []
        for _ in 0..<200 {
            all += FrostRecipe.particles(for: event(.blow, cells: 40, direction: SIMD2(0, -1)), rng: &rng)
        }
        #expect(all.contains { $0.kind == .frostDust && $0.hue == FrostArt.mistHue })
        #expect(!all.contains { $0.kind == .shard })
    }

    @Test func finishMixesPowderAndShards() {
        var rng = SeededRandom(seed: 7)
        var all: [Particle] = []
        for _ in 0..<10 {
            all += FrostRecipe.particles(for: event(.finish, cells: 400, amount: 0.4), rng: &rng)
        }
        #expect(all.contains { $0.kind == .frostDust })
        #expect(all.contains { $0.kind == .shard })
    }

    @Test func countRoundsRandomlyAroundTheExpectationAndRespectsTheCap() {
        var rng = SeededRandom(seed: 8)
        #expect(FrostRecipe.count(expected: 0, cap: 5, rng: &rng) == 0)
        #expect(FrostRecipe.count(expected: 3, cap: 0, rng: &rng) == 0)
        #expect(FrostRecipe.count(expected: 100, cap: 5, rng: &rng) == 5)
        let draws = (0..<4000).map { _ in FrostRecipe.count(expected: 2.3, cap: 10, rng: &rng) }
        #expect(Set(draws).isSubset(of: [2, 3]))
        let mean = Float(draws.reduce(0, +)) / Float(draws.count)
        #expect(abs(mean - 2.3) < 0.05)
    }
}

struct FrostLookTests {
    @Test func blowMeltsMoreThanScratchWhichMeltsMoreThanShake() {
        let blow = FrostLook.wetness(for: .blow)
        let scratch = FrostLook.wetness(for: .scratch)
        let shake = FrostLook.wetness(for: .shake)
        #expect(blow > scratch && scratch > shake)
        #expect([blow, scratch, shake].allSatisfy { (0...1).contains($0) })
    }
}
