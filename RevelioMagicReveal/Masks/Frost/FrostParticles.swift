import CoreGraphics
import Foundation
import SwiftUI
import simd

/// Particules du givre : poudre raclée (gratter), gouttelettes et buée (souffler), éclats de glace (secouer).
enum FrostRecipe: ParticleRecipe {
    static func particles(for event: ErosionEvent, rng: inout SeededRandom) -> [Particle] {
        guard !event.cells.isEmpty, event.totalAmount > 0 else { return [] }
        switch event.source {
        case .scratch: return scratch(event, &rng)
        case .blow: return blow(event, &rng)
        case .shake: return shake(event, &rng)
        case .finish: return finish(event, &rng)
        }
    }

    /// Arrondi aléatoire : pour 2,3 attendus on émet 2 ou 3 (3 une fois sur trois environ), plafonné à `cap`.
    /// Garde un débit juste même quand chaque image n'érode qu'un peu (souffle).
    static func count(expected: Float, cap: Int, rng: inout SeededRandom) -> Int {
        guard expected > 0, cap > 0 else { return 0 }
        let clamped = min(expected, Float(cap))
        let whole = Int(clamped)
        let extra = rng.chance(clamped - Float(whole)) ? 1 : 0
        return min(cap, whole + extra)
    }

    /// Gratter : poudre de givre raclée, poussée par le doigt, et quelques copeaux qui scintillent en tombant.
    private static func scratch(_ event: ErosionEvent, _ rng: inout SeededRandom) -> [Particle] {
        let n = count(expected: event.totalAmount * 0.8 + 0.5, cap: 10, rng: &rng)
        let push = event.direction * 0.08
        return rng.pick(event.cells, count: n).map { cell in
            let jitter = SIMD2(rng.float(-4...4), rng.float(-4...4))
            return powder(at: event.point(cell) + jitter, push: push, shavingChance: 0.22, rng: &rng)
        }
    }

    /// Souffler : la glace fond, des gouttelettes glissent lentement sur la vitre dégagée ; un peu de buée.
    private static func blow(_ event: ErosionEvent, _ rng: inout SeededRandom) -> [Particle] {
        let pane = SIMD2(Float(event.cardSize.width), Float(event.cardSize.height))
        var result: [Particle] = []

        let drops = count(expected: event.totalAmount * 0.005, cap: 3, rng: &rng)
        for cell in rng.pick(event.cells, count: drops) {
            let size = rng.chance(0.3) ? rng.float(3.0...4.6) : rng.float(1.4...3.0)
            let life = rng.float(2.4...4.2)
            result.append(Particle(
                kind: .droplet,
                position: event.point(cell) + SIMD2(rng.float(-3...3), rng.float(-3...3)),
                velocity: SIMD2(rng.float(-3...3), rng.float(0...8)),
                size: size,
                rotation: pane.x, spin: 0, flip: pane.y, flipSpeed: 0,
                life: life, maxLife: life,
                // Les grosses gouttes glissent plus vite (≈ 20 à 40 pt/s une fois lancées).
                gravityScale: 0.012 + 0.004 * size,
                drag: 1.3,
                wobble: rng.float(0.05...0.25),
                seed: rng.float(0...1)
            ))
        }

        let puffs = count(expected: event.totalAmount * 0.0025 * (0.4 + event.intensity), cap: 2, rng: &rng)
        for cell in rng.pick(event.cells, count: puffs) {
            let life = rng.float(1.1...1.9)
            result.append(Particle(
                kind: .frostDust,
                position: event.point(cell),
                velocity: SIMD2(rng.float(-10...10), rng.float(-26 ... -8)),
                size: rng.float(16...30),
                rotation: pane.x, spin: 0, flip: pane.y, flipSpeed: 0,
                life: life, maxLife: life,
                gravityScale: 0,
                drag: 0.8,
                hue: FrostArt.mistHue,
                seed: rng.float(0...1)
            ))
        }
        return result
    }

    /// Secouer : des plaques de givre se détachent en éclats translucides qui tournoient, avec de la poudre.
    private static func shake(_ event: ErosionEvent, _ rng: inout SeededRandom) -> [Particle] {
        let kick = event.direction * 250 * (0.5 + event.intensity)
        var result: [Particle] = []
        let shards = count(expected: event.totalAmount * 0.03 + 0.5, cap: 8, rng: &rng)
        for cell in rng.pick(event.cells, count: shards) {
            result.append(shard(at: event.point(cell), kick: kick, rng: &rng))
        }
        let dust = count(expected: event.totalAmount * 0.06, cap: 14, rng: &rng)
        for cell in rng.pick(event.cells, count: dust) {
            result.append(powder(at: event.point(cell), push: kick * 0.5, shavingChance: 0.3, rng: &rng))
        }
        return result
    }

