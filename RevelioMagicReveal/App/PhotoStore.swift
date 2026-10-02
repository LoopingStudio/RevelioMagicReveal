import Observation
import PhotosUI
import SwiftUI
import UIKit

/// La photo à révéler : celle d'exemple, ou une photo de la photothèque.
@Observable
final class PhotoStore {
    private(set) var image: UIImage
    private(set) var isLoading = false

    init() {
        image = SamplePhoto.render()
    }

    func load(_ item: PhotosPickerItem) async {
        isLoading = true
        defer { isLoading = false }
        guard let data = try? await item.loadTransferable(type: Data.self),
              let picked = UIImage(data: data) else { return }
        image = picked.preparedForDisplay(maxDimension: 2000)
    }

    func useSample() {
        image = SamplePhoto.render()
    }
}

private extension UIImage {
    func preparedForDisplay(maxDimension: CGFloat) -> UIImage {
        let longest = max(size.width, size.height)
        guard longest > maxDimension else { return self }
        let scale = maxDimension / longest
        let target = CGSize(width: size.width * scale, height: size.height * scale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: target, format: format).image { _ in
            draw(in: CGRect(origin: .zero, size: target))
        }
    }
}
