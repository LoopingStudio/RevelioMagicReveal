import SwiftUI

/// La photo façon tirage, son masque, et les particules qui s'en échappent.
struct RevealCardView: View {
    let engine: RevealEngine
    let photo: UIImage

    var body: some View {
        photoArea
            .padding(11)
            .background(Palette.paper, in: .rect(cornerRadius: 16))
            .shadow(color: .black.opacity(0.45), radius: 26, y: 16)
            // L'animation ne porte que sur la lueur : appliquée à toute la carte, elle ferait fondre
            // les couches insérées ou retirées au même moment (morceaux de papier, particules).
            .animation(.smooth(duration: 0.8)) { content in
                content.shadow(color: Palette.gold.opacity(engine.phase == .revealed ? 0.45 : 0), radius: 40)
            }
    }

    private var photoArea: some View {
        let image = Image(uiImage: photo)
        return Color.clear
            .aspectRatio(CGFloat(RevealEngine.cardAspect), contentMode: .fit)
            .overlay {
                image
                    .resizable()
                    .scaledToFill()
            }
            .overlay {
                MaskLayer(engine: engine, photo: image)
            }
            .clipShape(.rect(cornerRadius: 5))
            .overlay {
                FreeLayers(engine: engine)
                    .padding(-RevealEngine.particleMargin)
                    .allowsHitTesting(false)
            }
            .contentShape(.rect)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        engine.scratch(at: value.location, time: value.time.timeIntervalSinceReferenceDate)
                    }
                    .onEnded { _ in engine.endScratch() }
            )
            .onGeometryChange(for: CGSize.self) { $0.size } action: { size in
                engine.cardSize = size
            }
            .accessibilityElement()
            .accessibilityLabel("Photo à révéler")
            .accessibilityValue("\(Int(engine.revealed * 100)) % révélé")
    }
}

/// Couches non rognées par la carte, posées sur la carte agrandie de `particleMargin` de chaque côté.
private struct FreeLayers: View {
    let engine: RevealEngine

    var body: some View {
        ZStack {
            MaskFreeLayer(engine: engine)
            ParticleCanvas(engine: engine)
        }
    }
}

struct ParticleCanvas: View {
    let engine: RevealEngine

    var body: some View {
        let _ = engine.frame
        let particles = engine.particles.particles
        Canvas(rendersAsynchronously: false) { context, _ in
            let margin = RevealEngine.particleMargin
            context.translateBy(x: margin, y: margin)
            for particle in particles {
                ParticleArt.draw(particle, in: &context)
            }
        }
    }
}
