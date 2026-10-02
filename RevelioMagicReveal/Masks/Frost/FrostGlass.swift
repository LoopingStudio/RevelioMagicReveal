import CoreGraphics
import SwiftUI
import simd

/// Réglages du rendu, isolés pour être testés.
enum FrostLook {
    /// Flou de la photo vue à travers le givre, en points.
    static let blurRadius: CGFloat = 13

    /// Humidité du bord : souffler fait fondre (bord mouillé, large), secouer casse la glace (bord sec et net).
    static func wetness(for gesture: RevealGesture) -> Float {
        switch gesture {
        case .scratch: 0.7
        case .blow: 1
        case .shake: 0.2
        }
    }
}

/// La vitre givrée elle-même, pilotée par des valeurs simples (carte de couverture comprise).
struct FrostGlass: View {
    let photo: Image
    /// Motif des cristaux (`FrostCrystalMap`).
    let crystals: Image
    let field: Shader.Argument
    let fieldSize: Shader.Argument
    let time: Float
    let gravity: SIMD2<Float>
    let wetness: Float

    var body: some View {
        ZStack {
            // Bord humide côté vitre dégagée : réfracte une copie de la photo nette.
            Color.clear
                .overlay { photo.resizable().scaledToFill() }
                .clipped()
                .layerEffect(
                    ShaderLibrary.rnFrostMeniscus(
                        .boundingRect, field, fieldSize, .image(crystals),
                        .float(time), .float2(gravity.x, gravity.y), .float(wetness)
                    ),
                    maxSampleOffset: CGSize(width: 6, height: 6)
                )
            // Le givre, par-dessus : la photo vue à travers devient floue.
            Color.clear
                .overlay {
                    photo.resizable().scaledToFill()
                        .blur(radius: FrostLook.blurRadius, opaque: true)
                }
                .clipped()
                .layerEffect(
                    ShaderLibrary.rnFrostPane(
                        .boundingRect, field, fieldSize, .image(crystals),
                        .float(time), .float2(gravity.x, gravity.y), .float(wetness)
                    ),
                    maxSampleOffset: CGSize(width: 4, height: 4)
                )
        }
    }
}
