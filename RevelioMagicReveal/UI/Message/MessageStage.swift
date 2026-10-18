import SwiftUI

/// La grande scène de l'écran du message : la visualisation choisie pendant la lecture, le niveau en
/// direct pendant l'enregistrement, ou l'état en cours (préparation, erreur).
struct MessageStage: View {
    let model: AudioMessageModel
    let photo: MessagePhoto?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 28)
                .fill(Palette.night.opacity(0.6))
            content
        }
        .clipShape(.rect(cornerRadius: 28))
        .overlay {
            RoundedRectangle(cornerRadius: 28)
                .strokeBorder(Palette.cream.opacity(0.12))
        }
        .animation(.smooth(duration: 0.25), value: model.visualization)
    }

    @ViewBuilder private var content: some View {
        switch model.phase {
        case .recording:
            RecordingStage(levels: Array(model.recordingLevels.suffix(AudioMessageModel.liveBars)),
                           started: model.recordingStarted ?? .now)
        case .preparing(let text):
            VStack(spacing: 14) {
                ProgressView()
                    .controlSize(.large)
                    .tint(Palette.cream)
                Text(text)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(Palette.cream.opacity(0.8))
            }
        case .failed(let text):
            notice(text, symbol: "exclamationmark.bubble")
        case .empty:
            notice("Écoute l'exemple ou enregistre un message", symbol: "waveform")
        case .ready, .playing:
            if let analysis = model.analysis, let message = model.message {
                visualization(analysis: analysis, message: message)
            }
        }
    }

    private func visualization(analysis: AudioMessageAnalysis, message: AudioMessage) -> some View {
        let kind = model.visualization
        return TimelineView(.animation(paused: !model.isAnimating)) { _ in
            let input = StageInput(analysis: analysis, message: message, time: model.playhead(), photo: photo)
            Canvas(rendersAsynchronously: false) { context, size in
                StageArt.draw(kind, in: &context, size: size, input: input)
            }
        }
        .id(kind)
        .transition(.opacity)
        .accessibilityElement()
        .accessibilityLabel("Visualisation : \(kind.title)")
    }

    private func notice(_ text: String, symbol: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 34, weight: .semibold))
                .foregroundStyle(Palette.gold)
            Text(text)
                .font(.callout.weight(.medium))
                .foregroundStyle(Palette.cream.opacity(0.85))
                .multilineTextAlignment(.center)
        }
        .padding(28)
    }
}

/// Pendant l'enregistrement : le niveau du micro qui défile (le plus récent à droite) et le chrono.
private struct RecordingStage: View {
    let levels: [Float]
    let started: Date

    var body: some View {
        VStack(spacing: 20) {
            Canvas { context, size in
                let slot = size.width / CGFloat(AudioMessageModel.liveBars)
                let width = slot * 0.6
                var bars = Path()
                for (i, level) in levels.enumerated() {
                    let x = size.width - CGFloat(levels.count - i) * slot + (slot - width) / 2
                    let height = 2 + CGFloat(level) * size.height * 0.46
                    bars.addRoundedRect(in: CGRect(x: x, y: size.height / 2 - height, width: width, height: height * 2),
                                        cornerSize: CGSize(width: width / 2, height: width / 2))
                }
                context.fill(bars, with: .color(Palette.cream))
            }
            .frame(height: 150)

            HStack(spacing: 8) {
                Image(systemName: "record.circle.fill")
                    .foregroundStyle(Palette.berry)
                    .symbolEffect(.pulse)
                Text(started, style: .timer)
                    .monospacedDigit()
            }
            .font(.title3.weight(.semibold))
            .foregroundStyle(Palette.cream)

            Text("Parle… touche Terminer quand c'est fini")
                .font(.callout)
                .foregroundStyle(Palette.cream.opacity(0.7))
        }
        .padding(24)
    }
}
