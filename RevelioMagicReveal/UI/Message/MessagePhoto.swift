import UIKit

/// La photo vue dans l'écran du message, préparée une fois : réduite, car le halo et la couronne la
/// dessinent à chaque image.
nonisolated struct MessagePhoto: @unchecked Sendable {
    let photo: UIImage

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
        return MessagePhoto(photo: small)
    }
}
