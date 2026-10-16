import SwiftUI

/// Barre de lecture façon message vocal : bouton lecture, forme d'onde du message entier (dorée pour
/// la partie écoutée) qu'on scrubbe au doigt, et le temps.
struct MessageScrubber: View {
    let model: AudioMessageModel

    var body: some View {
        HStack(spacing: 14) {
            Button {
                model.togglePlay()
            } label: {
                Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 20, weight: .semibold))
                    .frame(width: 48, height: 48)
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.glassProminent)
            .buttonBorderShape(.circle)
            .tint(Palette.gold)
            .disabled(!model.canPlay)
            .accessibilityLabel(model.isPlaying ? "Pause" : "Écouter")

            TimelineView(.animation(paused: !model.isAnimating)) { _ in
                let time = model.playhead()
                let duration = model.duration
                HStack(spacing: 12) {
                    GeometryReader { proxy in
                        WaveformBars(bars: model.overview, progress: duration > 0 ? time / duration : 0)
                            .contentShape(.rect)
                            .gesture(scrub(width: proxy.size.width, duration: duration))
                    }
                    .frame(height: 38)
                    Text("\(Self.format(time)) / \(Self.format(duration))")
                        .font(.caption.weight(.medium).monospacedDigit())
                        .foregroundStyle(Palette.cream.opacity(0.75))
                        .fixedSize()
                }
            }
        }
        .disabled(model.isRecording)
    }

    private func scrub(width: CGFloat, duration: Double) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if !model.isScrubbing { model.beginScrub() }
                model.scrub(to: Double(min(max(value.location.x / max(width, 1), 0), 1)) * duration)
            }
            .onEnded { value in
                model.endScrub(at: Double(min(max(value.location.x / max(width, 1), 0), 1)) * duration)
            }
    }

    static func format(_ seconds: Double) -> String {
        let total = Int(seconds.rounded(.down))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

/// La forme d'onde d'un message en barres arrondies, la partie lue en or.
private struct WaveformBars: View {
    let bars: [Float]
    let progress: Double

    var body: some View {
        Canvas { context, size in
            guard !bars.isEmpty else { return }
            let slot = size.width / CGFloat(bars.count)
            let width = max(2, slot * 0.56)
            let corner = CGSize(width: width / 2, height: width / 2)
            var played = Path(), rest = Path()
            for (i, value) in bars.enumerated() {
                let height = 4 + CGFloat(value) * (size.height - 4)
                let rect = CGRect(x: CGFloat(i) * slot + (slot - width) / 2, y: (size.height - height) / 2,
                                  width: width, height: height)
                if (Double(i) + 0.5) / Double(bars.count) <= progress {
                    played.addRoundedRect(in: rect, cornerSize: corner)
                } else {
                    rest.addRoundedRect(in: rect, cornerSize: corner)
                }
            }
            context.fill(played, with: .color(Palette.gold))
            context.fill(rest, with: .color(Palette.cream.opacity(0.35)))
        }
    }
}
