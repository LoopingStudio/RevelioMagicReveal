import CoreImage
import UIKit

/// La photo vue dans l'écran du message, préparée une fois : réduite (le halo et la couronne la
/// dessinent à chaque image) et une version givrée pour « La voix révèle la photo ».
nonisolated struct MessagePhoto: @unchecked Sendable {
    let photo: UIImage
    let frosted: UIImage

    static let maxDimension: CGFloat = 520

    static func prepare(_ cover: UIImage) async -> MessagePhoto {
        await Task.detached(priority: .userInitiated) { make(cover) }.value
    }

    static func make(_ cover: UIImage) -> MessagePhoto {
        let longest = max(cover.size.width, cover.size.height)
        let scale = min(1, maxDimension / max(longest, 1))
        let size = CGSize(width: (cover.size.width * scale).rounded(), height: (cover.size.height * scale).rounded())
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let small = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            cover.draw(in: CGRect(origin: .zero, size: size))
        }
        return MessagePhoto(photo: small, frosted: frost(small) ?? small)
    }

    /// Flou épais, couleurs éteintes et éclaircies : la photo derrière une vitre givrée.
    private static func frost(_ image: UIImage) -> UIImage? {
        guard let cg = image.cgImage else { return nil }
        let input = CIImage(cgImage: cg)
        let output = input.clampedToExtent()
            .applyingGaussianBlur(sigma: 16)
            .applyingFilter("CIColorControls", parameters: [
                kCIInputSaturationKey: 0.5,
                kCIInputBrightnessKey: 0.14,
                kCIInputContrastKey: 0.9,
            ])
            .cropped(to: input.extent)
        guard let result = CIContext().createCGImage(output, from: input.extent) else { return nil }
        return UIImage(cgImage: result)
    }
}
