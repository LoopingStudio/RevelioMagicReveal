import CoreGraphics
import SwiftUI
import simd

/// Givre sur une vitre : photo floutée sous un voile laiteux et des plumes de glace ;
/// la zone dégagée garde un bord humide qui réfracte la photo nette.
struct FrostMaskView: View {
    let engine: RevealEngine
    let photo: Image

    var body: some View {
        let _ = engine.frame
        FrostGlass(
            photo: photo,
            crystals: FrostCrystalMap.image,
            field: engine.fieldArgument,
            fieldSize: engine.fieldSizeArgument,
            time: engine.time,
            gravity: engine.gravity,
            wetness: FrostLook.wetness(for: engine.gesture)
        )
        .allowsHitTesting(false)
    }
}