    /// Fin : le givre restant part en poudre, avec quelques éclats.
    private static func finish(_ event: ErosionEvent, _ rng: inout SeededRandom) -> [Particle] {
        var result: [Particle] = []
        let dust = count(expected: event.totalAmount * 0.02 + 0.5, cap: 7, rng: &rng)
        for cell in rng.pick(event.cells, count: dust) {
            result.append(powder(at: event.point(cell), push: SIMD2(0, -40), shavingChance: 0.25, rng: &rng))
        }
        let shards = count(expected: event.totalAmount * 0.004, cap: 2, rng: &rng)
        for cell in rng.pick(event.cells, count: shards) {
            result.append(shard(at: event.point(cell), kick: SIMD2(rng.float(-120...120), -60), rng: &rng))
        }
        return result
    }

    private static func powder(at point: SIMD2<Float>, push: SIMD2<Float>, shavingChance: Float,
                               rng: inout SeededRandom) -> Particle {
        let shaving = rng.chance(shavingChance)
        let life = rng.float(0.45...0.95)
        return Particle(
            kind: .frostDust,
            position: point,
            velocity: push + SIMD2(rng.float(-60...60), rng.float(-120 ... -10)),
            size: shaving ? rng.float(1.6...2.8) : rng.float(0.5...1.4),
            rotation: rng.float(0...6.28),
            spin: rng.float(-8...8),
            flip: rng.float(0...6.28),
            flipSpeed: rng.float(7...16),
            life: life, maxLife: life,
            gravityScale: shaving ? 0.75 : 0.28,
            drag: shaving ? 0.9 : 2.6,
            hue: FrostArt.powderHue,
            seed: rng.float(0...1)
        )
    }

    private static func shard(at point: SIMD2<Float>, kick: SIMD2<Float>, rng: inout SeededRandom) -> Particle {
        let big = rng.chance(0.3)
        let life = rng.float(1.3...2.1)
        return Particle(
            kind: .shard,
            position: point,
            velocity: kick + SIMD2(rng.float(-90...90), rng.float(-160...30)),
            size: big ? rng.float(8...13) : rng.float(3...8),
            rotation: rng.float(0...6.28),
            spin: rng.float(-7...7),
            flip: rng.float(0...6.28),
            flipSpeed: rng.float(3...9) * (rng.chance(0.5) ? 1 : -1),
            life: life, maxLife: life,
            gravityScale: rng.float(0.85...1),
            drag: big ? 0.25 : 0.45,
            hue: rng.float(0...1),
            seed: rng.float(0...1)
        )
    }
}

extension Particle {
    /// Gouttes et buée restent sur la vitre : la recette range la taille de la carte dans `rotation` et `flip`
    /// (leurs `spin` et `flipSpeed` sont nuls, ces valeurs ne bougent donc pas) pour qu'on puisse les rogner au dessin.
    var frostPane: CGRect {
        CGRect(x: 0, y: 0, width: CGFloat(rotation), height: CGFloat(flip))
    }
}

enum FrostArt {
    /// `hue` d'une particule `.frostDust` : poudre (et copeaux) ou nappe de buée.
    static let powderHue: Float = 0
    static let mistHue: Float = 1

    private static let ice = Color(red: 0.93, green: 0.97, blue: 1.0)
    private static let deepIce = Color(red: 0.62, green: 0.79, blue: 0.95)

    static func draw(_ p: Particle, in context: inout GraphicsContext) {
        switch p.kind {
        case .frostDust:
            if p.hue >= 0.5 { drawMist(p, in: &context) } else { drawPowder(p, in: &context) }
        case .droplet: drawDroplet(p, in: &context)
        case .shard: drawShard(p, in: &context)
        default: break
        }
    }

    // MARK: Poudre

