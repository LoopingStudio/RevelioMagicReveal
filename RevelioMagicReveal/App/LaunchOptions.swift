import Foundation

/// Arguments de lancement pour vérifier un rendu sans geste réel, par exemple :
/// `-RNMask snow -RNGesture scratch -RNDemo partial`, ou `-RNMessage halo` pour l'écran du message.
struct LaunchOptions {
    var mask: MaskKind?
    var gesture: RevealGesture?
    var demo: DemoScript?
    var debugOverlay: Bool?
    /// Ouvre l'écran du message audio sur cette visualisation et lit l'exemple (captures).
    var message: AudioMessageModel.Visualization?

    init(defaults: UserDefaults = .standard) {
        mask = defaults.string(forKey: "RNMask").flatMap(MaskKind.init(rawValue:))
        gesture = defaults.string(forKey: "RNGesture").flatMap(RevealGesture.init(rawValue:))
        if let kind = defaults.string(forKey: "RNDemo").flatMap(DemoScript.Kind.init(rawValue:)) {
            let speed = defaults.object(forKey: "RNDemoSpeed") != nil ? Float(defaults.double(forKey: "RNDemoSpeed")) : 1
            demo = DemoScript(kind: kind, speed: speed)
        }
        debugOverlay = defaults.object(forKey: "RNDebug") != nil ? defaults.bool(forKey: "RNDebug") : nil
        message = defaults.string(forKey: "RNMessage").flatMap(AudioMessageModel.Visualization.init(rawValue:))
    }
}
