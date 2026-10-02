import SwiftUI
import simd

/// Gerbe de fin : confettis de Noël, étoiles et paillettes dorées qui jaillissent de la photo.
enum CelebrationRecipe {
    static let palette: [Color] = [
        Color(red: 0.80, green: 0.08, blue: 0.16),
        Color(red: 0.10, green: 0.50, blue: 0.26),
        Color(red: 0.93, green: 0.74, blue: 0.32),
        Color(red: 0.98, green: 0.97, blue: 0.94),
    ]

    static func burst(cardSize: CGSize, rng: inout SeededRandom) -> [Particle] {
        let w = Float(cardSize.width), h = Float(cardSize.height)
        var result: [Particle] = []
        for i in 0..<150 {
            let kind: ParticleKind = i % 5 == 0 ? .star : (i % 3 == 0 ? .sparkle : .confetti)
            let origin = SIMD2(rng.float(0.15...0.85) * w, rng.float(0.35...0.75) * h)
            let angle = rng.float(-.pi * 0.92 ... -.pi * 0.08)
            let speed = rng.float(420...1150)
            let life = rng.float(1.6...2.8)
            result.append(Particle(
                kind: kind,
                position: origin,
                velocity: SIMD2(cos(angle), sin(angle)) * speed,
                size: kind == .confetti ? rng.float(4...7) : rng.float(3...7),
                rotation: rng.float(0...6.28),
                spin: rng.float(-9...9),
                flip: rng.float(0...6.28),
                flipSpeed: kind == .confetti ? rng.float(6...14) : 0,
                life: life, maxLife: life,
                gravityScale: kind == .confetti ? 0.42 : 0.3,
                drag: kind == .confetti ? 1.6 : 1.9,
                wobble: kind == .confetti ? rng.float(0.5...1.5) : 0,
                hue: rng.float(0...0.999),
                seed: rng.float(0...1)
            ))
        }
        return result
    }
}

enum CelebrationArt {
    static func draw(_ p: Particle, in context: inout GraphicsContext) {
        let fade = Double(min(1, p.lifeFraction * 3))
        let s = CGFloat(p.size)
        var c = context
        c.translateBy(x: CGFloat(p.position.x), y: CGFloat(p.position.y))
        c.rotate(by: .radians(Double(p.rotation)))
        switch p.kind {
        case .confetti:
            let color = CelebrationRecipe.palette[Int(p.hue * Float(CelebrationRecipe.palette.count))]
            let squash = CGFloat(cos(p.flip))
            c.scaleBy(x: 1, y: max(0.08, abs(squash)))
            let shade = squash < 0 ? 0.75 : 1.0
            c.fill(Path(CGRect(x: -s * 0.55, y: -s, width: s * 1.1, height: s * 2)),
                   with: .color(color.opacity(fade * shade)))
        case .sparkle:
            let twinkle = 0.55 + 0.45 * sin(Double(p.age) * 18 + Double(p.seed) * 40)
            c.fill(sparklePath(radius: s * 1.3), with: .color(Color(red: 1, green: 0.92, blue: 0.62).opacity(fade * twinkle)))
        case .star:
            c.fill(starPath(radius: s * 1.4), with: .color(Color(red: 0.98, green: 0.80, blue: 0.36).opacity(fade)))
        default:
            break
        }
    }

    /// Étincelle à quatre branches.
    static func sparklePath(radius r: CGFloat) -> Path {
        var path = Path()
        let k = r * 0.22
        path.move(to: CGPoint(x: 0, y: -r))
        path.addQuadCurve(to: CGPoint(x: r, y: 0), control: CGPoint(x: k, y: -k))
        path.addQuadCurve(to: CGPoint(x: 0, y: r), control: CGPoint(x: k, y: k))
        path.addQuadCurve(to: CGPoint(x: -r, y: 0), control: CGPoint(x: -k, y: k))
        path.addQuadCurve(to: CGPoint(x: 0, y: -r), control: CGPoint(x: -k, y: -k))
        return path
    }

    static func starPath(radius r: CGFloat) -> Path {
        var path = Path()
        for i in 0..<10 {
            let angle = CGFloat(i) * .pi / 5 - .pi / 2
            let radius = i.isMultiple(of: 2) ? r : r * 0.45
            let point = CGPoint(x: cos(angle) * radius, y: sin(angle) * radius)
            if i == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        path.closeSubpath()
        return path
    }
}