    private static func drawPowder(_ p: Particle, in context: inout GraphicsContext) {
        let fade = Double(min(1, p.lifeFraction * 2.5))
        let s = CGFloat(p.size)
        let center = CGPoint(x: CGFloat(p.position.x), y: CGFloat(p.position.y))
        // La poussière de glace accroche la lumière en tournant.
        let glint = pow(max(0, cos(Double(p.flip))), 14)
        if s < 1.5 {
            let r = CGRect(x: center.x - s / 2, y: center.y - s / 2, width: s, height: s)
            context.fill(Path(ellipseIn: r), with: .color(.white.opacity((0.6 + 0.4 * glint) * fade)))
        } else {
            // Copeau : petite plaque irrégulière qui tourne et bascule.
            var c = context
            c.translateBy(x: center.x, y: center.y)
            c.rotate(by: .radians(Double(p.rotation)))
            c.scaleBy(x: 1, y: max(0.25, abs(cos(Double(p.flip) * 0.5))))
            c.fill(shardPath(size: s, seed: p.seed, vertices: 5), with: .color(ice.opacity((0.75 + 0.25 * glint) * fade)))
        }
        if glint > 0.4, p.seed > 0.55 {
            let k = (glint - 0.4) / 0.6
            var c = context
            c.translateBy(x: center.x, y: center.y)
            c.fill(glintPath(radius: s * 2.6 + 1.5), with: .color(.white.opacity(0.85 * k * fade)))
        }
    }

    // MARK: Buée

    private static func drawMist(_ p: Particle, in context: inout GraphicsContext) {
        let t = Double(1 - p.lifeFraction)
        let alpha = min(1, t * 5) * min(1, Double(p.lifeFraction) * 1.6)
        guard alpha > 0.01 else { return }
        let r = CGFloat(p.size) * CGFloat(1 + t * 0.6)
        let center = CGPoint(x: CGFloat(p.position.x), y: CGFloat(p.position.y))
        var c = context
        c.clip(to: Path(roundedRect: p.frostPane, cornerRadius: 5))
        let rect = CGRect(x: center.x - r * 1.3, y: center.y - r, width: r * 2.6, height: r * 2)
        let gradient = Gradient(colors: [.white.opacity(0.13 * alpha), .white.opacity(0.06 * alpha), .white.opacity(0)])
        c.fill(Path(ellipseIn: rect), with: .radialGradient(gradient, center: center, startRadius: 0, endRadius: r * 1.3))
    }

    // MARK: Gouttelettes

    private static func drawDroplet(_ p: Particle, in context: inout GraphicsContext) {
        let appear = min(1, Double(p.age) * 5)
        let fade = min(1, Double(p.lifeFraction) * 3) * appear
        guard fade > 0.01 else { return }
        var c = context
        c.clip(to: Path(roundedRect: p.frostPane, cornerRadius: 5))
        c.translateBy(x: CGFloat(p.position.x), y: CGFloat(p.position.y))

        // La goutte grossit en se formant puis s'étire dans le sens de sa glissade.
        let r = CGFloat(p.size) * CGFloat(0.6 + 0.4 * appear)
        let speed = simd_length(p.velocity)
        let direction = speed > 1 ? p.velocity / speed : SIMD2<Float>(0, 1)
        let stretch = 1 + min(CGFloat(speed) / 90, 0.3)

        var body = c
        body.rotate(by: .radians(Double(atan2(direction.y, direction.x)) - .pi / 2))
        // Traînée humide laissée derrière la goutte : à peine visible, elle s'efface vers le haut.
        let trail = CGFloat(min(p.age * speed * 0.8, 46))
        if trail > 2 {
            let rect = CGRect(x: -r * 0.5, y: -trail, width: r, height: trail)
            body.fill(Path(roundedRect: rect, cornerRadius: r * 0.5),
                      with: .linearGradient(Gradient(colors: [.white.opacity(0), .white.opacity(0.05 * fade)]),
                                            startPoint: CGPoint(x: 0, y: -trail), endPoint: .zero))
        }
        // Corps : lentille d'eau, cœur presque clair, bord sombre net (il reflète l'extérieur sombre).
        let shape = Path(ellipseIn: CGRect(x: -r, y: -r * (2 * stretch - 1), width: r * 2, height: r * 2 * stretch))
        body.fill(shape, with: .radialGradient(
            Gradient(stops: [
                .init(color: .white.opacity(0.06 * fade), location: 0),
                .init(color: .black.opacity(0.02 * fade), location: 0.55),
                .init(color: .black.opacity(0.22 * fade), location: 0.85),
                .init(color: .black.opacity(0.45 * fade), location: 1),
            ]),
            center: CGPoint(x: 0, y: -r * (stretch - 1)), startRadius: 0, endRadius: r * stretch))

        // Lumière (repère de l'écran) : reflet net en haut à gauche, croissant de lumière concentrée en bas.
        let caustic = Path { path in
            path.addArc(center: .zero, radius: r * 0.72, startAngle: .degrees(35), endAngle: .degrees(145), clockwise: false)
        }
        c.stroke(caustic, with: .color(.white.opacity(0.32 * fade)), style: StrokeStyle(lineWidth: max(0.6, r * 0.22), lineCap: .round))
        let highlight = CGRect(x: -r * 0.62, y: -r * 0.66, width: r * 0.48, height: r * 0.32)
        c.fill(Path(ellipseIn: highlight), with: .color(.white.opacity(0.9 * fade)))
        let spark = CGRect(x: r * 0.18, y: -r * 0.5, width: r * 0.14, height: r * 0.14)
        c.fill(Path(ellipseIn: spark), with: .color(.white.opacity(0.6 * fade)))
    }

