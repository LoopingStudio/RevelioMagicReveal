import SwiftUI
import simd

/// Ticket à gratter doré. PROVISOIRE : aplat doré, à remplacer par le vrai rendu.
struct GoldMaskView: View {
    let engine: RevealEngine

    var body: some View {
        let _ = engine.frame
        Rectangle()
            .fill(.white)
            .colorEffect(ShaderLibrary.rnPlaceholder(
                .boundingRect,
                engine.fieldArgument,
                engine.fieldSizeArgument,
                .color(Color(red: 0.86, green: 0.68, blue: 0.27))
            ))
            .allowsHitTesting(false)
    }
}

enum GoldRecipe: ParticleRecipe {
    static func particles(for event: ErosionEvent, rng: inout SeededRandom) -> [Particle] {
        []
    }
}

enum GoldArt {
    static func draw(_ p: Particle, in context: inout GraphicsContext) {}
}
