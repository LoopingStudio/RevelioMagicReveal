import SwiftUI

/// Lectures en direct et simulation des gestes (indispensable en simulateur).
struct DebugPanel: View {
    let engine: RevealEngine
    let settings: RevealSettings
    let inputs: InputCoordinator

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
                BlowSignatureReadout(features: engine.blowFeatures, classifier: engine.blowClassifier,
                                     signatureMode: settings.blowSignature, gateOpen: engine.blowGateOpen,
                                     microphoneName: inputs.microphoneName)
                BlowRecordingControls(inputs: inputs)
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

/// Les trois mesures qui décident « souffle ou pas », comparées à leurs seuils.
private struct BlowSignatureReadout: View {
    let features: BlowFeatures
    let classifier: BlowClassifier
    let signatureMode: Bool
    let gateOpen: Bool
    let microphoneName: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 10) {
                criterion("Harmon.", value: String(format: "%.2f", features.harmonicity),
                          ok: features.harmonicity <= classifier.maxHarmonicity)
                criterion("Graves", value: "\(Int(features.lowRatio * 100)) %", ok: features.lowRatio >= classifier.minLowRatio)
                criterion("Aigus", value: "\(Int(features.highRatio * 100)) %", ok: features.highRatio <= classifier.maxHighRatio)
            }
            Text(verdict)
                .foregroundStyle(gateOpen ? Palette.gold : Palette.cream.opacity(0.7))
        }
    }

    private var verdict: String {
        let mic = microphoneName.isEmpty ? "" : " · micro \(microphoneName)"
        guard signatureMode else { return "Mode volume seul\(mic)" }
        return (gateOpen ? "Souffle reconnu" : "Pas un souffle") + mic
    }

    private func criterion(_ name: String, value: String, ok: Bool) -> some View {
        HStack(spacing: 3) {
            Image(systemName: ok ? "checkmark.circle.fill" : "xmark.circle")
                .foregroundStyle(ok ? Palette.gold : Palette.cream.opacity(0.5))
            Text("\(name) \(value)")
        }
    }
}

/// Enregistrements étiquetés de 5 s pour régler la détection, et partage des fichiers.
private struct BlowRecordingControls: View {
    let inputs: InputCoordinator

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let label = inputs.recordingLabel {
                Label("Enregistrement « \(label.title) » en cours (5 s)…", systemImage: "record.circle")
                    .foregroundStyle(Palette.berry)
                    .symbolEffect(.pulse)
            } else {
                Text("Enregistrer 5 s :")
            }
            HStack(spacing: 6) {
                ForEach(BlowRecorder.Label.allCases, id: \.self) { label in
                    Button(label.title) { inputs.record(label) }
                        .buttonStyle(.glass)
                        .disabled(inputs.recordingLabel != nil || inputs.microphone != .listening)
                }
            }
            if !inputs.recordings.isEmpty {
                HStack(spacing: 6) {
                    ShareLink(items: inputs.recordings) {
                        Label("Partager (\(inputs.recordings.count / 2))", systemImage: "square.and.arrow.up")
                    }
                    .buttonStyle(.glass)
                    Button("Effacer", role: .destructive) { inputs.deleteRecordings() }
                        .buttonStyle(.glass)
                }
            }
        }
    }
}
