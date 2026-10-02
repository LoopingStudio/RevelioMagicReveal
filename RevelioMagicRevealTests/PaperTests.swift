import CoreGraphics
import Foundation
import Testing
import simd
@testable import RevelioMagicReveal

struct PaperGeometryTests {
    private let aspect: Float = 0.75

    @Test(arguments: [UInt32(1), 2, 7, 42, 1234])
    func piecesTileTheWholeCard(seed: UInt32) {
        let pieces = PaperCutter.cut(aspect: aspect, seed: seed)
        #expect((45...60).contains(pieces.count))
        let cardArea = 1 / aspect
        let total = pieces.reduce(Float(0)) { $0 + $1.area }
        #expect(abs(total - cardArea) < cardArea * 1e-4, "aires : \(total) pour \(cardArea)")
        #expect(pieces.allSatisfy { $0.area > 0 })
    }

    @Test(arguments: [UInt32(1), 2, 7, 42, 1234])
    func sharedEdgesAreTheSameTornLineOnBothSides(seed: UInt32) {
        let pieces = PaperCutter.cut(aspect: aspect, seed: seed)
        var checked = 0
        for (i, piece) in pieces.enumerated() {
            for edge in piece.edges {
                let twins = pieces[edge.neighbor].edges.filter { $0.neighbor == i }
                // L'autre côté parcourt exactement la même ligne, en sens inverse.
                #expect(twins.contains { $0.points == Array(edge.points.reversed()) },
                        "arête \(i)–\(edge.neighbor) différente des deux côtés")
                checked += 1
            }
        }
        #expect(checked > 100)
    }

    @Test func tornEdgesAreActuallyJagged() {
        let pieces = PaperCutter.cut(aspect: aspect, seed: 3)
        let longEdges = pieces.flatMap(\.edges).filter { simd_distance($0.points.first!, $0.points.last!) > 0.06 }
        #expect(!longEdges.isEmpty)
        for edge in longEdges {
            #expect(edge.points.count > 4)
            let a = edge.points.first!, b = edge.points.last!
            let n = simd_normalize(SIMD2(-(b - a).y, (b - a).x))
            let deviation = edge.points.map { abs(simd_dot($0 - a, n)) }.max()!
            #expect(deviation > 0.001, "arête trop droite")
            #expect(deviation < 0.03, "arête qui part trop loin")
        }
    }

    @Test func cuttingIsDeterministicForASeed() {
        let a = PaperCutter.cut(aspect: aspect, seed: 9)
        let b = PaperCutter.cut(aspect: aspect, seed: 9)
        let c = PaperCutter.cut(aspect: aspect, seed: 10)
        #expect(a.map(\.outline) == b.map(\.outline))
        #expect(a.map(\.outline) != c.map(\.outline))
    }

    @Test func everyPieceHasDetectionPointsInsideTheCard() {
        let pieces = PaperCutter.cut(aspect: aspect, seed: 5)
        for piece in pieces {
            #expect(piece.samples.count >= 8)
            #expect(piece.samples.allSatisfy { (0...1).contains($0.x) && (0...1).contains($0.y) })
        }
        let total = pieces.reduce(0) { $0 + $1.samples.count }
        #expect(total == Set(pieces.flatMap { $0.samples.map { "\($0.x),\($0.y)" } }).count)
    }
}

struct PaperSheetTests {
    private let cardSize = CGSize(width: 300, height: 400)

    private func makeField() -> CoverageField {
        CoverageField(columns: RevealEngine.fieldColumns, aspect: RevealEngine.cardAspect)
    }

    @Test func startsFullyAttached() {
        let sheet = PaperSheet(aspect: RevealEngine.cardAspect, seed: 4)
        #expect(sheet.attachedCount == sheet.pieces.count)
        #expect(sheet.revealedFraction == 0)
        #expect(sheet.falling.isEmpty)
    }

