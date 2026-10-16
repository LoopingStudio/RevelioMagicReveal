import PhotosUI
import SwiftUI

struct ContentView: View {
    let model: AppModel

    @State private var showsSettings = false
    @State private var showsMessage = false
    @State private var pickerItem: PhotosPickerItem?
    @Environment(\.scenePhase) private var scenePhase

    private var engine: RevealEngine { model.engine }

    var body: some View {
        ZStack {
            ChristmasBackground()

            VStack(spacing: 0) {
                header
                    .padding(.horizontal, 20)
                    .padding(.top, 6)

                Spacer(minLength: 12)

                RevealCardView(engine: engine, cover: model.media.cover, player: model.media.player) {
                    model.media.playFromStart()
                }
                .overlay {
                    // Animation limitée au voile : elle ne doit pas toucher la carte (changement de couverture, reset).
                    ZStack {
                        if model.media.isLoading {
                            LoadingVeil()
                                .transition(.opacity)
                        }
                    }
                    .animation(.smooth(duration: 0.25), value: model.media.isLoading)
                }
                .padding(.horizontal, 30)
                .overlay(alignment: .top) {
                    if model.settings.debugOverlay {
                        DebugPanel(engine: engine, settings: model.settings, inputs: model.inputs)
                            .padding(.top, -6)
                            .padding(.horizontal, 20)
                            .transition(.move(edge: .top).combined(with: .opacity))
                    }
                }

                Spacer(minLength: 12)

                hintRow
                    .padding(.horizontal, 24)
                    .padding(.bottom, 14)

                ChoiceControls(engine: engine)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
            }
        }
        .sheet(isPresented: $showsSettings) {
            SettingsSheet(settings: model.settings, media: model.media, audioHaptics: model.audioHaptics) {
                model.syncFeedbackSettings()
            } onContentChange: {
                engine.reset()
            } onPlayJingleBells: {
                model.feedback.playJingleBells()
            }
            .presentationDetents([.medium, .large])
            .presentationBackground(.thinMaterial)
        }
        .sheet(isPresented: $showsMessage, onDismiss: model.didHideAudioMessage) {
            AudioMessageSheet(model: model.audioMessage, cover: model.media.cover,
                              autoplay: model.launchMessage != nil)
                .presentationDetents([.large])
                .interactiveDismissDisabled(model.audioMessage.isRecording)
        }
        .onAppear {
            model.start()
            if model.launchMessage != nil { showAudioMessage() }
        }
        .task(id: engine.gesture) { await model.inputs.activate(for: engine.gesture) }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                Task { await model.inputs.activate(for: engine.gesture) }
            } else {
                model.inputs.suspend()
            }
        }
        .onChange(of: pickerItem) { _, item in
            guard let item else { return }
            Task {
                await model.media.load(item)
                engine.reset()
            }
        }
        .onChange(of: model.settings.micSource) {
            Task { await model.inputs.restartMicrophone(for: engine.gesture) }
        }
        .onChange(of: engine.phase) { _, phase in
            switch phase {
            case .revealed: model.media.playFromStart()
            case .covered: model.media.rewind()
            case .finishing: break
            }
        }
        .animation(.smooth(duration: 0.3), value: model.settings.debugOverlay)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Revelio")
                    .font(.system(.title2, design: .serif).weight(.semibold))
                    .foregroundStyle(Palette.cream)
                Text("Magic Reveal · Noël")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Palette.cream.opacity(0.6))
            }
            Spacer()
            PhotosPicker(selection: $pickerItem, matching: .videos, photoLibrary: .shared()) {
                Image(systemName: "film")
                    .font(.system(size: 17, weight: .semibold))
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .disabled(model.media.isLoading)
            .accessibilityLabel("Choisir une vidéo")

            Button(action: showAudioMessage) {
                Image(systemName: "waveform")
                    .font(.system(size: 17, weight: .semibold))
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .accessibilityLabel("Message audio")

            Button {
                showsSettings = true
            } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 17, weight: .semibold))
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .accessibilityLabel("Réglages")
        }
        .tint(Palette.cream)
    }

    private func showAudioMessage() {
        model.willShowAudioMessage()
        showsMessage = true
    }

    private var hintRow: some View {
        HStack(spacing: 12) {
            Group {
                if engine.phase == .revealed, model.media.kind == .video {
                    Label("Touche la carte pour revoir la vidéo", systemImage: "play.circle")
                } else if engine.phase == .revealed {
                    Label("Joyeux Noël !", systemImage: "sparkles")
                } else if engine.gesture == .blow, model.inputs.microphone == .denied {
                    Label("Micro refusé : autorise-le dans Réglages", systemImage: "mic.slash")
                } else if engine.gesture == .blow, model.inputs.microphone == .unavailable {
                    Label("Micro indisponible", systemImage: "mic.slash")
                } else {
                    Label(engine.gesture == .blow ? model.settings.mic.blowHint : engine.gesture.hint,
                          systemImage: engine.gesture.symbol)
                }
            }
            .font(.callout.weight(.medium))
            .foregroundStyle(Palette.cream.opacity(0.9))
            .lineLimit(2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentTransition(.opacity)
            .animation(.smooth, value: engine.phase)

            Button {
                engine.reset()
            } label: {
                Label("Recommencer", systemImage: "arrow.counterclockwise")
                    .font(.callout.weight(.semibold))
                    .padding(.horizontal, 4)
                    .frame(height: 32)
            }
            .buttonStyle(.glassProminent)
            .tint(engine.phase == .revealed ? Palette.gold : Palette.fir)
        }
    }
}

/// Voile posé sur la carte pendant l'import d'une vidéo (copie, téléchargement iCloud, première image).
private struct LoadingVeil: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 16)
            .fill(.black.opacity(0.5))
            .overlay {
                VStack(spacing: 12) {
                    ProgressView()
                        .controlSize(.large)
                        .tint(Palette.cream)
                    Text("Chargement de la vidéo…")
                        .font(.callout.weight(.medium))
                        .foregroundStyle(Palette.cream)
                }
            }
            .contentShape(.rect)
            .accessibilityElement(children: .combine)
    }
}

enum Palette {
    static let cream = Color(red: 0.98, green: 0.95, blue: 0.88)
    static let gold = Color(red: 0.86, green: 0.66, blue: 0.28)
    static let fir = Color(red: 0.12, green: 0.38, blue: 0.27)
    static let berry = Color(red: 0.72, green: 0.10, blue: 0.16)
    static let night = Color(red: 0.04, green: 0.07, blue: 0.16)
    static let paper = Color(red: 0.985, green: 0.975, blue: 0.95)
}
