import CoreGraphics
import Foundation
import Testing
import simd
@testable import RevelioNoel

@MainActor
struct GoldPieceTests {
    @Test func hueRoundTripsForEveryPiece() {
        for piece in GoldPiece.allCases {
            #expect(GoldPiece(hue: piece.hue) == piece)
        }
    }

    @Test func outOfRangeHueIsClamped() {
        #expect(GoldPiece(hue: -3) == .crumb)
        #expect(GoldPiece(hue: 1) == .leaf)
        #expect(GoldPiece(hue: 42) == .leaf)
    }
}

@MainActor
struct GoldRecipeTests {
    private func event(_ source: ErosionEvent.Source, cells: Int, amount: Float = 0.5,
                       direction: SIMD2<Float> = SIMD2(300, 0)) -> ErosionEvent {
        let eroded = (0..<cells).map { i in
            ErodedCell(position: SIMD2(Float(i % 10) / 10 + 0.05, Float(i / 10) / 12 + 0.05), amount: amount)
        }
        return ErosionEvent(source: source, cells: eroded, cardSize: CGSize(width: 300, height: 400),
                            direction: direction, intensity: 0.8)
    }

    @Test func countGrowsWithErosionAndIsCapped() {
        #expect(GoldRecipe.count(for: 0, perUnit: 0.5, cap: 10) == 0)
        #expect(GoldRecipe.count(for: 0.1, perUnit: 0.5, cap: 10) == 1)
        #expect(GoldRecipe.count(for: 6, perUnit: 0.5, cap: 10) == 4)
        #expect(GoldRecipe.count(for: 1000, perUnit: 0.5, cap: 10) == 10)
    }

    @Test func scratchingShedsFlakesAndCurlsThatFall() {
        var rng = SeededRandom(seed: 7)
        let particles = GoldRecipe.particles(for: event(.scratch, cells: 60), rng: &rng)
        #expect(!particles.isEmpty)
        #expect(particles.count <= 6)
        for p in particles {
            #expect(p.kind == .goldFlake || p.kind == .goldCurl)
            if p.kind == .goldFlake { #expect(GoldPiece(hue: p.hue) == .crumb) }
            #expect(p.gravityScale > 0.5)
        }
    }

    @Test func blowingLiftsGlitterUpwards() {
        var rng = SeededRandom(seed: 3)
        let particles = GoldRecipe.particles(for: event(.blow, cells: 120), rng: &rng)
        #expect(!particles.isEmpty)
        #expect(particles.count <= 16)
        for p in particles {
            #expect(p.kind == .goldFlake)
            #expect(p.velocity.y < 0, "les paillettes doivent partir vers le haut")
            #expect(p.gravityScale < 0.5, "puis retomber doucement")
            #expect(GoldPiece(hue: p.hue) != .crumb)
        }
    }

    @Test func shakingDropsLargeFlippingPiecesOfFoil() {
        var rng = SeededRandom(seed: 11)
        let particles = GoldRecipe.particles(for: event(.shake, cells: 120, amount: 1), rng: &rng)
        #expect(particles.count <= 12)
        let leaves = particles.filter { $0.kind == .goldFlake && GoldPiece(hue: $0.hue) == .leaf }
        #expect(!leaves.isEmpty)
        for leaf in leaves {
            #expect(leaf.size >= 8)
            #expect(leaf.flipSpeed > 0, "un morceau de feuille se retourne en tombant")
        }
        // Projetés dans le sens de la secousse (ici vers la droite).
        let meanVX = particles.map(\.velocity.x).reduce(0, +) / Float(particles.count)
        #expect(meanVX > 0)
    }

    @Test func finishingScattersGlitter() {
        var rng = SeededRandom(seed: 5)
        let particles = GoldRecipe.particles(for: event(.finish, cells: 200, amount: 0.3), rng: &rng)
        #expect(!particles.isEmpty)
        #expect(particles.count <= 22)
        #expect(particles.contains { GoldPiece(hue: $0.hue) == .glitter })
    }

    @Test func noErosionNoParticles() {
        var rng = SeededRandom(seed: 1)
        for source in [ErosionEvent.Source.scratch, .blow, .shake, .finish] {
            #expect(GoldRecipe.particles(for: event(source, cells: 0), rng: &rng).isEmpty)
        }
    }
}

@MainActor
struct GoldSheenTests {
    @Test func tiltingRightSlidesTheHighlightLeft() {
        let upright = GoldSheen.light(gravity: SIMD2(0, 1), time: 0, drift: 0)
        let tiltedRight = GoldSheen.light(gravity: SIMD2(0.5, 0.85), time: 0, drift: 0)
        let tiltedLeft = GoldSheen.light(gravity: SIMD2(-0.5, 0.85), time: 0, drift: 0)
        #expect(tiltedRight.x < upright.x)
        #expect(tiltedLeft.x > upright.x)
    }

    @Test func layingThePhoneDownLowersTheHighlight() {
        let upright = GoldSheen.light(gravity: SIMD2(0, 1), time: 0, drift: 0)
        let flat = GoldSheen.light(gravity: SIMD2(0, 0.35), time: 0, drift: 0)
        #expect(flat.y > upright.y)
    }

