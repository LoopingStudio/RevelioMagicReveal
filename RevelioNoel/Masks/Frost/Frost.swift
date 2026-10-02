import SwiftUI
import simd

/// Givre sur une vitre. PROVISOIRE : aplat bleuté, à remplacer par le vrai rendu.
struct FrostMaskView: View {
    let engine: RevealEngine
    let photo: Image

    var body: some View {
        let _ = engine.frame
        Rectangle()
            .fill(.white)
            .colorEffect(ShaderLibrary.rnPlaceholder(
                .boundingRect,
                engine.fieldArgument,
                engine.fieldSizeArgument,
                .color(Color(red: 0.85, green: 0.93, blue: 1.0).opacity(0.92))
            ))
            .allowsHitTesting(false)
    }
}

enum FrostRecipe: ParticleRecipe {
    static func particles(for event: ErosionEvent, rng: inout SeededRandom) -> [Particle] {
        []
    }
}

enum FrostArt {
    static func draw(_ p: Particle, in context: inout GraphicsContext) {}
}
