import SwiftUI

/// Une recette transforme une érosion en particules propres au masque.
protocol ParticleRecipe {
    static func particles(for event: ErosionEvent, rng: inout SeededRandom) -> [Particle]
}

extension MaskKind {
    var recipe: any ParticleRecipe.Type {
        switch self {
        case .frost: FrostRecipe.self
        case .snow: SnowRecipe.self
        case .paper: PaperRecipe.self
        case .gold: GoldRecipe.self
        }
    }
}

/// La couche qui recouvre la photo, selon le masque choisi.
struct MaskLayer: View {
    let engine: RevealEngine
    let photo: Image

    var body: some View {
        switch engine.mask {
        case .frost: FrostMaskView(engine: engine, photo: photo)
        case .snow: SnowMaskView(engine: engine)
        case .paper: PaperMaskView(engine: engine)
        case .gold: GoldMaskView(engine: engine)
        }
    }
}

/// Couche libre (non rognée par la carte) propre au masque, par exemple les morceaux de papier qui tombent.
/// Elle est posée sur la carte agrandie de `RevealEngine.particleMargin` de chaque côté :
/// l'origine de la carte y est en (particleMargin, particleMargin).
struct MaskFreeLayer: View {
    let engine: RevealEngine

    var body: some View {
        switch engine.mask {
        case .paper: PaperFallingLayer(engine: engine)
        case .frost, .snow, .gold: EmptyView()
        }
    }
}

/// Dessin d'une particule selon sa famille.
enum ParticleArt {
    static func draw(_ particle: Particle, in context: inout GraphicsContext) {
        switch particle.kind.family {
        case .snow: SnowArt.draw(particle, in: &context)
        case .frost: FrostArt.draw(particle, in: &context)
        case .gold: GoldArt.draw(particle, in: &context)
        case .paper: PaperArt.draw(particle, in: &context)
        case .celebration: CelebrationArt.draw(particle, in: &context)
        }
    }
}

extension RevealEngine {
    /// Arguments communs passés aux shaders : la carte de couverture et sa taille.
    var fieldArgument: Shader.Argument { .floatArray(field.values) }
    var fieldSizeArgument: Shader.Argument { .float2(Float(field.cols), Float(field.rows)) }
}

/// Particules : aide au tirage aléatoire.
extension SeededRandom {
    mutating func float(_ range: ClosedRange<Float>) -> Float {
        Float.random(in: range, using: &self)
    }

    mutating func chance(_ probability: Float) -> Bool {
        Float.random(in: 0..<1, using: &self) < probability
    }

    /// Tire jusqu'à `count` cellules, pondérées par la quantité érodée.
    mutating func pick(_ cells: [ErodedCell], count: Int) -> [ErodedCell] {
        guard !cells.isEmpty, count > 0 else { return [] }
        if cells.count <= count { return cells }
        return (0..<count).map { _ in cells[Int.random(in: 0..<cells.count, using: &self)] }
    }
}
