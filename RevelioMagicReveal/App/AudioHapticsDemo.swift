import Foundation
import Observation

/// Banc d'essai « vibrations depuis un son » : l'app analyse le fichier au chargement (coups, rythme,
/// enveloppe) puis joue le son et les vibrations qui en sont déduites.
@Observable
final class AudioHapticsDemo {
    enum State: Equatable { case idle, analyzing, playing, failed }

    private(set) var state: State = .idle
    /// Résultat de la dernière analyse, pour le contrôle (« 36 coups · 111 bpm »).
    private(set) var summary: String?

    @ObservationIgnored private let feedback: FeedbackCenter
    @ObservationIgnored private var task: Task<Void, Never>?

    init(feedback: FeedbackCenter) {
        self.feedback = feedback
    }

    /// Fichier choisi dans Fichiers : copié dans le dossier temporaire (l'accès sécurisé est éphémère).
    func play(fileAt picked: URL) {
        let accessing = picked.startAccessingSecurityScopedResource()
        defer { if accessing { picked.stopAccessingSecurityScopedResource() } }
        let copy = URL.temporaryDirectory.appending(path: "son-\(UUID().uuidString).\(picked.pathExtension)")
        do {
            try FileManager.default.copyItem(at: picked, to: copy)
        } catch {
            state = .failed
            summary = "Impossible de lire « \(picked.lastPathComponent) »"
            return
        }
        play(copy, name: picked.deletingPathExtension().lastPathComponent)
    }

    func stop() {
        task?.cancel()
        task = nil
        feedback.stopAudioDriven()
        state = .idle
    }

    private func play(_ url: URL, name: String) {
        stop()
        state = .analyzing
        task = Task {
            // L'analyse (décodage, filtrage, détection) se fait hors du fil principal ; on joue ensuite le
            // vrai fichier, avec les vibrations par-dessus.
            let analysis = await Task.detached(priority: .userInitiated) {
                try? HeartbeatAnalyzer.analyze(fileAt: url)
            }.value
            guard !Task.isCancelled else { return }
            guard let analysis else {
                state = .failed
                summary = "Impossible d'analyser « \(name) »"
                return
            }
            let bpm = analysis.bpm > 0 ? " · \(Int(analysis.bpm.rounded())) bpm" : ""
            summary = "\(name) : \(analysis.beats.count) coups\(bpm) · \(Int(analysis.duration.rounded())) s"
            feedback.playAudioDriven(url: url, analysis: analysis)
            state = .playing
            try? await Task.sleep(for: .seconds(analysis.duration + 0.3))
            if !Task.isCancelled { state = .idle }
        }
    }
}