    @Test func piecesHoldAboveTheThresholdAndTearBelowIt() {
        var sheet = PaperSheet(aspect: RevealEngine.cardAspect, seed: 4)
        var rng = SeededRandom(seed: 1)
        var field = makeField()
        // Couverture uniforme 0,6 : au-dessus du seuil (0,55), rien ne tombe, mais tout se soulève.
        field.dissolve(by: 0, minimumStep: 0.4)
        _ = sheet.step(dt: 1.0 / 60, field: field, events: [], gravity: SIMD2(0, 1), cardSize: cardSize, rng: &rng)
        #expect(sheet.attachedCount == sheet.pieces.count)
        #expect(sheet.looseness.allSatisfy { $0 > 0.8 && $0 < 1 })
        // 0,5 : sous le seuil, tout se détache.
        field.dissolve(by: 0, minimumStep: 0.1)
        _ = sheet.step(dt: 1.0 / 60, field: field, events: [], gravity: SIMD2(0, 1), cardSize: cardSize, rng: &rng)
        #expect(sheet.attachedCount == 0)
        #expect(sheet.falling.count == sheet.pieces.count)
        #expect(sheet.revealedFraction == 1)
    }

    @Test func onlyThePieceUnderTheErosionTearsAndRevealedFractionIsItsArea() {
        var sheet = PaperSheet(aspect: RevealEngine.cardAspect, seed: 8)
        var rng = SeededRandom(seed: 1)
        var field = makeField()
        let target = sheet.pieces.indices.min { simd_distance(sheet.pieces[$0].centroid, SIMD2(0.5, 0.66)) < simd_distance(sheet.pieces[$1].centroid, SIMD2(0.5, 0.66)) }!
        let piece = sheet.pieces[target]
        // Disque centré sur le morceau, un peu plus petit que lui : sa couverture moyenne passe sous le seuil.
        field.erodeDisc(center: SIMD2(piece.centroid.x, piece.centroid.y * RevealEngine.cardAspect), radius: piece.radius * 0.95, strength: 1)
        #expect(sheet.meanCoverage(of: target, in: field) < PaperSheet.detachThreshold)

        let scraps = sheet.step(dt: 1.0 / 60, field: field, events: [], gravity: SIMD2(0, 1), cardSize: cardSize, rng: &rng)
        #expect(!sheet.attached[target])
        #expect(!scraps.isEmpty)
        #expect(scraps.allSatisfy { $0.kind == .paperScrap })
        let detached = sheet.pieces.indices.filter { !sheet.attached[$0] }
        // Les voisins effleurés par le disque peuvent suivre, mais pas les morceaux lointains.
        #expect(detached.count <= 4)
        let expected = detached.reduce(Float(0)) { $0 + sheet.pieces[$1].area } / sheet.totalArea
        #expect(abs(sheet.revealedFraction - expected) < 1e-5)
        #expect(sheet.revealedFraction > 0.01 && sheet.revealedFraction < 0.1)
    }

    @Test func detachAllReleasesEverythingInAWaveThenThePiecesLeave() {
        var sheet = PaperSheet(aspect: RevealEngine.cardAspect, seed: 6)
        var rng = SeededRandom(seed: 2)
        let field = makeField()
        sheet.detachAll(rng: &rng)
        // La vague prend ~0,3 s : au début, une partie seulement est partie.
        _ = sheet.step(dt: 1.0 / 60, field: field, events: [], gravity: SIMD2(0, 1), cardSize: cardSize, rng: &rng)
        #expect(sheet.attachedCount > 0)
        for _ in 0..<30 {
            _ = sheet.step(dt: 1.0 / 60, field: field, events: [], gravity: SIMD2(0, 1), cardSize: cardSize, rng: &rng)
        }
        #expect(sheet.attachedCount == 0)
        #expect(sheet.revealedFraction == 1)
        #expect(!sheet.falling.isEmpty)
        for _ in 0..<(60 * 8) {
            _ = sheet.step(dt: 1.0 / 60, field: field, events: [], gravity: SIMD2(0, 1), cardSize: cardSize, rng: &rng)
        }
        #expect(sheet.falling.isEmpty)
    }

