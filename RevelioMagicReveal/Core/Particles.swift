import CoreGraphics
import Foundation
import simd

/// Toutes les sortes de particules. Le dessin de chaque famille vit dans le dossier de son masque.
enum ParticleKind: UInt8, Sendable {
    // Neige
    case flake, powder, clump
    // Givre
    case shard, droplet, frostDust
    // Doré
    case goldFlake, goldCurl
    // Papier
    case paperScrap
    // Célébration
    case sparkle, confetti, star

    enum Family { case snow, frost, gold, paper, celebration }

    var family: Family {
        switch self {
        case .flake, .powder, .clump: .snow
        case .shard, .droplet, .frostDust: .frost
        case .goldFlake, .goldCurl: .gold
        case .paperScrap: .paper
        case .sparkle, .confetti, .star: .celebration
        }
    }
}

/// Une particule, en points dans le repère de la carte (origine en haut à gauche).
struct Particle: Sendable {
    var kind: ParticleKind
    var position: SIMD2<Float>
    var velocity: SIMD2<Float> = .zero
    var size: Float = 4
    var rotation: Float = 0
    var spin: Float = 0
    /// Phase de retournement (confettis, morceaux plats) : on dessine avec une échelle cos(flip).
    var flip: Float = 0
    var flipSpeed: Float = 0
    var life: Float = 1
    var maxLife: Float = 1
    /// Fraction de la gravité appliquée (les flocons planent, les mottes tombent).
    var gravityScale: Float = 1
    /// Freinage par seconde.
    var drag: Float = 0.5
    /// Amplitude du flottement latéral (flocons, confettis).
    var wobble: Float = 0
    /// Teinte libre pour la famille (0…1), par exemple la couleur d'un confetti.
    var hue: Float = 0
    var seed: Float = 0

    var age: Float { maxLife - life }
    var lifeFraction: Float { max(0, life / maxLife) }
}

/// Simulation simple : gravité réelle du téléphone, freinage, flottement, durée de vie.
struct ParticleSystem: Sendable {
    static let gravityStrength: Float = 1400 // points / s²

    private(set) var particles: [Particle] = []
    var maxCount = 1400

    var isEmpty: Bool { particles.isEmpty }
    var count: Int { particles.count }

    mutating func emit(_ particle: Particle) {
        guard particles.count < maxCount else { return }
        particles.append(particle)
    }

    mutating func emit(contentsOf newParticles: [Particle]) {
        let room = maxCount - particles.count
        guard room > 0 else { return }
        particles.append(contentsOf: newParticles.prefix(room))
    }

    /// `bounds` : zone au-delà de laquelle une particule est retirée (la carte élargie).
    mutating func step(dt: Float, gravity: SIMD2<Float>, time: Float, bounds: CGRect) {
        guard !particles.isEmpty else { return }
        let g = gravity * Self.gravityStrength
        let minX = Float(bounds.minX), maxX = Float(bounds.maxX)
        let minY = Float(bounds.minY), maxY = Float(bounds.maxY)
        var i = 0
        while i < particles.count {
            var p = particles[i]
            p.life -= dt
            p.velocity += g * p.gravityScale * dt
            p.velocity *= max(0, 1 - p.drag * dt)
            if p.wobble != 0 {
                let sway = sin(time * 2.3 + p.seed * 17) * p.wobble
                p.velocity.x += sway * dt * 60
            }
            p.position += p.velocity * dt
            p.rotation += p.spin * dt
            p.flip += p.flipSpeed * dt
            let outside = p.position.x < minX || p.position.x > maxX || p.position.y < minY || p.position.y > maxY
            if p.life <= 0 || outside {
                particles.swapAt(i, particles.count - 1)
                particles.removeLast()
            } else {
                particles[i] = p
                i += 1
            }
        }
    }

    mutating func removeAll() {
        particles.removeAll(keepingCapacity: true)
    }
}
