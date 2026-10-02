import Foundation
import simd

/// Transforme le niveau du micro en intensité de souffle 0…1, lissée.
nonisolated struct BlowAnalyzer: Sendable {
    /// Niveau (dBFS) à partir duquel on considère qu'on souffle.
    var thresholdDB: Float
    /// Au-dessus du seuil, nombre de dB pour atteindre l'intensité maximale.
    var rangeDB: Float = 18
    var attack: Float = 0.04
    var release: Float = 0.22
    private(set) var strength: Float = 0

    init(thresholdDB: Float) {
        self.thresholdDB = thresholdDB
    }

    static func decibels(rms: Float) -> Float {
        20 * log10(max(rms, 1e-7))
    }

    static func rms(_ samples: UnsafeBufferPointer<Float>) -> Float {
        guard !samples.isEmpty else { return 0 }
        var sum: Float = 0
        for s in samples { sum += s * s }
        return (sum / Float(samples.count)).squareRoot()
    }

    @discardableResult
    mutating func process(levelDB: Float, dt: Float) -> Float {
        let target = min(max((levelDB - thresholdDB) / rangeDB, 0), 1)
        let tau = target > strength ? attack : release
        let k = 1 - exp(-max(dt, 0) / tau)
        strength += (target - strength) * k
        if strength < 0.002 { strength = 0 }
        return strength
    }

    mutating func reset() {
        strength = 0
    }
}

struct ShakeImpulse: Equatable, Sendable {
    /// 0…1
    var strength: Float
    /// Direction du coup dans le repère de l'écran (y vers le bas), normalisée.
    var direction: SIMD2<Float>
}

/// Repère les secousses dans l'accélération utilisateur (sans la gravité), en g.
struct ShakeAnalyzer: Sendable {
    var thresholdG: Float
    var cooldown: Float = 0.14
    private var sinceLastImpulse: Float = .greatestFiniteMagnitude

    init(thresholdG: Float) {
        self.thresholdG = thresholdG
    }

    /// `acceleration` dans le repère de l'appareil (x à droite, y vers le haut de l'appareil).
    mutating func process(acceleration: SIMD3<Float>, dt: Float) -> ShakeImpulse? {
        sinceLastImpulse += dt
        let magnitude = simd_length(acceleration)
        guard magnitude >= thresholdG, sinceLastImpulse >= cooldown else { return nil }
        sinceLastImpulse = 0
        let strength = min(1, 0.3 + (magnitude - thresholdG) / (thresholdG * 1.5))
        let planar = SIMD2(acceleration.x, -acceleration.y)
        let length = simd_length(planar)
        let direction = length > 0.05 ? planar / length : SIMD2<Float>(0, 1)
        return ShakeImpulse(strength: strength, direction: direction)
    }
}

/// Repère de l'appareil → repère de l'écran (y vers le bas).
func screenVector(fromDevice v: SIMD3<Float>) -> SIMD2<Float> {
    SIMD2(v.x, -v.y)
}