    @Test func fallingPiecesFollowTheRealGravity() {
        for gravity in [SIMD2<Float>(0, 1), SIMD2<Float>(1, 0)] {
            var sheet = PaperSheet(aspect: RevealEngine.cardAspect, seed: 6)
            var rng = SeededRandom(seed: 2)
            var field = makeField()
            field.clear()
            _ = sheet.step(dt: 1.0 / 60, field: field, events: [], gravity: gravity, cardSize: cardSize, rng: &rng)
            let start = sheet.falling.map(\.position)
            for _ in 0..<45 {
                _ = sheet.step(dt: 1.0 / 60, field: field, events: [], gravity: gravity, cardSize: cardSize, rng: &rng)
            }
            let moved = zip(start, sheet.falling.map(\.position)).map { simd_dot($1 - $0, gravity) }
            let average = moved.reduce(0, +) / Float(moved.count)
            #expect(average > 60, "les morceaux devraient filer vers \(gravity)")
        }
    }

    @Test func shakeLaunchesPiecesInTheDirectionOfTheBlow() {
        var sheet = PaperSheet(aspect: RevealEngine.cardAspect, seed: 11)
        var rng = SeededRandom(seed: 3)
        var field = makeField()
        field.clear()
        let event = ErosionEvent(source: .shake, cells: [ErodedCell(position: SIMD2(0.5, 0.5), amount: 1)],
                                 cardSize: cardSize, direction: SIMD2(1, 0), intensity: 1)
        _ = sheet.step(dt: 1.0 / 60, field: field, events: [event], gravity: SIMD2(0, 1), cardSize: cardSize, rng: &rng)
        let averageVX = sheet.falling.map(\.velocity.x).reduce(0, +) / Float(sheet.falling.count)
        #expect(averageVX > 300)
    }

    @Test func blowSendsPiecesUpward() {
        var sheet = PaperSheet(aspect: RevealEngine.cardAspect, seed: 11)
        var rng = SeededRandom(seed: 3)
        var field = makeField()
        field.clear()
        let event = ErosionEvent(source: .blow, cells: [ErodedCell(position: SIMD2(0.5, 0.9), amount: 1)],
                                 cardSize: cardSize, direction: SIMD2(0, -1), intensity: 1)
        _ = sheet.step(dt: 1.0 / 60, field: field, events: [event], gravity: SIMD2(0, 1), cardSize: cardSize, rng: &rng)
        #expect(sheet.falling.allSatisfy { $0.velocity.y < -200 })
    }
}

@MainActor
struct PaperEngineTests {
    private func makeEngine(gesture: RevealGesture, autoFinish: Double) -> RevealEngine {
        let defaults = UserDefaults(suiteName: "PaperEngineTests-\(UUID().uuidString)")!
        let settings = RevealSettings(defaults: defaults)
        settings.autoFinishThreshold = autoFinish
        let engine = RevealEngine(settings: settings, feedback: FeedbackCenter(), mask: .paper, gesture: gesture)
        engine.cardSize = CGSize(width: 300, height: 400)
        return engine
    }

    @Test func shakingTearsOffPiecesAndRevealedFollowsThePaper() {
        let engine = makeEngine(gesture: .shake, autoFinish: 1)
        for _ in 0..<3 {
            engine.shakeImpulse(ShakeImpulse(strength: 1, direction: SIMD2(1, 0)))
            for _ in 0..<20 { engine.tick(dt: 1.0 / 60) }
        }
        #expect(engine.paper.attachedCount < engine.paper.pieces.count)
        #expect(engine.revealed == engine.paper.revealedFraction)
        #expect(engine.revealed > 0.1)
    }

    @Test func autoFinishTearsEverythingOff() {
        let engine = makeEngine(gesture: .blow, autoFinish: 0.5)
        engine.simulatedBlow = 1
        var ticks = 0
        while engine.phase == .covered, ticks < 900 { engine.tick(dt: 1.0 / 60); ticks += 1 }
        #expect(engine.phase == .finishing)
        engine.simulatedBlow = 0
        for _ in 0..<120 { engine.tick(dt: 1.0 / 60) }
        #expect(engine.phase == .revealed)
        #expect(engine.paper.attachedCount == 0)
        #expect(engine.revealed == 1)
    }
}
