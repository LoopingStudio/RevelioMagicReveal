import CoreGraphics
import Foundation
import SwiftUI
import simd

/// Variante d'un `.goldFlake`, codée dans `hue` (champ libre de la famille).
enum GoldPiece: Int, CaseIterable, Sendable {
    /// Copeau arraché par le doigt.
    case crumb
    /// Paillette fine qui scintille.
    case glitter
    /// Morceau de feuille qui se retourne en tombant.
    case leaf

    var hue: Float { (Float(rawValue) + 0.5) / Float(Self.allCases.count) }

    init(hue: Float) {
        let index = Int((hue * Float(Self.allCases.count)).rounded(.down))
        self = GoldPiece(rawValue: min(max(index, 0), Self.allCases.count - 1)) ?? .crumb
    }
}

enum GoldRecipe: ParticleRecipe {
    static func particles(for event: ErosionEvent, rng: inout SeededRandom) -> [Particle] {
        switch event.source {
        case .scratch: scratch(event, &rng)
        case .blow: blow(event, &rng)
        case .shake: shake(event, &rng)
        case .finish: finish(event, &rng)
        }
    }

    /// Nombre de particules : proportionnel à la quantité érodée, au moins une, plafonné.
    static func count(for amount: Float, perUnit: Float, cap: Int) -> Int {
        guard amount > 0 else { return 0 }
        return min(cap, Int(amount * perUnit) + 1)
    }

    /// Copeaux et petites spirales arrachés par le doigt, qui tombent avec la gravité.
    private static func scratch(_ event: ErosionEvent, _ rng: inout SeededRandom) -> [Particle] {
        let n = count(for: event.totalAmount, perUnit: 0.45, cap: 6)
        let push = event.direction * 0.09
        return rng.pick(event.cells, count: n).map { cell in
            let curl = rng.chance(0.28)
            let life = rng.float(0.8...1.5)
            return Particle(
                kind: curl ? .goldCurl : .goldFlake,
                position: event.point(cell) + SIMD2(rng.float(-4...4), rng.float(-4...4)),
                velocity: push + SIMD2(rng.float(-70...70), rng.float(-130 ... -10)),
                size: curl ? rng.float(3...5.5) : rng.float(1.1...2.7),
                rotation: rng.float(0...6.28),
                spin: curl ? rng.float(-9...9) : rng.float(-14...14),
                flip: rng.float(0...6.28),
                flipSpeed: curl ? 0 : rng.float(5...15),
                life: life, maxLife: life,
                gravityScale: curl ? 0.95 : 0.85,
                drag: curl ? 0.9 : 1.3,
                hue: GoldPiece.crumb.hue,
                seed: rng.float(0...1)
            )
        }
    }

    /// Paillettes qui s'envolent vers le haut, puis retombent en scintillant.
    private static func blow(_ event: ErosionEvent, _ rng: inout SeededRandom) -> [Particle] {
        let n = count(for: event.totalAmount, perUnit: 0.5, cap: 16)
        let lift = 0.6 + 0.4 * event.intensity
        return rng.pick(event.cells, count: n).map { cell in
            let bit = rng.chance(0.18)
            let life = rng.float(1.5...2.4)
            return Particle(
                kind: .goldFlake,
                position: event.point(cell),
                velocity: SIMD2(rng.float(-170...170), rng.float(-760 ... -320) * lift),
                size: bit ? rng.float(2.2...4) : rng.float(0.9...2.1),
                rotation: rng.float(0...6.28),
                spin: rng.float(-6...6),
                flip: rng.float(0...6.28),
                flipSpeed: rng.float(7...18),
                life: life, maxLife: life,
                gravityScale: 0.34,
                drag: 1.25,
                wobble: rng.float(0.6...1.8),
                hue: bit ? GoldPiece.leaf.hue : GoldPiece.glitter.hue,
                seed: rng.float(0...1)
            )
        }
    }

