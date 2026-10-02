import CoreGraphics
import Foundation
import simd

/// Un morceau arraché qui tombe : corps rigide plat, avec un retournement 3D autour d'un axe dans son plan.
struct FallingPaper: Sendable {
    /// Indice du morceau dans `PaperSheet.pieces`.
    var piece: Int
    /// Position du centroïde, en points dans le repère de la carte.
    var position: SIMD2<Float>
    var velocity: SIMD2<Float>
    /// Rotation dans le plan (radians).
    var rotation: Float
    var spin: Float
    /// Retournement autour de l'axe `flipAxis` : on dessine avec une échelle cos(flip), verso quand cos < 0.
    var flip: Float = 0
    var flipSpeed: Float
    /// Angle de l'axe de retournement, dans le repère de l'écran.
    var flipAxis: Float
    var age: Float = 0
    var gravityScale: Float
    /// Freinage de l'air par seconde, à plat face au mouvement.
    var drag: Float
    /// Intensité du vol plané latéral (feuille morte).
    var flutter: Float
    var phase: Float

    /// 0 → 1 pendant que le morceau se soulève de la photo.
    var lift: Float { smoothstep(0, 0.32, age) }
}

/// État du papier cadeau : morceaux attachés, morceaux qui tombent.
///
/// Les gestes érodent la carte de couverture ; un morceau se détache quand la couverture moyenne
/// sous lui passe sous `detachThreshold`. La carte n'est donc jamais dessinée : elle ne sert qu'à décider.
struct PaperSheet: Sendable {
    static let detachThreshold: Float = 0.55
    /// Au-delà, un morceau « tient encore » mais commence à se soulever (ombre, léger gonflement).
    static let loosenessQuantum: Float = 1.0 / 24

    let aspect: Float
    let seed: UInt32
    let pieces: [PaperPiece]
    let totalArea: Float

    private(set) var attached: [Bool]
    /// 0 = intact, 1 = sur le point de se détacher.
    private(set) var looseness: [Float]
    private(set) var falling: [FallingPaper] = []
    private(set) var revealedFraction: Float = 0

    private var detachedArea: Float = 0
    /// Arrachages programmés par `detachAll` (secondes restantes, < 0 : rien de prévu).
    private var releaseTimers: [Float]
    private var launch: Launch = .none
    private var launchAge: Float = .infinity

    init(aspect: Float, seed: UInt32) {
        self.aspect = aspect
        self.seed = seed
        pieces = PaperCutter.cut(aspect: aspect, seed: seed)
        totalArea = pieces.reduce(0) { $0 + $1.area }
        attached = Array(repeating: true, count: pieces.count)
        looseness = Array(repeating: 0, count: pieces.count)
        releaseTimers = Array(repeating: -1, count: pieces.count)
    }

    var attachedCount: Int { attached.reduce(0) { $0 + ($1 ? 1 : 0) } }

    /// Couverture moyenne de la carte sur les points de détection du morceau.
    func meanCoverage(of index: Int, in field: CoverageField) -> Float {
        let samples = pieces[index].samples
        var sum: Float = 0
        for p in samples { sum += field.sample(at: p) }
        return sum / Float(samples.count)
    }

    /// Unités de largeur de carte → points dans le repère de la carte.
    func point(_ p: SIMD2<Float>, cardSize: CGSize) -> SIMD2<Float> {
        SIMD2(p.x * Float(cardSize.width), p.y * aspect * Float(cardSize.height))
    }

    /// Morceau sous un point normalisé (0…1) : le germe le plus proche, aux dents de la déchirure près.
    func pieceIndex(atNormalized p: SIMD2<Float>) -> Int {
        let q = SIMD2(p.x, p.y / aspect)
        var best = Float.greatestFiniteMagnitude
        var bestIndex = 0
        for (i, piece) in pieces.enumerated() {
            let d = simd_distance_squared(q, piece.site)
            if d < best { best = d; bestIndex = i }
        }
        return bestIndex
    }

    // MARK: - Tick

