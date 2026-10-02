import PhotosUI
import SwiftUI

struct ContentView: View {
    let model: AppModel

    @State private var showsSettings = false
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

                RevealCardView(engine: engine, photo: model.photos.image)
                    .padding(.horizontal, 30)
                    .overlay(alignment: .top) {
                        if model.settings.debugOverlay {
                            DebugPanel(engine: engine, settings: model.settings)
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
            SettingsSheet(settings: model.settings, photos: model.photos) {
                model.syncFeedbackSettings()
            }
            .presentationDetents([.medium, .large])
            .presentationBackground(.thinMaterial)
        }
        .onAppear { model.start() }
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
                await model.photos.load(item)
                engine.reset()
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
            PhotosPicker(selection: $pickerItem, matching: .images, photoLibrary: .shared()) {
                Image(systemName: "photo.on.rectangle")
                    .font(.system(size: 17, weight: .semibold))
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .accessibilityLabel("Choisir une photo")

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

    private var hintRow: some View {
        HStack(spacing: 12) {
            Group {
                if engine.phase == .revealed {
                    Label("Joyeux Noël !", systemImage: "sparkles")
                } else if engine.gesture == .blow, model.inputs.microphone == .denied {
                    Label("Micro refusé : autorise-le dans Réglages", systemImage: "mic.slash")
                } else if engine.gesture == .blow, model.inputs.microphone == .unavailable {
                    Label("Micro indisponible", systemImage: "mic.slash")
                } else {
                    Label(engine.gesture.hint, systemImage: engine.gesture.symbol)
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

enum Palette {
    static let cream = Color(red: 0.98, green: 0.95, blue: 0.88)
    static let gold = Color(red: 0.86, green: 0.66, blue: 0.28)
    static let fir = Color(red: 0.12, green: 0.38, blue: 0.27)
    static let berry = Color(red: 0.72, green: 0.10, blue: 0.16)
    static let night = Color(red: 0.04, green: 0.07, blue: 0.16)
    static let paper = Color(red: 0.985, green: 0.975, blue: 0.95)
}