    /// Gros morceaux de feuille projetés dans le sens de la secousse, qui se retournent en tombant.
    private static func shake(_ event: ErosionEvent, _ rng: inout SeededRandom) -> [Particle] {
        let n = count(for: event.totalAmount, perUnit: 0.12, cap: 12)
        let kick = event.direction * 240 * (0.5 + event.intensity)
        return rng.pick(event.cells, count: n).map { cell in
            let leaf = rng.chance(0.7)
            let life = rng.float(1.5...2.3)
            return Particle(
                kind: leaf ? .goldFlake : (rng.chance(0.5) ? .goldCurl : .goldFlake),
                position: event.point(cell),
                velocity: kick + SIMD2(rng.float(-90...90), rng.float(-150...30)),
                size: leaf ? rng.float(8...19) : rng.float(1.4...3),
                rotation: rng.float(0...6.28),
                spin: leaf ? rng.float(-4...4) : rng.float(-12...12),
                flip: rng.float(0...6.28),
                flipSpeed: leaf ? rng.float(2.5...7) : rng.float(6...14),
                life: life, maxLife: life,
                gravityScale: leaf ? 0.9 : 1,
                drag: leaf ? 0.8 : 0.5,
                wobble: leaf ? rng.float(0.3...0.9) : 0,
                hue: leaf ? GoldPiece.leaf.hue : GoldPiece.crumb.hue,
                seed: rng.float(0...1)
            )
        }
    }

    /// Fin : la feuille restante part en paillettes scintillantes.
    private static func finish(_ event: ErosionEvent, _ rng: inout SeededRandom) -> [Particle] {
        let n = count(for: event.totalAmount, perUnit: 0.22, cap: 22)
        return rng.pick(event.cells, count: n).map { cell in
            let crumb = rng.chance(0.25)
            let life = rng.float(1.0...1.9)
            return Particle(
                kind: .goldFlake,
                position: event.point(cell),
                velocity: SIMD2(rng.float(-140...140), rng.float(-260 ... -40)),
                size: crumb ? rng.float(1.2...2.4) : rng.float(1.1...2.6),
                rotation: rng.float(0...6.28),
                spin: rng.float(-5...5),
                flip: rng.float(0...6.28),
                flipSpeed: rng.float(6...16),
                life: life, maxLife: life,
                gravityScale: crumb ? 0.7 : 0.16,
                drag: 1.4,
                wobble: crumb ? 0 : 1.2,
                hue: crumb ? GoldPiece.crumb.hue : GoldPiece.glitter.hue,
                seed: rng.float(0...1)
            )
        }
    }
}

enum GoldArt {
    /// Décalage de l'ombre portée d'un copeau sur la feuille (lumière en haut à gauche).
    private static let shadowOffset = CGSize(width: 0.7, height: 1.1)

    static func draw(_ p: Particle, in context: inout GraphicsContext) {
        let fade = Double(min(1, p.lifeFraction * 3))
        let s = CGFloat(p.size)
        let light = shine(rotation: p.rotation, flip: p.flip, seed: p.seed)
        let piece = p.kind == .goldCurl ? nil : GoldPiece(hue: p.hue)
        // Les gros morceaux volent plus haut : ombre plus décalée et plus douce.
        let lift: CGFloat = piece == .leaf ? 2.2 : 1

        var shadow = context
        shadow.translateBy(x: CGFloat(p.position.x) + shadowOffset.width * lift,
                           y: CGFloat(p.position.y) + shadowOffset.height * lift)
        shadow.rotate(by: .radians(Double(p.rotation)))
        var c = context
        c.translateBy(x: CGFloat(p.position.x), y: CGFloat(p.position.y))
        c.rotate(by: .radians(Double(p.rotation)))

        let shadowShading = GraphicsContext.Shading.color(.black.opacity(fade * (piece == .leaf ? 0.22 : 0.32)))
        switch piece {
        case nil:
            let shape = GoldShapes.curls[Int(p.seed * 997) % GoldShapes.curls.count]
            shadow.scaleBy(x: s, y: s)
            shadow.fill(shape, with: shadowShading)
            drawCurl(p, shape: shape, size: s, light: light, fade: fade, in: &c)
        case .crumb?:
            let shape = GoldShapes.crumbs[Int(p.seed * 997) % GoldShapes.crumbs.count]
            let squash = s * max(0.2, CGFloat(abs(cos(p.flip))))
            shadow.scaleBy(x: s, y: squash)
            shadow.fill(shape, with: shadowShading)
            c.scaleBy(x: s, y: squash)
            c.fill(shape, with: .color(goldColor(0.42 + light * 0.8).opacity(fade)))
        case .glitter?:
            drawGlitter(p, size: s, light: light, fade: fade, in: &c)
        case .leaf?:
            let shape = GoldShapes.leaves[Int(p.seed * 997) % GoldShapes.leaves.count]
            let face = CGFloat(cos(p.flip))
            shadow.scaleBy(x: s, y: s * max(0.08, abs(face)))
            shadow.fill(shape, with: shadowShading)
            drawLeaf(p, shape: shape, face: face, size: s, light: light, fade: fade, in: &c)
        }
    }

