import CoreGraphics
import SwiftUI

/// Motif des cristaux de givre (plumes de glace, petites étoiles, grain, épaisseur), dessiné une seule fois
/// par le GPU puis relu par les shaders à chaque image : il peut être riche sans peser sur le 120 Hz.
/// Canaux : R = cristaux, G = épaisseur du givre, B = grain des facettes.
@MainActor
enum FrostCrystalMap {
    /// Carte de référence au ratio de la photo, en points ; le motif s'étire à la taille réelle de la carte.
    static let referenceSize = CGSize(width: 360, height: 480)
    static let scale: CGFloat = 3

    /// Le motif, rendu au premier accès (quelques millisecondes), ou un repli uniforme si le rendu échoue.
    static let image: Image = render() ?? placeholder

    static func render() -> Image? {
        let content = Rectangle()
            .fill(.white)
            .colorEffect(ShaderLibrary.rnFrostCrystals(.boundingRect))
            .frame(width: referenceSize.width, height: referenceSize.height)
        let renderer = ImageRenderer(content: content)
        renderer.scale = scale
        renderer.isOpaque = true
        guard let cgImage = renderer.cgImage else { return nil }
        return Image(decorative: cgImage, scale: scale)
    }

    /// Givre uniforme, sans cristaux.
    static var placeholder: Image {
        Image(size: CGSize(width: 2, height: 2), opaque: true) { context in
            context.fill(Path(CGRect(x: 0, y: 0, width: 2, height: 2)),
                         with: .color(Color(red: 0, green: 0.55, blue: 0.5)))
        }
    }
}
