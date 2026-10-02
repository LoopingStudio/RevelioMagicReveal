import SwiftUI

/// Nuit de Noël : dégradé bleu nuit → sapin, lueur dorée derrière la photo, neige légère.
struct ChristmasBackground: View {
    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(red: 0.03, green: 0.06, blue: 0.15), Color(red: 0.04, green: 0.11, blue: 0.16), Color(red: 0.03, green: 0.14, blue: 0.11)],
                startPoint: .top, endPoint: .bottom
            )
            RadialGradient(colors: [Palette.gold.opacity(0.16), .clear], center: .init(x: 0.5, y: 0.42), startRadius: 0, endRadius: 360)
            AmbientSnow()
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}

private struct AmbientSnow: View {
    private struct Flake {
        var x: Double, phase: Double, speed: Double, size: Double, drift: Double, opacity: Double
    }

    private static let flakes: [Flake] = {
        var rng = SeededRandom(seed: 99)
        return (0..<70).map { _ in
            Flake(x: Double(rng.float(0...1)), phase: Double(rng.float(0...1)), speed: Double(rng.float(0.025...0.07)),
                  size: Double(rng.float(1...3.2)), drift: Double(rng.float(6...22)), opacity: Double(rng.float(0.15...0.55)))
        }
    }()

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            Canvas { context, size in
                for flake in Self.flakes {
                    let progress = (flake.phase + t * flake.speed).truncatingRemainder(dividingBy: 1)
                    let y = progress * (size.height + 20) - 10
                    let x = flake.x * size.width + sin(t * 0.6 + flake.phase * 12) * flake.drift
                    let rect = CGRect(x: x, y: y, width: flake.size, height: flake.size)
                    context.fill(Path(ellipseIn: rect), with: .color(.white.opacity(flake.opacity)))
                }
            }
        }
    }
}