    /// Éclat (0…1) d'un copeau plat. Sa normale dépend de son inclinaison propre, du retournement
    /// et de la rotation : il s'allume quand elle renvoie la lumière (en haut à gauche) vers l'œil.
    static func shine(rotation: Float, flip: Float, seed: Float) -> Float {
        let tilt = 0.3 + 0.55 * seed + flip
        let axis = rotation + seed * 6.283
        let normal = SIMD3(sin(tilt) * cos(axis), sin(tilt) * sin(axis), abs(cos(tilt)))
        let halfway = simd_normalize(SIMD3<Float>(-0.2, -0.32, 1))
        let d = max(0, simd_dot(normal, halfway))
        return min(1, 0.12 + 0.88 * pow(d, 7))
    }

    /// Même rampe que le shader (`gold_ramp`) : de l'ombre profonde à l'éclat doré.
    static let rampStops: [(Float, SIMD3<Float>)] = [
        (0, SIMD3(0.13, 0.065, 0.015)),
        (0.25, SIMD3(0.42, 0.25, 0.065)),
        (0.55, SIMD3(0.78, 0.56, 0.20)),
        (0.92, SIMD3(0.96, 0.79, 0.42)),
        (1.3, SIMD3(1.00, 0.93, 0.68)),
    ]

    static func goldRGB(_ x: Float) -> SIMD3<Float> {
        let stops = rampStops
        let v = min(max(x, 0), stops[stops.count - 1].0)
        for i in 1..<stops.count where v <= stops[i].0 {
            let (x0, c0) = stops[i - 1]
            let (x1, c1) = stops[i]
            return simd_mix(c0, c1, SIMD3(repeating: (v - x0) / (x1 - x0)))
        }
        return stops[stops.count - 1].1
    }

    static func goldColor(_ x: Float) -> Color {
        let rgb = goldRGB(x)
        return Color(red: Double(rgb.x), green: Double(rgb.y), blue: Double(rgb.z))
    }

    private static func drawGlitter(_ p: Particle, size s: CGFloat, light: Float, fade: Double, in c: inout GraphicsContext) {
        let squash = CGFloat(abs(cos(p.flip)))
        var body = c
        body.scaleBy(x: s, y: s * max(0.25, squash))
        body.fill(GoldShapes.rhombus, with: .color(goldColor(0.45 + light * 0.85).opacity(fade)))
        // Éclair en étoile quand la paillette renvoie la lumière.
        let flash = max(0, (light - 0.62) / 0.38)
        guard flash > 0 else { return }
        var glow = c
        glow.blendMode = .plusLighter
        glow.rotate(by: .radians(Double(-p.rotation)))
        glow.fill(GoldShapes.sparkle(radius: s * (1.6 + 2.6 * CGFloat(flash))),
                  with: .color(Color(red: 1, green: 0.93, blue: 0.7).opacity(fade * Double(flash) * 0.9)))
    }

