import SwiftUI

/// Écran « Message audio » : un même message vocal (l'exemple, ou un message enregistré ici) vu de
/// plusieurs façons, pour comparer.
struct AudioMessageSheet: View {
    @Bindable var model: AudioMessageModel
    let cover: UIImage
    var autoplay = false

    @State private var photo: MessagePhoto?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationStack {
            VStack(spacing: 18) {
                MessageStage(model: model, photo: photo)
                    .aspectRatio(1, contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.horizontal, 20)

                visualizationPicker

                MessageScrubber(model: model)
                    .padding(.horizontal, 20)

                actions
                    .padding(.horizontal, 20)
            }
            .padding(.top, 8)
            .padding(.bottom, 12)
            .background { ChristmasBackground() }
            .navigationTitle("Message audio")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(role: .close) { dismiss() }
                        .disabled(model.isRecording)
                }
            }
        }
        .task { photo = await MessagePhoto.prepare(cover) }
        .onAppear { model.open(autoplay: autoplay) }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { model.resume() } else { model.suspend() }
        }
        .sensoryFeedback(.selection, trigger: model.visualization)
    }

    private var visualizationPicker: some View {
        GlassEffectContainer(spacing: 6) {
            HStack(spacing: 6) {
                ForEach(AudioMessageModel.Visualization.allCases) { kind in
                    GlassChip(title: kind.title, symbol: kind.symbol, selected: kind == model.visualization) {
                        model.visualization = kind
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .disabled(model.isRecording)
    }

    private var actions: some View {
        HStack(spacing: 10) {
            CapsuleAction(title: "Exemple", symbol: "sparkles", highlighted: model.message?.source == .sample) {
                model.loadSample()
            }
            .disabled(model.isRecording)

            CapsuleAction(title: "Vibrations", symbol: "iphone.radiowaves.left.and.right",
                          highlighted: model.vibrations) {
                model.vibrations.toggle()
            }
            .accessibilityValue(model.vibrations ? "activées" : "coupées")

            CapsuleAction(title: model.isRecording ? "Terminer" : "Enregistrer",
                          symbol: model.isRecording ? "stop.fill" : "mic.fill",
                          highlighted: model.isRecording, tint: Palette.berry, highlightedText: Palette.cream) {
                model.toggleRecording()
            }
        }
    }
}

/// Bouton capsule en verre, teinté quand il est actif.
private struct CapsuleAction: View {
    let title: String
    let symbol: String
    let highlighted: Bool
    var tint = Palette.gold
    var highlightedText = Palette.night
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.callout.weight(.semibold))
                .labelStyle(.titleAndIcon)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .foregroundStyle(highlighted ? highlightedText : Palette.cream)
                .frame(maxWidth: .infinity, minHeight: 46)
                .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .glassEffect(highlighted ? .regular.tint(tint).interactive() : .regular.interactive(), in: .capsule)
        .contentTransition(.symbolEffect(.replace))
        .accessibilityAddTraits(highlighted ? .isSelected : [])
    }
}