    /// Appelé à chaque tick quand le masque papier est actif ; rend les lambeaux à émettre.
    mutating func step(dt: Float, field: CoverageField, events: [ErosionEvent], gravity: SIMD2<Float>,
                       cardSize: CGSize, rng: inout SeededRandom) -> [Particle] {
        var scraps: [Particle] = []
        launchAge += dt
        for event in events {
            launch = Launch(event)
            launchAge = 0
            if event.source == .scratch {
                scraps += crumbs(for: event, cardSize: cardSize, rng: &rng)
            }
        }
        let currentLaunch = launchAge < 0.35 ? launch : .none

        for i in pieces.indices where attached[i] {
            if releaseTimers[i] >= 0 {
                // Morceau programmé par la vague d'auto-fin : seul son minuteur décide, sinon la
                // dissolution de la carte l'arracherait en même temps que tous les autres.
                releaseTimers[i] -= dt
                if releaseTimers[i] < 0 {
                    scraps += detach(i, launch: .finish, cardSize: cardSize, rng: &rng)
                }
                continue
            }
            let mean = meanCoverage(of: i, in: field)
            if mean < Self.detachThreshold {
                scraps += detach(i, launch: currentLaunch, cardSize: cardSize, rng: &rng)
            } else {
                let loose = min(1, max(0, (1 - mean) / (1 - Self.detachThreshold)))
                if loose > looseness[i] { looseness[i] = loose }
            }
        }

        stepFalling(dt: dt, gravity: gravity, cardSize: cardSize)
        revealedFraction = attachedCount == 0 ? 1 : min(1, detachedArea / totalArea)
        return scraps
    }

    /// Auto-fin : tout ce qui reste se détache, en vague depuis le centre sur ~0,3 s.
    mutating func detachAll(rng: inout SeededRandom) {
        let center = SIMD2<Float>(0.5, 0.5 / aspect)
        let remaining = pieces.indices.filter { attached[$0] }
        let farthest = remaining.map { simd_distance(pieces[$0].centroid, center) }.max() ?? 1
        for i in remaining {
            let d = simd_distance(pieces[i].centroid, center) / max(farthest, 1e-3)
            releaseTimers[i] = 0.3 * d + Float.random(in: 0...0.06, using: &rng)
        }
        launch = .finish
        launchAge = 0
    }

    // MARK: - Détachement

    private mutating func detach(_ i: Int, launch: Launch, cardSize: CGSize, rng: inout SeededRandom) -> [Particle] {
        attached[i] = false
        looseness[i] = 1
        releaseTimers[i] = -1
        detachedArea += pieces[i].area

        let piece = pieces[i]
        let center = point(piece.centroid, cardSize: cardSize)
        let radius = piece.radius * Float(cardSize.width)
        var velocity: SIMD2<Float>
        var spin: Float
        var flipSpeed = Float.random(in: 2.2...6.5, using: &rng)

        switch launch {
        case let .scratch(fingerVelocity, finger):
            let speed = simd_length(fingerVelocity)
            let direction = speed > 1 ? fingerVelocity / speed : SIMD2(0, -1)
            velocity = direction * min(1300, 160 + speed * 0.5) + SIMD2(0, -110)
            // Le doigt tire le morceau par un point excentré : il part en tournant.
            let lever = center - finger
            let torque = (lever.x * fingerVelocity.y - lever.y * fingerVelocity.x) / max(radius * 240, 1)
            spin = min(10, max(-10, torque)) + Float.random(in: -1.5...1.5, using: &rng)
        case let .blow(intensity):
            // Soufflé vers le haut, écarté de l'axe du micro (bas-centre).
            let side = piece.centroid.x - 0.5
            velocity = SIMD2(side * Float.random(in: 700...1100, using: &rng) + Float.random(in: -120...120, using: &rng),
                             -Float.random(in: 620...1000, using: &rng) * (0.55 + 0.45 * intensity))
            spin = Float.random(in: -6...6, using: &rng)
            flipSpeed *= 1.4
        case let .shake(direction, intensity):
            velocity = direction * Float.random(in: 300...560, using: &rng) * (0.7 + 0.5 * intensity)
                + SIMD2(Float.random(in: -120...120, using: &rng), Float.random(in: -220...20, using: &rng))
            spin = Float.random(in: -9...9, using: &rng)
        case .finish:
            let cardCenter = SIMD2(Float(cardSize.width), Float(cardSize.height)) * 0.5
            let away = center - cardCenter
            let outward = simd_length(away) > 1 ? simd_normalize(away) : SIMD2(0, -1)
            velocity = outward * Float.random(in: 90...280, using: &rng) + SIMD2(0, -Float.random(in: 140...360, using: &rng))
            spin = Float.random(in: -5...5, using: &rng)
        case .none:
            velocity = SIMD2(Float.random(in: -90...90, using: &rng), -Float.random(in: 40...170, using: &rng))
            spin = Float.random(in: -3...3, using: &rng)
        }
        if rng.chance(0.5) { flipSpeed = -flipSpeed }

        falling.append(FallingPaper(
            piece: i,
            position: center,
            velocity: velocity,
            rotation: 0,
            spin: spin,
            flipSpeed: flipSpeed,
            flipAxis: Float.random(in: 0...Float.pi, using: &rng),
            gravityScale: Float.random(in: 0.85...1.1, using: &rng),
            drag: Float.random(in: 1.6...2.3, using: &rng),
            flutter: Float.random(in: 1.4...2.8, using: &rng),
            phase: Float.random(in: 0...(2 * .pi), using: &rng)
        ))
        return tearScraps(for: i, velocity: velocity, cardSize: cardSize, rng: &rng)
    }