    // MARK: Éclats

    private static func drawShard(_ p: Particle, in context: inout GraphicsContext) {
        let fade = Double(min(1, p.lifeFraction * 3))
        let s = CGFloat(p.size)
        var c = context
        c.translateBy(x: CGFloat(p.position.x), y: CGFloat(p.position.y))
        c.rotate(by: .radians(Double(p.rotation)))
        let tilt = cos(Double(p.flip))
        c.scaleBy(x: 1, y: max(0.1, abs(tilt)))

        let outline = shardPath(size: s, seed: p.seed, vertices: 6)
        if tilt >= 0 {
            // Face givrée : croûte blanche mate, un peu plus bleutée vers le bas.
            c.fill(outline, with: .linearGradient(
                Gradient(colors: [Color.white.opacity(0.92 * fade), ice.opacity(0.78 * fade)]),
                startPoint: CGPoint(x: -s, y: -s), endPoint: CGPoint(x: s, y: s)))
            c.fill(shardPath(size: s * 0.55, seed: p.seed + 0.37, vertices: 5), with: .color(.white.opacity(0.5 * fade)))
            c.stroke(outline, with: .color(deepIce.opacity(0.45 * fade)), lineWidth: 0.5)
        } else {
            // Revers : glace claire, translucide, arêtes vives.
            c.fill(outline, with: .linearGradient(
                Gradient(colors: [ice.opacity(0.5 * fade), deepIce.opacity((0.25 + 0.1 * Double(p.hue)) * fade)]),
                startPoint: CGPoint(x: -s, y: -s), endPoint: CGPoint(x: s, y: s)))
            c.stroke(outline, with: .color(.white.opacity(0.75 * fade)), lineWidth: 0.6)
        }

        // Éclat quand la face renvoie la lumière vers l'œil.
        let glint = pow(abs(tilt), 12) * pow(max(0, cos(Double(p.rotation) + Double(p.seed) * 6.28)), 6)
        if glint > 0.02 {
            c.fill(outline, with: .color(.white.opacity(0.6 * glint * fade)))
        }
    }

    // MARK: Formes

    /// Polygone irrégulier, toujours le même pour une graine donnée.
    static func shardPath(size s: CGFloat, seed: Float, vertices n: Int) -> Path {
        var rng = SeededRandom(seed: UInt32(truncatingIfNeeded: Int(seed * 1_000_003)))
        let elongation = CGFloat(Float.random(in: 1...1.7, using: &rng))
        var path = Path()
        for i in 0..<n {
            let a = (Double(i) + Double(Float.random(in: -0.3...0.3, using: &rng))) / Double(n) * 2 * .pi
            let radius = s * CGFloat(Float.random(in: 0.55...1, using: &rng))
            let point = CGPoint(x: CGFloat(cos(a)) * radius * elongation, y: CGFloat(sin(a)) * radius / elongation)
            if i == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        path.closeSubpath()
        return path
    }

    /// Étincelle fine à quatre branches.
    static func glintPath(radius r: CGFloat) -> Path {
        let k = r * 0.13
        var path = Path()
        path.move(to: CGPoint(x: 0, y: -r))
        path.addLine(to: CGPoint(x: k, y: -k))
        path.addLine(to: CGPoint(x: r, y: 0))
        path.addLine(to: CGPoint(x: k, y: k))
        path.addLine(to: CGPoint(x: 0, y: r))
        path.addLine(to: CGPoint(x: -k, y: k))
        path.addLine(to: CGPoint(x: -r, y: 0))
        path.addLine(to: CGPoint(x: -k, y: -k))
        path.closeSubpath()
        return path
    }
}