    @Test func driftAnimatesTheHighlightOverTime() {
        let a = GoldSheen.light(gravity: SIMD2(0, 1), time: 1, drift: 0.3)
        let b = GoldSheen.light(gravity: SIMD2(0, 1), time: 4, drift: 0.3)
        #expect(simd_distance(a, b) > 0.05)
    }

    @Test func gravityJumpsAreSmoothed() {
        var sheen = GoldSheen()
        _ = sheen.update(gravity: SIMD2(0, 1), time: 0)
        // Le moteur remplace la gravité par (0, 0.35) d'un coup quand le téléphone passe à plat.
        _ = sheen.update(gravity: SIMD2(0, 0.35), time: 1.0 / 60)
        let afterOneFrame = sheen.smoothedGravity ?? .zero
        #expect(afterOneFrame.y > 0.85, "le reflet ne doit pas sauter")
        for frame in 2...120 { _ = sheen.update(gravity: SIMD2(0, 0.35), time: Float(frame) / 60) }
        #expect(abs((sheen.smoothedGravity ?? .zero).y - 0.35) < 0.01)
    }

    @Test func repeatedUpdatesAtTheSameTimeDoNotMove() {
        var sheen = GoldSheen()
        _ = sheen.update(gravity: SIMD2(0, 1), time: 2)
        let first = sheen.update(gravity: SIMD2(1, 0), time: 2)
        let second = sheen.update(gravity: SIMD2(1, 0), time: 2)
        #expect(first == second)
        #expect(sheen.smoothedGravity == SIMD2(0, 1))
    }
}

@MainActor
struct GoldTicketLayoutTests {
    @Test func motifsStayInsideTheFrameAndAwayFromTheCartouche() {
        let layout = GoldTicketLayout(size: CGSize(width: 320, height: 427))
        #expect(!layout.motifs.isEmpty)
        let plate = layout.cartouche
        for motif in layout.motifs {
            let box = CGRect(x: motif.center.x - motif.radius, y: motif.center.y - motif.radius,
                             width: motif.radius * 2, height: motif.radius * 2)
            #expect(layout.innerFrame.contains(box), "motif hors du filet : \(motif.center)")
            #expect(!plate.intersects(box), "motif sur le cartouche : \(motif.center)")
        }
    }

    @Test func everyMotifKindAppears() {
        let layout = GoldTicketLayout(size: CGSize(width: 320, height: 427))
        for kind in GoldTicketLayout.MotifKind.allCases {
            #expect(layout.motifs.contains { $0.kind == kind })
        }
    }

    @Test func cartoucheIsCenteredInsideTheFrame() {
        let size = CGSize(width: 320, height: 427)
        let layout = GoldTicketLayout(size: size)
        #expect(abs(layout.cartouche.midX - size.width / 2) < 0.5)
        #expect(abs(layout.cartouche.midY - size.height / 2) < 0.5)
        #expect(layout.innerFrame.contains(layout.cartouche))
    }

    @Test func layoutIsDeterministic() {
        let size = CGSize(width: 300, height: 400)
        #expect(GoldTicketLayout(size: size) == GoldTicketLayout(size: size))
    }
}

@MainActor
struct GoldArtTests {
    @Test func shineStaysInRangeAndFollowsOrientation() {
        var values: [Float] = []
        for i in 0..<64 {
            let angle = Float(i) / 64 * 2 * .pi
            let v = GoldArt.shine(rotation: angle, flip: angle * 0.7, seed: 0.3)
            #expect(v >= 0 && v <= 1)
            values.append(v)
        }
        // Un copeau qui tourne passe de l'ombre à l'éclat.
        #expect((values.max() ?? 0) - (values.min() ?? 0) > 0.5)
    }

    @Test func goldRampMatchesItsEndsAndBrightensMonotonically() {
        #expect(GoldArt.goldRGB(-1) == GoldArt.rampStops.first?.1)
        #expect(GoldArt.goldRGB(5) == GoldArt.rampStops.last?.1)
        var previous: Float = -1
        for i in 0...26 {
            let rgb = GoldArt.goldRGB(Float(i) * 0.05)
            let luminance = simd_dot(rgb, SIMD3(0.2126, 0.7152, 0.0722))
            #expect(luminance >= previous)
            previous = luminance
        }
    }
}

@MainActor
struct GoldCrumbleTests {
    @Test func staysAtZeroWhileCovered() {
        var crumble = GoldCrumble()
        #expect(crumble.update(phase: .covered, time: 0) == 0)
        #expect(crumble.update(phase: .covered, time: 5) == 0)
    }

    @Test func rampsUpSmoothlyOnceFinishingStarts() {
        var crumble = GoldCrumble()
        #expect(crumble.update(phase: .finishing, time: 10) == 0)
        let mid = crumble.update(phase: .finishing, time: 10 + GoldCrumble.ramp / 2)
        #expect(abs(mid - 0.5) < 0.01)
        #expect(crumble.update(phase: .revealed, time: 12) == 1)
    }

    @Test func resetsWhenThePhotoIsCoveredAgain() {
        var crumble = GoldCrumble()
        _ = crumble.update(phase: .finishing, time: 1)
        _ = crumble.update(phase: .revealed, time: 3)
        #expect(crumble.update(phase: .covered, time: 4) == 0)
        #expect(crumble.update(phase: .finishing, time: 5) == 0)
    }
}