    /// Lambeaux arrachés le long des arêtes qui tenaient encore à un voisin.
    private func tearScraps(for i: Int, velocity: SIMD2<Float>, cardSize: CGSize, rng: inout SeededRandom) -> [Particle] {
        let piece = pieces[i]
        var torn = piece.edges.filter { attached[$0.neighbor] }
        if torn.isEmpty { torn = piece.edges }
        let points = torn.flatMap(\.points)
        guard !points.isEmpty else { return [] }
        let count = min(9, 3 + torn.count * 2)
        return (0..<count).map { _ in
            let p = point(points[Int.random(in: 0..<points.count, using: &rng)], cardSize: cardSize)
            return PaperRecipe.scrap(at: p, inheriting: velocity, rng: &rng)
        }
    }

    /// Miettes de papier sous le doigt, seulement là où le papier tient encore.
    private func crumbs(for event: ErosionEvent, cardSize: CGSize, rng: inout SeededRandom) -> [Particle] {
        guard rng.chance(0.55) else { return [] }
        return rng.pick(event.cells, count: 1).compactMap { cell in
            guard attached[pieceIndex(atNormalized: cell.position)] else { return nil }
            return PaperRecipe.crumb(at: event.point(cell), fingerVelocity: event.direction, rng: &rng)
        }
    }

    // MARK: - Chute

    private mutating func stepFalling(dt: Float, gravity: SIMD2<Float>, cardSize: CGSize) {
        guard !falling.isEmpty else { return }
        let margin = Float(RevealEngine.particleMargin)
        let minX = -margin, maxX = Float(cardSize.width) + margin
        let minY = -margin, maxY = Float(cardSize.height) + margin
        let strength = simd_length(gravity)
        let down = strength > 0.01 ? gravity / strength : SIMD2<Float>(0, 1)
        let side = SIMD2(-down.y, down.x)

        var k = 0
        while k < falling.count {
            var body = falling[k]
            body.age += dt
            let faceOn = abs(cos(body.flip))
            // À plat, le papier freine beaucoup ; sur la tranche, il tombe plus vite.
            let drag = body.drag * (0.35 + 0.65 * faceOn)
            body.velocity += gravity * ParticleSystem.gravityStrength * body.gravityScale * dt
            body.velocity *= max(0, 1 - drag * dt)
            // Vol plané : le morceau incliné glisse de côté, et change de sens à chaque demi-tour.
            let sinking = max(0, simd_dot(body.velocity, down))
            body.velocity += side * sin(2 * body.flip + body.phase) * body.flutter * sinking * dt
            body.position += body.velocity * dt
            body.rotation += body.spin * dt
            body.spin *= max(0, 1 - 0.35 * dt)
            body.flip += body.flipSpeed * dt

            let r = pieces[body.piece].radius * Float(cardSize.width) * 1.1
            let gone = body.position.x + r < minX || body.position.x - r > maxX
                || body.position.y + r < minY || body.position.y - r > maxY || body.age > 9
            if gone {
                falling.remove(at: k)
            } else {
                falling[k] = body
                k += 1
            }
        }
    }
}

/// Élan donné aux morceaux qui se détachent, d'après le dernier geste.
private enum Launch: Sendable {
    case none
    /// Vitesse du doigt (pt/s) et position du doigt (pt, repère de la carte).
    case scratch(SIMD2<Float>, SIMD2<Float>)
    case blow(Float)
    case shake(SIMD2<Float>, Float)
    case finish

    init(_ event: ErosionEvent) {
        switch event.source {
        case .scratch:
            var center = SIMD2<Float>.zero
            for cell in event.cells { center += event.point(cell) }
            self = .scratch(event.direction, center / Float(max(1, event.cells.count)))
        case .blow:
            self = .blow(event.intensity)
        case .shake:
            let length = simd_length(event.direction)
            self = .shake(length > 0.01 ? event.direction / length : SIMD2(0, 1), event.intensity)
        case .finish:
            self = .finish
        }
    }
}
