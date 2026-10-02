import SwiftUI
import simd

/// Papier cadeau. PROVISOIRE : aplat rouge piloté par la carte, à remplacer par les morceaux déchirés.
struct PaperMaskView: View {
    let engine: RevealEngine

    var body: some View {
        let _ = engine.frame
        Rectangle()
            .fill(.white)
            .colorEffect(ShaderLibrary.rnPlaceholder(
                .boundingRect,
                engine.fieldArgument,
                engine.fieldSizeArgument,
                .color(Color(red: 0.72, green: 0.09, blue: 0.13))
            ))
            .allowsHitTesting(false)
    }
}

/// Morceaux en train de tomber, dessinés hors de la carte. PROVISOIRE : vide.
struct PaperFallingLayer: View {
    let engine: RevealEngine

    var body: some View {
        EmptyView()
    }
}

/// État du papier : morceaux attachés ou détachés. PROVISOIRE : suit simplement la carte.
struct PaperSheet: Sendable {
    private(set) var revealedFraction: Float = 0

    init(aspect: Float, seed: UInt32) {}

    /// Appelé à chaque tick quand le masque papier est actif ; rend d'éventuelles particules à émettre.
    mutating func step(dt: Float, field: CoverageField, events: [ErosionEvent], gravity: SIMD2<Float>,
                       cardSize: CGSize, rng: inout SeededRandom) -> [Particle] {
        revealedFraction = field.revealedFraction
        return []
    }

    /// Auto-fin : tout ce qui reste se détache.
    mutating func detachAll(rng: inout SeededRandom) {}
}

enum PaperRecipe: ParticleRecipe {
    static func particles(for event: ErosionEvent, rng: inout SeededRandom) -> [Particle] {
        []
    }
}

enum PaperArt {
    static func draw(_ p: Particle, in context: inout GraphicsContext) {}
}
