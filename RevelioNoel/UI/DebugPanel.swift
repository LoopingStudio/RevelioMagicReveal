import SwiftUI

/// Lectures en direct et simulation des gestes (indispensable en simulateur).
struct DebugPanel: View {
    let engine: RevealEngine
    let settings: RevealSettings

    @State private var shakeTask: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Révélé \(Int(engine.revealed * 100)) %")
                Spacer()
                Text(phaseLabel).foregroundStyle(.secondary)
            }
            switch engine.gesture {
            case .blow:
                MicMeter(levelDB: engine.blowLevelDB, thresholdDB: Float(settings.blowThresholdDB))
                Gauge(label: "Souffle", value: engine.blowStrength)
            case .shake:
                Gauge(label: "Dernière secousse", value: engine.lastShakeStrength)
            case .scratch:
                EmptyView()
            }
            HStack(spacing: 8) {
                if engine.gesture != .scratch {
                    Text("Maintenir : simuler")
                        .padding(.horizontal, 12)
                        .frame(height: 32)
                        .glassEffect(.regular.tint(Palette.fir).interactive(), in: .capsule)
                        .onLongPressGesture(minimumDuration: 30, maximumDistance: 80, perform: {}) { pressing in
                            simulate(pressing)
                        }
                }
                Button("Tout révéler") { engine.revealAll() }
                    .buttonStyle(.glass)
                    .frame(height: 32)
            }
        }
        .font(.caption.monospacedDigit())
        .foregroundStyle(Palette.cream)
        .padding(12)
        .glassEffect(in: .rect(cornerRadius: 16))
        .onDisappear { simulate(false) }
    }

    private var phaseLabel: String {
        switch engine.phase {
        case .covered: "couvert"
        case .finishing: "auto-fin…"
        case .revealed: "révélé"
        }
    }

    private func simulate(_ pressing: Bool) {
        switch engine.gesture {
        case .blow:
            engine.simulatedBlow = pressing ? 0.8 : 0
        case .shake:
            shakeTask?.cancel()
            shakeTask = nil
            guard pressing else { return }
            shakeTask = Task {
                var flip: Float = 1
                while !Task.isCancelled {
                    engine.shakeImpulse(ShakeImpulse(strength: 0.85, direction: SIMD2(flip, 0.25)))
                    flip = -flip
                    try? await Task.sleep(for: .milliseconds(350))
                }
            }
        case .scratch:
            break
        }
    }
}

private struct MicMeter: View {
    let levelDB: Float
    let thresholdDB: Float

    private let floorDB: Float = -80

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Micro \(Int(levelDB.rounded())) dB · seuil \(Int(thresholdDB)) dB")
            GeometryReader { proxy in
                let width = proxy.size.width
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.12))
                    Capsule().fill(levelDB >= thresholdDB ? Palette.gold : Palette.cream.opacity(0.6))
                        .frame(width: width * fraction(levelDB))
                    Rectangle().fill(Palette.berry)
                        .frame(width: 2)
                        .offset(x: width * fraction(thresholdDB) - 1)
                }
            }
            .frame(height: 6)
        }
    }

    private func fraction(_ db: Float) -> CGFloat {
        CGFloat(min(max((db - floorDB) / -floorDB, 0), 1))
    }
}

private struct Gauge: View {
    let label: String
    let value: Float

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("\(label) \(Int(value * 100)) %")
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.12))
                    Capsule().fill(Palette.gold).frame(width: proxy.size.width * CGFloat(min(max(value, 0), 1)))
                }
            }
            .frame(height: 6)
        }
    }
}
