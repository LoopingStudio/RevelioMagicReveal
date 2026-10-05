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

/// Seuils qui disent si un bloc ressemble à un souffle plutôt qu'à la voix.
///
/// Réglés le 2026-10-02 sur des prises réelles (iPhone, micro du bas) : souffle à −29…−44 dB, centre
/// 70-195 Hz, graves 81-99 %, harmonicité surtout < 0,45 ; voix grave (F0 ≈ 100 Hz) à −38…−52 dB,
/// centre 180-580 Hz, harmonicité 0,5-0,93 sur les voyelles, avec des fins de mots graves et faibles
/// (−45…−48 dB, centre 200-220 Hz) qui frôlent les seuils. Rejouer `scripts/analyse-souffle.py` sur
/// de nouvelles prises avant de les changer.
nonisolated struct BlowClassifier: Equatable, Sendable {
    /// Au-dessus, le bloc a une hauteur de note : voyelle, chant, musique.
    var maxHarmonicity: Float = 0.6
    /// En dessous, pas assez de grondement d'air : chuchotement, sifflante, bruit lointain.
    var minLowRatio: Float = 0.75
    /// Au-dessus, sifflante (« sss », « chhh ») plutôt que souffle.
    var maxHighRatio: Float = 0.05
    /// Au-dessus, le spectre est trop haut pour un souffle : c'est le critère qui écarte le mieux la voix.
    var maxCentroidHz: Float = 200
    /// Durée minimale de blocs « souffle » consécutifs avant d'ouvrir : écarte claquements et plosives.
    var minDuration: Float = 0.12
    /// Tolérance de blocs « non souffle » avant de refermer (pointes d'harmonicité pendant un souffle).
    var releaseDuration: Float = 0.18

    // Souffle direct, collé au micro : très fort, il peut saturer, et la distorsion fait monter le centre du
    // spectre et les aigus. D'où des critères spectraux plus larges, réservés aux blocs très forts (la voix
    // n'a pas dépassé −38 dB dans les prises réelles, même de près). L'harmonicité reste exigée : une voix
    // criée et saturée garde une hauteur de note (harmonicité ≈ 1) et doit rester rejetée.
    /// Niveau à partir duquel la voie « souffle direct » s'applique (indépendant du curseur de seuil).
    var directMinLevelDB: Float = -20
    var directMinLowRatio: Float = 0.6
    var directMaxHighRatio: Float = 0.15
    var directMaxCentroidHz: Float = 400
    var directMaxHarmonicity: Float = 0.7

    func isBlowLike(_ f: BlowFeatures, thresholdDB: Float) -> Bool {
        isNormalBlow(f, thresholdDB: thresholdDB) || isDirectBlow(f)
    }

    func isNormalBlow(_ f: BlowFeatures, thresholdDB: Float) -> Bool {
        f.levelDB >= thresholdDB && f.harmonicity <= maxHarmonicity && f.lowRatio >= minLowRatio
            && f.highRatio <= maxHighRatio && f.centroidHz <= maxCentroidHz
    }

    func isDirectBlow(_ f: BlowFeatures) -> Bool {
        f.levelDB >= directMinLevelDB && f.lowRatio >= directMinLowRatio && f.highRatio <= directMaxHighRatio
            && f.centroidHz <= directMaxCentroidHz && f.harmonicity <= directMaxHarmonicity
    }
}

/// Avec plusieurs canaux, on suit celui qui ressemble le plus à un souffle, à défaut le plus fort.
/// (Le mode « mesure » limite aujourd'hui la capture à un seul canal, le micro du bas.)
nonisolated enum BlowChannelChooser {
    static func choose(_ channels: [BlowFeatures], classifier: BlowClassifier, thresholdDB: Float) -> Int {
        var best = -1
        var bestLevel = -Float.infinity
        for (i, f) in channels.enumerated() where classifier.isBlowLike(f, thresholdDB: thresholdDB) && f.levelDB > bestLevel {
            best = i
            bestLevel = f.levelDB
        }
        if best >= 0 { return best }
        return channels.indices.max { channels[$0].levelDB < channels[$1].levelDB } ?? 0
    }
}

extension BlowAnalyzer {
    enum Mode: String, CaseIterable, Sendable {
        /// Tout son assez fort compte (premier comportement).
        case level
        /// Seul un son qui a la signature d'un souffle compte.
        case signature
    }
}

/// Porte temporelle du mode signature, avec hystérésis :
/// - pour ouvrir, il faut `minDuration` de blocs « souffle » **consécutifs** (un seul bloc « non souffle »
///   remet le compteur à zéro : des fins de mots graves dispersées ne s'additionnent pas) ;
/// - une fois ouverte, elle tolère `releaseDuration` de blocs « non souffle » (pointes d'harmonicité
///   pendant un vrai souffle) avant de se refermer.
nonisolated struct BlowGate: Sendable {
    var classifier = BlowClassifier()
    private(set) var isOpen = false
    private(set) var lastBlowLike = false
    private var consecutiveBlow: Float = 0
    private var otherTime: Float = 0

    mutating func process(_ f: BlowFeatures, thresholdDB: Float, dt: Float) -> Bool {
        lastBlowLike = classifier.isBlowLike(f, thresholdDB: thresholdDB)
        if isOpen {
            otherTime = lastBlowLike ? 0 : otherTime + dt
            if otherTime >= classifier.releaseDuration {
                isOpen = false
                consecutiveBlow = 0
            }
        } else {
            consecutiveBlow = lastBlowLike ? consecutiveBlow + dt : 0
            if consecutiveBlow >= classifier.minDuration {
                isOpen = true
                otherTime = 0
            }
        }
        return isOpen
    }

    mutating func reset() {
        isOpen = false
        lastBlowLike = false
        consecutiveBlow = 0
        otherTime = 0
    }
}
