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
                        WaveformBars(bars: model.overview, progress: duration > 0 ? time / duration : 0,
                                     grabbed: model.isScrubbing)
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
        .sensoryFeedback(.impact(weight: .light), trigger: model.isScrubbing) { _, grabbed in grabbed }
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

/// La forme d'onde d'un message en barres arrondies. La partie lue se remplit d'or en continu (pas barre
/// par barre), avec un curseur qui grossit quand on le tient.
private struct WaveformBars: View {
    let bars: [Float]
    let progress: Double
    let grabbed: Bool

    var body: some View {
        Canvas { context, size in
            guard !bars.isEmpty else { return }
            let slot = size.width / CGFloat(bars.count)
            let width = max(2, slot * 0.56)
            let corner = CGSize(width: width / 2, height: width / 2)
            var shape = Path()
            for (i, value) in bars.enumerated() {
                let height = 4 + CGFloat(value) * (size.height - 4)
                shape.addRoundedRect(in: CGRect(x: CGFloat(i) * slot + (slot - width) / 2, y: (size.height - height) / 2,
                                                width: width, height: height), cornerSize: corner)
            }
            context.fill(shape, with: .color(Palette.cream.opacity(0.32)))
            let x = size.width * CGFloat(min(max(progress, 0), 1))
            var played = context
            played.clip(to: Path(CGRect(x: 0, y: 0, width: x, height: size.height)))
            played.fill(shape, with: .color(Palette.gold))

            let radius: CGFloat = grabbed ? 8 : 5.5
            let knob = Path(ellipseIn: CGRect(x: x - radius, y: size.height / 2 - radius, width: 2 * radius, height: 2 * radius))
            context.fill(knob, with: .color(Palette.cream))
            context.stroke(knob, with: .color(Palette.gold), lineWidth: 1.5)
        }
        .animation(.smooth(duration: 0.15), value: grabbed)
    }
}
