import Foundation
import Observation

/// Réglages du banc d'essai, conservés d'un lancement à l'autre.
@Observable
final class RevealSettings {
    // Gratter
    var brushRadius: Double { didSet { save(brushRadius, .brushRadius) } }
    var scratchStrength: Double { didSet { save(scratchStrength, .scratchStrength) } }
    // Souffler
    var blowThresholdDB: Double { didSet { save(blowThresholdDB, .blowThresholdDB) } }
    var blowSpeed: Double { didSet { save(blowSpeed, .blowSpeed) } }
    // Secouer
    var shakeThresholdG: Double { didSet { save(shakeThresholdG, .shakeThresholdG) } }
    var shakeSpeed: Double { didSet { save(shakeSpeed, .shakeSpeed) } }
    // Fin
    /// 1 = auto-fin désactivée.
    var autoFinishThreshold: Double { didSet { save(autoFinishThreshold, .autoFinishThreshold) } }
    // Retours
    var hapticsEnabled: Bool { didSet { save(hapticsEnabled, .hapticsEnabled) } }
    var soundEnabled: Bool { didSet { save(soundEnabled, .soundEnabled) } }
    var debugOverlay: Bool { didSet { save(debugOverlay, .debugOverlay) } }

    @ObservationIgnored private let defaults: UserDefaults

    enum Key: String, CaseIterable {
        case brushRadius, scratchStrength, blowThresholdDB, blowSpeed, shakeThresholdG, shakeSpeed
        case autoFinishThreshold, hapticsEnabled, soundEnabled, debugOverlay
    }

    static let factory: [Key: Any] = [
        .brushRadius: 26.0,
        .scratchStrength: 0.75,
        .blowThresholdDB: -26.0,
        .blowSpeed: 1.0,
        .shakeThresholdG: 1.1,
        .shakeSpeed: 1.0,
        .autoFinishThreshold: 0.7,
        .hapticsEnabled: true,
        .soundEnabled: true,
        .debugOverlay: false,
    ]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: Dictionary(uniqueKeysWithValues: Self.factory.map { ($0.key.rawValue, $0.value) }))
        brushRadius = defaults.double(forKey: Key.brushRadius.rawValue)
        scratchStrength = defaults.double(forKey: Key.scratchStrength.rawValue)
        blowThresholdDB = defaults.double(forKey: Key.blowThresholdDB.rawValue)
        blowSpeed = defaults.double(forKey: Key.blowSpeed.rawValue)
        shakeThresholdG = defaults.double(forKey: Key.shakeThresholdG.rawValue)
        shakeSpeed = defaults.double(forKey: Key.shakeSpeed.rawValue)
        autoFinishThreshold = defaults.double(forKey: Key.autoFinishThreshold.rawValue)
        hapticsEnabled = defaults.bool(forKey: Key.hapticsEnabled.rawValue)
        soundEnabled = defaults.bool(forKey: Key.soundEnabled.rawValue)
        debugOverlay = defaults.bool(forKey: Key.debugOverlay.rawValue)
    }

    func restoreFactorySettings() {
        for key in Key.allCases { defaults.removeObject(forKey: key.rawValue) }
        let fresh = RevealSettings(defaults: defaults)
        brushRadius = fresh.brushRadius
        scratchStrength = fresh.scratchStrength
        blowThresholdDB = fresh.blowThresholdDB
        blowSpeed = fresh.blowSpeed
        shakeThresholdG = fresh.shakeThresholdG
        shakeSpeed = fresh.shakeSpeed
        autoFinishThreshold = fresh.autoFinishThreshold
        hapticsEnabled = fresh.hapticsEnabled
        soundEnabled = fresh.soundEnabled
        debugOverlay = fresh.debugOverlay
    }

    private func save(_ value: Any, _ key: Key) {
        defaults.set(value, forKey: key.rawValue)
    }
}
