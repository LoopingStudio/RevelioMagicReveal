import SwiftUI
import simd

/// Neige accumulée sur la photo.
struct SnowMaskView: View {
    let engine: RevealEngine

    var body: some View {
        let _ = engine.frame
        Rectangle()
            .fill(.white)
            .colorEffect(ShaderLibrary.rnSnow(
                .boundingRect,
                engine.fieldArgument,
                engine.fieldSizeArgument,
                .float(engine.time)
            ))
            .allowsHitTesting(false)
    }
}

enum SnowRecipe: ParticleRecipe {
    static func particles(for event: ErosionEvent, rng: inout SeededRandom) -> [Particle] {
        switch event.source {
        case .scratch: scratch(event, &rng)
        case .blow: blow(event, &rng)
        case .shake: shake(event, &rng)
        case .finish: finish(event, &rng)
        }
    }

    /// Poudre soulevée par le doigt, quelques petites mottes.
    private static func scratch(_ event: ErosionEvent, _ rng: inout SeededRandom) -> [Particle] {
        let count = min(14, Int(event.totalAmount * 1.4) + 1)
        let push = event.direction * 0.12
        return rng.pick(event.cells, count: count).map { cell in
            let clump = rng.chance(0.18)
            let life = rng.float(0.5...1.0)
            return Particle(
                kind: clump ? .clump : .powder,
                position: event.point(cell) + SIMD2(rng.float(-3...3), rng.float(-3...3)),
                velocity: push + SIMD2(rng.float(-70...70), rng.float(-150 ... -20)),
                size: clump ? rng.float(2.5...5) : rng.float(1...2.4),
                rotation: rng.float(0...6.28),
                spin: rng.float(-4...4),
                life: life, maxLife: life,
                gravityScale: clump ? 0.9 : 0.25,
                drag: clump ? 0.6 : 2.6,
                seed: rng.float(0...1)
            )
        }
    }

    /// Les flocons s'envolent vers le haut en tourbillonnant.
    private static func blow(_ event: ErosionEvent, _ rng: inout SeededRandom) -> [Particle] {
        let count = min(18, Int(event.totalAmount * 0.5) + 1)
        return rng.pick(event.cells, count: count).map { cell in
            let life = rng.float(1.1...2.0)
            return Particle(
                kind: rng.chance(0.75) ? .flake : .powder,
                position: event.point(cell),
                velocity: SIMD2(rng.float(-160...160), rng.float(-620 ... -260) * (0.6 + 0.4 * event.intensity)),
                size: rng.float(1.6...4.2),
                rotation: rng.float(0...6.28),
                spin: rng.float(-3...3),
                life: life, maxLife: life,
                gravityScale: 0.07,
                drag: 1.1,
                wobble: rng.float(0.8...2.2),
                seed: rng.float(0...1)
            )
        }
    }

    /// Des mottes se détachent et tombent dans le sens de la secousse puis de la gravité.
    private static func shake(_ event: ErosionEvent, _ rng: inout SeededRandom) -> [Particle] {
        let count = min(40, Int(event.totalAmount * 0.35) + 1)
        let kick = event.direction * 260 * (0.5 + event.intensity)
        return rng.pick(event.cells, count: count).map { cell in
            let big = rng.chance(0.45)
            let life = rng.float(1.2...2.0)
            return Particle(
                kind: big ? .clump : .powder,
                position: event.point(cell),
                velocity: kick + SIMD2(rng.float(-90...90), rng.float(-120...40)),
                size: big ? rng.float(4...10) : rng.float(1.2...2.6),
                rotation: rng.float(0...6.28),
                spin: rng.float(-5...5),
                life: life, maxLife: life,
                gravityScale: big ? 1 : 0.4,
                drag: big ? 0.25 : 1.8,
                seed: rng.float(0...1)
            )
        }
    }

    /// Fin : la neige restante part en poudre légère.
    private static func finish(_ event: ErosionEvent, _ rng: inout SeededRandom) -> [Particle] {
        let count = min(24, Int(event.totalAmount * 0.25) + 1)
        return rng.pick(event.cells, count: count).map { cell in
            let life = rng.float(0.9...1.6)
            return Particle(
                kind: .flake,
                position: event.point(cell),
                velocity: SIMD2(rng.float(-120...120), rng.float(-260 ... -60)),
                size: rng.float(1.4...3.6),
                spin: rng.float(-3...3),
                life: life, maxLife: life,
                gravityScale: 0.1,
                drag: 1.2,
                wobble: 1.4,
                seed: rng.float(0...1)
            )
        }
    }
}

enum SnowArt {
    static func draw(_ p: Particle, in context: inout GraphicsContext) {
        let fade = Double(min(1, p.lifeFraction * 2.5))
        let s = CGFloat(p.size)
        let center = CGPoint(x: CGFloat(p.position.x), y: CGFloat(p.position.y))
        switch p.kind {
        case .flake:
            let halo = CGRect(x: center.x - s * 1.6, y: center.y - s * 1.6, width: s * 3.2, height: s * 3.2)
            context.fill(Path(ellipseIn: halo), with: .color(.white.opacity(0.18 * fade)))
            let core = CGRect(x: center.x - s * 0.6, y: center.y - s * 0.6, width: s * 1.2, height: s * 1.2)
            context.fill(Path(ellipseIn: core), with: .color(.white.opacity(0.95 * fade)))
        case .powder:
            let r = CGRect(x: center.x - s / 2, y: center.y - s / 2, width: s, height: s)
            context.fill(Path(ellipseIn: r), with: .color(.white.opacity(0.85 * fade)))
        case .clump:
            var c = context
            c.translateBy(x: center.x, y: center.y)
            c.rotate(by: .radians(Double(p.rotation)))
            let body = CGRect(x: -s, y: -s * 0.75, width: s * 2, height: s * 1.5)
            c.fill(Path(ellipseIn: body), with: .color(Color(red: 0.74, green: 0.81, blue: 0.94).opacity(fade)))
            let top = body.insetBy(dx: s * 0.18, dy: s * 0.12).offsetBy(dx: -s * 0.1, dy: -s * 0.12)
            c.fill(Path(ellipseIn: top), with: .color(.white.opacity(fade)))
        default:
            break
        }
    }
}