    /// Morceau de feuille : recto or, verso or champagne, tous deux métalliques ; un reflet le
    /// traverse selon son orientation et un pli net le casse en deux facettes.
    private static func drawLeaf(_ p: Particle, shape: Path, face: CGFloat, size s: CGFloat, light: Float, fade: Double,
                                 in c: inout GraphicsContext) {
        c.scaleBy(x: s, y: s * max(0.08, abs(face)))
        let front = face >= 0
        // Le verso tire vers le champagne : on décale la rampe et on désature un peu.
        func tone(_ x: Float) -> Color {
            guard !front else { return goldColor(x) }
            let rgb = simd_mix(goldRGB(x + 0.06), SIMD3(repeating: simd_reduce_add(goldRGB(x + 0.06)) / 3), SIMD3(repeating: 0.18))
            return Color(red: Double(rgb.x), green: Double(rgb.y), blue: Double(rgb.z))
        }
        // Bande de reflet étroite qui glisse sur la feuille : c'est elle qui fait « métal ».
        let sweep = CGFloat(0.5 + 0.32 * sin(p.flip * 1.3 + p.rotation))
        let gradient = Gradient(stops: [
            .init(color: tone(0.2 + light * 0.3).opacity(fade), location: 0),
            .init(color: tone(0.42 + light * 0.4).opacity(fade), location: sweep - 0.16),
            .init(color: tone(0.85 + light * 0.45).opacity(fade), location: sweep),
            .init(color: tone(0.45 + light * 0.35).opacity(fade), location: sweep + 0.12),
            .init(color: tone(0.24 + light * 0.3).opacity(fade), location: 1),
        ])
        c.fill(shape, with: .linearGradient(gradient, startPoint: CGPoint(x: -1, y: -1), endPoint: CGPoint(x: 1, y: 1)))

        // Pli : la seconde facette est un peu plus sombre, avec une arête franche.
        let angle = Double(p.seed) * 6.283
        let axis = CGPoint(x: cos(angle), y: sin(angle))
        let foldAt = 0.35 + 0.3 * CGFloat(p.seed)
        let crease = Gradient(stops: [
            .init(color: .black.opacity(0), location: 0),
            .init(color: .black.opacity(0), location: foldAt),
            .init(color: .black.opacity(0.28 * fade), location: foldAt),
            .init(color: .black.opacity(0.1 * fade), location: 1),
        ])
        c.fill(shape, with: .linearGradient(crease, startPoint: CGPoint(x: -axis.x, y: -axis.y), endPoint: axis))
        c.stroke(shape, with: .color(tone(1.0 + light * 0.3).opacity(fade * 0.7)), lineWidth: 0.55 / s)
    }

    /// Copeau en ruban vrillé : chaque tour de l'hélice passe de l'ombre à l'éclat, et la bande
    /// claire glisse le long du ruban quand il tourne.
    private static func drawCurl(_ p: Particle, shape: Path, size s: CGFloat, light: Float, fade: Double,
                                 in c: inout GraphicsContext) {
        c.scaleBy(x: s, y: s)
        let phase = CGFloat(0.5 + 0.5 * sin(p.rotation * 1.7 + p.seed * 9))
        let dark = goldColor(0.32 + light * 0.25).opacity(fade)
        let bright = goldColor(0.85 + light * 0.45).opacity(fade)
        let mid = goldColor(0.52 + light * 0.35).opacity(fade)
        let gradient = Gradient(stops: [
            .init(color: dark, location: 0),
            .init(color: bright, location: 0.1 + 0.25 * phase),
            .init(color: mid, location: 0.5),
            .init(color: bright, location: 0.6 + 0.25 * phase),
            .init(color: dark, location: 1),
        ])
        c.fill(shape, with: .linearGradient(gradient, startPoint: CGPoint(x: -1, y: -0.2), endPoint: CGPoint(x: 1, y: 0.2)))
    }
}

