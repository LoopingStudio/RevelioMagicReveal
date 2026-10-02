import AVFoundation
import CoreTransferable
import Observation
import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Ce qu'on révèle : une photo, ou une vidéo qui démarre une fois la révélation terminée.
@Observable
final class MediaStore {
    enum Kind: Equatable { case photo, video }

    private(set) var kind: Kind = .photo
    /// Image affichée sous le masque : la photo, ou la première image de la vidéo.
    private(set) var cover: UIImage
    /// Lecteur de la vidéo courante (nil pour une photo), calé sur la première image tant qu'on n'a pas révélé.
    private(set) var player: AVPlayer?
    private(set) var isLoading = false

    init() {
        cover = SamplePhoto.render()
    }

    // MARK: - Contenu

    func useSampleVideo() async {
        guard let url = Bundle.main.url(forResource: "noel-exemple", withExtension: "mp4") else { return }
        await loadVideo(url)
    }

    func useSamplePhoto() {
        showPhoto(SamplePhoto.render())
    }

    func load(_ item: PhotosPickerItem) async {
        isLoading = true
        defer { isLoading = false }
        if item.supportedContentTypes.contains(where: { $0.conforms(to: .movie) }) {
            guard let movie = try? await item.loadTransferable(type: PickedMovie.self) else { return }
            await loadVideo(movie.url)
        } else {
            guard let data = try? await item.loadTransferable(type: Data.self),
                  let picked = UIImage(data: data) else { return }
            showPhoto(picked.preparedForDisplay(maxDimension: 2000))
        }
    }

    private func showPhoto(_ image: UIImage) {
        player?.pause()
        player = nil
        cover = image
        kind = .photo
    }

    /// La première image exacte sert de couverture : la vidéo, calée dessus, prend le relais sans saut.
    private func loadVideo(_ url: URL) async {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        generator.maximumSize = CGSize(width: 2000, height: 2000)
        guard let first = try? await generator.image(at: .zero) else { return }
        player?.pause()
        let player = AVPlayer(url: url)
        player.actionAtItemEnd = .pause
        player.automaticallyWaitsToMinimizeStalling = false
        self.player = player
        cover = UIImage(cgImage: first.image)
        kind = .video
    }

    // MARK: - Lecture

    /// Révélation terminée (ou tap pour revoir) : la vidéo repart du début.
    func playFromStart() {
        guard let player else { return }
        player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
        player.play()
    }

    /// Photo recouverte : la vidéo revient sur sa première image, à l'arrêt.
    func rewind() {
        guard let player else { return }
        player.pause()
        player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
    }
}

/// Vidéo choisie dans la photothèque, copiée dans le dossier temporaire de l'app.
nonisolated struct PickedMovie: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { movie in
            SentTransferredFile(movie.url)
        } importing: { received in
            let ext = received.file.pathExtension.isEmpty ? "mov" : received.file.pathExtension
            let destination = URL.temporaryDirectory.appending(path: "revelio-\(UUID().uuidString).\(ext)")
            try FileManager.default.copyItem(at: received.file, to: destination)
            return PickedMovie(url: destination)
        }
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
