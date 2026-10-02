import Foundation

/// Arguments de lancement pour vérifier un rendu sans geste réel, par exemple :
/// `-RNMask snow -RNGesture scratch -RNDemo partial`.
struct LaunchOptions {
    var mask: MaskKind?
    var gesture: RevealGesture?
    var demo: DemoScript?
    var debugOverlay: Bool?

    init(defaults: UserDefaults = .standard) {
        mask = defaults.string(forKey: "RNMask").flatMap(MaskKind.init(rawValue:))
        gesture = defaults.string(forKey: "RNGesture").flatMap(RevealGesture.init(rawValue:))
        if let kind = defaults.string(forKey: "RNDemo").flatMap(DemoScript.Kind.init(rawValue:)) {
            let speed = defaults.object(forKey: "RNDemoSpeed") != nil ? Float(defaults.double(forKey: "RNDemoSpeed")) : 1
            demo = DemoScript(kind: kind, speed: speed)
        }
        debugOverlay = defaults.object(forKey: "RNDebug") != nil ? defaults.bool(forKey: "RNDebug") : nil
    }
}
