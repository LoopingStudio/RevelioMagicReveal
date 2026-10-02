import SwiftUI

struct SettingsSheet: View {
    @Bindable var settings: RevealSettings
    let media: MediaStore
    let onFeedbackChange: () -> Void
    /// Le contenu a changé : on recouvre la carte.
    let onContentChange: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Gratter") {
                    SliderRow(title: "Taille du doigt", value: $settings.brushRadius, range: 10...60, step: 1) { "\(Int($0)) pt" }
                    SliderRow(title: "Force", value: $settings.scratchStrength, range: 0.2...1, step: 0.05) { "\(Int($0 * 100)) %" }
                }
                Section {
                    Picker("Détection", selection: $settings.blowSignature) {
                        Text("Signature du souffle").tag(true)
                        Text("Volume seul").tag(false)
                    }
                    Picker("Micro", selection: $settings.micSource) {
                        ForEach(MicSource.allCases, id: \.rawValue) { source in
                            Text(source.title).tag(source.rawValue)
                        }
                    }
                    SliderRow(title: "Seuil du micro", value: $settings.blowThresholdDB, range: -55 ... -5, step: 1) { "\(Int($0)) dB" }
                    SliderRow(title: "Vitesse", value: $settings.blowSpeed, range: 0.3...3, step: 0.1) { String(format: "×%.1f", $0) }
                } header: {
                    Text("Souffler")
                } footer: {
                    Text("La signature du souffle ignore la voix et la musique. Seuil bas : un souffle léger suffit. Le mode debug montre les mesures en direct et permet d'enregistrer des échantillons pour régler la détection.")
                }
                Section {
                    SliderRow(title: "Seuil de secousse", value: $settings.shakeThresholdG, range: 0.4...3, step: 0.1) { String(format: "%.1f g", $0) }
                    SliderRow(title: "Vitesse", value: $settings.shakeSpeed, range: 0.3...3, step: 0.1) { String(format: "×%.1f", $0) }
                } header: {
                    Text("Secouer")
                }
                Section {
                    SliderRow(title: "Auto-fin", value: $settings.autoFinishThreshold, range: 0.3...1, step: 0.05) {
                        $0 >= 1 ? "désactivée" : "à \(Int($0 * 100)) %"
                    }
                } header: {
                    Text("Fin")
                } footer: {
                    Text("Au-delà de ce seuil, le reste du masque disparaît tout seul et la photo est célébrée.")
                }
                Section("Retours") {
                    Toggle("Haptique", isOn: $settings.hapticsEnabled)
                    Toggle("Son", isOn: $settings.soundEnabled)
                }
                Section("Contenu révélé") {
                    Button("Vidéo d'exemple") {
                        Task {
                            await media.useSampleVideo()
                            onContentChange()
                        }
                    }
                    Button("Photo d'exemple") {
                        media.useSamplePhoto()
                        onContentChange()
                    }
                }
                Section("Debug") {
                    Toggle("Panneau de debug", isOn: $settings.debugOverlay)
                    Button("Réglages d'usine", role: .destructive) { settings.restoreFactorySettings() }
                }
            }
            .navigationTitle("Réglages")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(role: .close) { dismiss() }
                }
            }
        }
        .onChange(of: settings.hapticsEnabled) { onFeedbackChange() }
        .onChange(of: settings.soundEnabled) { onFeedbackChange() }
    }
}

private struct SliderRow: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let format: (Double) -> String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                Text(format(value))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Slider(value: $value, in: range, step: step)
                .tint(Palette.gold)
        }
    }
}
