import CoreGraphics
import Foundation
import SwiftUI
import simd

/// Ticket à gratter doré : feuille métallisée brossée, motifs embossés, lettrage poli miroir.
///
/// La peau (`GoldSkin`) code le relief, le poli et l'encre dans ses canaux ; le shader `rnGold`
/// l'éclaire comme du métal et la découpe selon la carte de couverture.
struct GoldMaskView: View {
    let engine: RevealEngine
    @State private var sheen = GoldSheenTracker()

    init(engine: RevealEngine) {
        self.engine = engine
    }

    var body: some View {
        let _ = engine.frame
        let light = sheen.update(gravity: engine.gravity, time: engine.time)
        let dissolve = sheen.dissolve(phase: engine.phase, time: engine.time)
        GoldSkin()
            .layerEffect(
                ShaderLibrary.rnGold(
                    .boundingRect,
                    engine.fieldArgument,
                    engine.fieldSizeArgument,
                    .float(engine.time),
                    .float2(light.x, light.y),
                    .float(dissolve)
                ),
                maxSampleOffset: CGSize(width: 1, height: 1)
            )
            .allowsHitTesting(false)
    }
}

/// Garde l'état d'une image à l'autre (référence : la vue est recréée à chaque tick).
final class GoldSheenTracker {
    private var sheen = GoldSheen()
    private var crumble = GoldCrumble()

    func update(gravity: SIMD2<Float>, time: Float) -> SIMD2<Float> {
        sheen.update(gravity: gravity, time: time)
    }

    func dissolve(phase: RevealPhase, time: Float) -> Float {
        crumble.update(phase: phase, time: time)
    }
}

/// Progression (0…1) de l'effritement de fin, montée en douceur dès que l'auto-fin démarre.
struct GoldCrumble: Sendable {
    /// Durée de la montée, en secondes : la déchirure grossit sans à-coup.
    static let ramp: Float = 0.3

    private var startedAt: Float?

    mutating func update(phase: RevealPhase, time: Float) -> Float {
        guard phase != .covered else {
            startedAt = nil
            return 0
        }
        let start = startedAt ?? time
        startedAt = start
        return min(1, max(0, (time - start) / Self.ramp))
    }
}

/// Position du reflet principal, en coordonnées normalisées de la carte (peut sortir de 0…1).
///
/// Le reflet file vers le côté relevé quand on incline le téléphone, et descend quand on le
/// couche. La gravité est lissée : le moteur la remplace par (0, 0.35) d'un coup quand le
/// téléphone passe à plat, il ne faut pas que le reflet saute.
struct GoldSheen: Sendable {
    /// Constante de temps du lissage, en secondes.
    static let response: Float = 0.12

    /// Dérive lente du reflet. En simulateur la gravité reste (0, 1) : la dérive porte l'animation.
    static let driftAmplitude: Float = {
        #if targetEnvironment(simulator)
        0.32
        #else
        0.07
        #endif
    }()

    private(set) var smoothedGravity: SIMD2<Float>?
    private var lastTime: Float?

    mutating func update(gravity: SIMD2<Float>, time: Float) -> SIMD2<Float> {
        if let previous = smoothedGravity, let t0 = lastTime {
            let dt = max(0, time - t0)
            let k = 1 - exp(-dt / Self.response)
            smoothedGravity = previous + (gravity - previous) * k
        } else {
            smoothedGravity = gravity
        }
        lastTime = time
        return Self.light(gravity: smoothedGravity ?? gravity, time: time)
    }

    static func light(gravity: SIMD2<Float>, time: Float, drift: Float = driftAmplitude) -> SIMD2<Float> {
        let tiltX = min(max(gravity.x, -1), 1)
        // 1 = téléphone debout, ≈ 0.35 à plat (valeur plancher du moteur).
        let upright = min(max(gravity.y, -1), 1)
        let base = SIMD2(0.5 - tiltX * 0.85, 0.16 + (1 - upright) * 0.75)
        let wander = SIMD2(sin(time * 0.43) * 0.9, sin(time * 0.29 + 1.3) * 0.5) * drift
        return base + wander
    }
}