/// Formes unitaires des particules, calculées une fois.
extension GoldShapes {
    static let crumbs: [Path] = (0..<6).map { polygon(sides: 5, jitter: 0.4, seed: Double($0) * 3.1) }
    static let leaves: [Path] = (0..<6).map { tornPolygon(sides: 7, seed: Double($0) * 5.7 + 1) }
    static let rhombus: Path = {
        var path = Path()
        path.move(to: CGPoint(x: 0, y: -1))
        path.addLine(to: CGPoint(x: 0.6, y: 0))
        path.addLine(to: CGPoint(x: 0, y: 1))
        path.addLine(to: CGPoint(x: -0.6, y: 0))
        path.closeSubpath()
        return path
    }()
    /// Spirale d'Archimède de 1,7 tour, du centre vers le rayon 1.
    static let curls: [Path] = [(1.3, 0.55), (1.7, 0.45), (1.1, 0.6)].map { curlRibbon(turns: $0.0, radius: $0.1) }

    /// Ruban de copeau : hélice vue de côté (un ressort étiré), effilée aux deux bouts.
    static func curlRibbon(turns: Double, radius: Double) -> Path {
        let steps = 40
        var centers: [CGPoint] = []
        var widths: [Double] = []
        for i in 0...steps {
            let t = Double(i) / Double(steps)
            let angle = t * turns * 2 * .pi
            centers.append(CGPoint(x: -0.85 + 1.7 * t + radius * 0.75 * cos(angle), y: radius * sin(angle)))
            widths.append(0.05 + 0.22 * pow(sin(.pi * t), 0.7))
        }
        var left: [CGPoint] = [], right: [CGPoint] = []
        for i in 0...steps {
            let a = centers[max(0, i - 1)], b = centers[min(steps, i + 1)]
            let dx = b.x - a.x, dy = b.y - a.y
            let length = max(1e-6, (dx * dx + dy * dy).squareRoot())
            let nx = -dy / length * widths[i] / 2, ny = dx / length * widths[i] / 2
            left.append(CGPoint(x: centers[i].x + nx, y: centers[i].y + ny))
            right.append(CGPoint(x: centers[i].x - nx, y: centers[i].y - ny))
        }
        var path = Path()
        path.addLines(left + right.reversed())
        path.closeSubpath()
        return path
    }

    static func polygon(sides: Int, jitter: Double, seed: Double) -> Path {
        var path = Path()
        for i in 0..<sides {
            let a = (Double(i) + (GoldTicketLayout.hash(seed + Double(i)) - 0.5) * 0.6) / Double(sides) * 2 * .pi
            let r = 1 - jitter * GoldTicketLayout.hash(seed * 1.7 + Double(i) * 2.3)
            let point = CGPoint(x: cos(a) * r, y: sin(a) * r)
            if i == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        path.closeSubpath()
        return path
    }

    /// Polygone aux bords déchirés : un point creusé ou saillant entre chaque sommet.
    static func tornPolygon(sides: Int, seed: Double) -> Path {
        var path = Path()
        var points: [CGPoint] = []
        for i in 0..<sides {
            let a = (Double(i) + (GoldTicketLayout.hash(seed + Double(i)) - 0.5) * 0.5) / Double(sides) * 2 * .pi
            let r = 0.72 + 0.28 * GoldTicketLayout.hash(seed * 2.1 + Double(i) * 1.3)
            points.append(CGPoint(x: cos(a) * r, y: sin(a) * r))
        }
        for i in 0..<sides {
            let p0 = points[i], p1 = points[(i + 1) % sides]
            let dent = 0.82 + 0.3 * GoldTicketLayout.hash(seed * 3.3 + Double(i) * 0.7)
            let mid = CGPoint(x: (p0.x + p1.x) / 2 * dent, y: (p0.y + p1.y) / 2 * dent)
            if i == 0 { path.move(to: p0) } else { path.addLine(to: p0) }
            path.addLine(to: mid)
        }
        path.closeSubpath()
        return path
    }
}
