import Foundation

// Logique pure des retours : courbes, saveurs par masque, motifs haptiques décrits sans Core Haptics.
// Tout est `nonisolated` : testable hors main actor et utilisable depuis le thread audio.

// MARK: - Timbre

/// Saveur d'un masque, côté retours. Valeur brute stable : elle traverse le thread audio dans un atomique.
nonisolated enum FeedbackTimbre: UInt8, CaseIterable, Sendable {
    case frost, snow, paper, gold
}

// MARK: - Courbes

/// Correspondances gestes → intensités. Entrées et sorties normalisées 0…1 (netteté : contrôle −1…1).
nonisolated enum FeedbackCurves {
    /// En dessous, le doigt est considéré immobile : aucune texture.
    static let restSpeed: Float = 0.015

    /// Intensité de la texture haptique de grattage (contrôle d'intensité, multiplie le motif).
    /// La vitesse donne l'élan, la matière effacée donne le « mordant » : gratter une zone déjà
    /// révélée reste perceptible mais nettement plus lisse.
    static func scratchHapticIntensity(speed: Float, material: Float) -> Float {
        guard speed > restSpeed else { return 0 }
        let motion = 0.2 + 0.8 * pow(clamp01(speed), 0.6)
        return min(1, motion * (0.35 + 0.65 * clamp01(material)))
    }

    /// Contrôle de netteté (s'ajoute à celle du motif) : plus le doigt va vite, plus c'est net.
    static func scratchHapticSharpness(speed: Float, base: Float, slope: Float) -> Float {
        min(max(base + slope * clamp01(speed), -1), 1)
    }

    /// Gain du bruit de grattage. Sans matière à effacer, presque rien (on frotte la photo).
    static func scratchGain(speed: Float, material: Float) -> Float {
        guard speed > restSpeed else { return 0 }
        let motion = 0.12 + 0.88 * pow(clamp01(speed), 0.8)
        return motion * (0.1 + 0.9 * clamp01(material))
    }

    /// Brillance du timbre (ouvre les filtres) : un geste vif sonne plus aigu.
    static func scratchBrightness(speed: Float) -> Float {
        0.2 + 0.8 * pow(clamp01(speed), 0.7)
    }

    /// Grondement du souffle : nul sous un souffle à peine perceptible, plafonné pour rester doux
    /// (et limiter ce que le micro pourrait capter de la vibration).
    static func rumbleIntensity(strength: Float) -> Float {
        guard strength > 0.03 else { return 0 }
        return min(rumbleCeiling, 0.1 + 0.5 * pow(clamp01(strength), 0.85))
    }

    static let rumbleCeiling: Float = 0.55

    static func rumbleSharpness(strength: Float, base: Float) -> Float {
        min(max(base + 0.12 * clamp01(strength), -1), 1)
    }

    /// Impulsion d'une secousse.
    static func shakeIntensity(strength: Float) -> Float {
        0.45 + 0.55 * clamp01(strength)
    }

    /// Petite impulsion de morceaux qui tombent, selon la quantité libérée (cellules érodées).
    static func chunkIntensity(amount: Float) -> Float {
        0.2 + 0.4 * min(1, (max(amount, 0) / 400).squareRoot())
    }

    /// Amplitude du « whoosh » des morceaux qui tombent.
    static func whooshAmplitude(amount: Float) -> Float {
        0.2 + 0.55 * min(1, (max(amount, 0) / 500).squareRoot())
    }

    static func clamp01(_ x: Float) -> Float { min(max(x, 0), 1) }
}

// MARK: - Matière sous le doigt

/// Présence de matière effacée sous le doigt, lissée : attaque rapide, relâche plus lente.
nonisolated struct MaterialTracker: Sendable {
    /// Quantité érodée par échantillon tactile considérée comme « pleine matière ».
    var referenceAmount: Float = 3
    var attack: Float = 0.03
    var release: Float = 0.12
    private(set) var value: Float = 0

    @discardableResult
    mutating func update(erodedAmount: Float, dt: Float) -> Float {
        let target = FeedbackCurves.clamp01(erodedAmount / referenceAmount)
        let tau = target > value ? attack : release
        value += (target - value) * (1 - exp(-max(dt, 0) / tau))
        return value
    }

    mutating func reset() { value = 0 }
}

// MARK: - Cadence des impulsions

/// Accumule une quantité (matière effacée, cellules tombées) et ne libère une impulsion qu'au-delà
/// d'un seuil, jamais plus souvent que `minInterval`.
nonisolated struct ImpulseGate: Sendable {
    var threshold: Float
    var minInterval: Double
    private(set) var accumulated: Float = 0
    private var lastFire: Double = -.infinity

    init(threshold: Float, minInterval: Double) {
        self.threshold = threshold
        self.minInterval = minInterval
    }

    /// Renvoie la quantité libérée si une impulsion doit partir maintenant.
    mutating func add(_ amount: Float, at time: Double) -> Float? {
        // Plafond : une grosse rafale ne doit pas laisser un arriéré d'impulsions.
        accumulated = min(accumulated + max(amount, 0), threshold * 4)
        guard accumulated >= threshold, time - lastFire >= minInterval else { return nil }
        let released = accumulated
        accumulated = 0
        lastFire = time
        return released
    }

    mutating func reset() {
        accumulated = 0
        lastFire = -.infinity
    }
}

/// Limite l'envoi de paramètres dynamiques au moteur haptique (les appels arrivent jusqu'à 120 Hz).
nonisolated struct ParameterThrottle: Sendable {
    var minInterval: Double
    var epsilon: Float = 0.01
    private var lastTime: Double = -.infinity
    private var last = SIMD2<Float>(-10, -10)

    init(minInterval: Double) {
        self.minInterval = minInterval
    }

    mutating func shouldSend(_ values: SIMD2<Float>, at time: Double) -> Bool {
        let delta = max(abs(values.x - last.x), abs(values.y - last.y))
        guard delta > 0 else { return false }
        // Le passage à zéro (et le départ de zéro) part tout de suite : c'est ce qu'on sent le plus.
        let crossesZero = (values.x == 0) != (last.x == 0)
        guard crossesZero || (time - lastTime >= minInterval && delta >= epsilon) else { return false }
        last = values
        lastTime = time
        return true
    }

    mutating func reset() {
        lastTime = -.infinity
        last = SIMD2(-10, -10)
    }
}

// MARK: - Aléa déterministe

/// Petit générateur xorshift, sans allocation : utilisable sur le thread audio.
nonisolated struct FeedbackRandom: Sendable {
    private var state: UInt32

    init(seed: UInt32) {
        state = seed == 0 ? 0x9E37_79B9 : seed
    }

    mutating func next() -> UInt32 {
        state ^= state << 13
        state ^= state >> 17
        state ^= state << 5
        return state
    }

    /// 0 ≤ x < 1
    mutating func uniform() -> Float {
        Float(next() >> 8) * (1.0 / 16_777_216.0)
    }

    /// −1 ≤ x < 1
    mutating func bipolar() -> Float {
        uniform() * 2 - 1
    }

    mutating func value(in range: ClosedRange<Float>) -> Float {
        range.lowerBound + (range.upperBound - range.lowerBound) * uniform()
    }

    mutating func integer(in range: ClosedRange<Int>) -> Int {
        range.lowerBound + Int(next() % UInt32(range.count))
    }
}

// MARK: - Motifs haptiques (description)

/// Un évènement haptique décrit sans Core Haptics (testable), converti par `HapticPlayer`.
nonisolated struct HapticEventSpec: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case transient
        case continuous(duration: Double)
    }

    var kind: Kind
    var time: Double
    var intensity: Float
    var sharpness: Float

    var end: Double {
        switch kind {
        case .transient: time
        case .continuous(let duration): time + duration
        }
    }
}

/// Texture de grattage en boucle : un corps continu + des grains (transitoires) pseudo-aléatoires.
/// L'intensité et la netteté globales sont ensuite pilotées en direct par la vitesse du doigt.
nonisolated struct ScratchTexture: Sendable {
    var loopDuration: Double = 2
    var bodyIntensity: Float
    var bodySharpness: Float
    /// Intervalle moyen entre deux grains (ou deux grappes).
    var grainInterval: Double
    /// Variation de l'intervalle, en fraction (0 = régulier).
    var grainJitter: Double
    var grainIntensity: ClosedRange<Float>
    var grainSharpness: ClosedRange<Float>
    /// Grains par grappe : > 1 pour un froissement irrégulier (papier).
    var clusterSize: ClosedRange<Int> = 1...1
    var clusterSpacing: Double = 0.016
    /// Un grain sur `accentEvery` est un accent (craquement du givre). 0 = aucun.
    var accentEvery: Int = 0
    var accentIntensity: Float = 1
    var accentSharpness: Float = 1

    func events(seed: UInt32 = 7) -> [HapticEventSpec] {
        var rng = FeedbackRandom(seed: seed)
        var events = [HapticEventSpec(kind: .continuous(duration: loopDuration), time: 0,
                                      intensity: bodyIntensity, sharpness: bodySharpness)]
        let lastTime = loopDuration - 0.004
        var t = grainInterval * Double(rng.uniform()) * 0.5
        var count = 0
        while t < lastTime {
            let size = rng.integer(in: clusterSize)
            var grainTime = t
            for index in 0..<size {
                if index > 0 { grainTime += clusterSpacing * Double(0.7 + 0.6 * rng.uniform()) }
                guard grainTime < lastTime else { break }
                count += 1
                let accent = accentEvery > 0 && count % accentEvery == 0
                events.append(HapticEventSpec(
                    kind: .transient, time: grainTime,
                    intensity: accent ? accentIntensity : rng.value(in: grainIntensity),
                    sharpness: accent ? accentSharpness : rng.value(in: grainSharpness)))
            }
            t = grainTime + grainInterval * (1 + grainJitter * Double(rng.bipolar()))
        }
        return events
    }
}

/// Impulsions liées à la matière effacée pendant le grattage (froissements du papier, craquements du givre).
nonisolated struct CrinkleSpec: Sendable {
    var threshold: Float
    var minInterval: Double
    var intensity: ClosedRange<Float>
    var sharpness: Float
}

/// Tout ce qui fait la saveur d'un masque côté retours.
nonisolated struct MaskFeel: Sendable {
    var timbre: FeedbackTimbre
    var texture: ScratchTexture
    /// Contrôle de netteté à vitesse nulle, et ce qu'on y ajoute à pleine vitesse.
    var sharpnessBase: Float
    var sharpnessSpeed: Float
    var crinkle: CrinkleSpec?
    /// Netteté des impulsions de secousse et de morceaux.
    var impulseSharpness: Float
    /// Durée de la « queue » sourde après l'impulsion (poids de ce qui tombe).
    var impulseTail: Double
    var rumbleSharpness: Float

    static func of(_ timbre: FeedbackTimbre) -> MaskFeel {
        switch timbre {
        case .gold:
            // Ticket à gratter : granuleux, dense et net.
            MaskFeel(timbre: .gold,
                     texture: ScratchTexture(bodyIntensity: 0.42, bodySharpness: 0.62,
                                             grainInterval: 0.019, grainJitter: 0.35,
                                             grainIntensity: 0.35...0.7, grainSharpness: 0.82...1),
                     sharpnessBase: -0.12, sharpnessSpeed: 0.3, crinkle: nil,
                     impulseSharpness: 0.75, impulseTail: 0.03, rumbleSharpness: 0.25)
        case .snow:
            // Neige : doux et feutré, un corps rond et quelques grains mous.
            MaskFeel(timbre: .snow,
                     texture: ScratchTexture(bodyIntensity: 0.75, bodySharpness: 0.06,
                                             grainInterval: 0.055, grainJitter: 0.5,
                                             grainIntensity: 0.12...0.28, grainSharpness: 0.05...0.2),
                     sharpnessBase: -0.05, sharpnessSpeed: 0.08, crinkle: nil,
                     impulseSharpness: 0.22, impulseTail: 0.09, rumbleSharpness: 0.05)
        case .frost:
            // Givre : cristallin, petits cliquetis très nets et craquements.
            MaskFeel(timbre: .frost,
                     texture: ScratchTexture(bodyIntensity: 0.3, bodySharpness: 0.55,
                                             grainInterval: 0.026, grainJitter: 0.3,
                                             grainIntensity: 0.28...0.5, grainSharpness: 0.88...1,
                                             accentEvery: 9, accentIntensity: 0.85, accentSharpness: 1),
                     sharpnessBase: -0.05, sharpnessSpeed: 0.25,
                     crinkle: CrinkleSpec(threshold: 26, minInterval: 0.09, intensity: 0.45...0.8, sharpness: 1),
                     impulseSharpness: 0.9, impulseTail: 0.02, rumbleSharpness: 0.18)
        case .paper:
            // Papier cadeau : froissé, grappes irrégulières et petites impulsions.
            MaskFeel(timbre: .paper,
                     texture: ScratchTexture(bodyIntensity: 0.38, bodySharpness: 0.35,
                                             grainInterval: 0.06, grainJitter: 0.6,
                                             grainIntensity: 0.25...0.75, grainSharpness: 0.4...0.7,
                                             clusterSize: 2...4, clusterSpacing: 0.016),
                     sharpnessBase: -0.08, sharpnessSpeed: 0.22,
                     crinkle: CrinkleSpec(threshold: 14, minInterval: 0.05, intensity: 0.4...0.85, sharpness: 0.55),
                     impulseSharpness: 0.5, impulseTail: 0.05, rumbleSharpness: 0.12)
        }
    }
}

/// Motifs ponctuels.
nonisolated enum HapticScripts {
    /// Un choc : transitoire + courte queue sourde qui donne du poids.
    static func impact(intensity: Float, sharpness: Float, tail: Double) -> [HapticEventSpec] {
        var events = [HapticEventSpec(kind: .transient, time: 0, intensity: intensity, sharpness: sharpness)]
        if tail > 0 {
            events.append(HapticEventSpec(kind: .continuous(duration: tail), time: 0,
                                          intensity: intensity * 0.5, sharpness: sharpness * 0.35))
        }
        return events
    }

    /// Célébration calée sur le carillon : une impulsion par note de l'arpège, de plus en plus
    /// forte et nette, un accord final qui s'épanouit puis quelques scintillements.
    static func celebration(score: [CelebrationNote] = CelebrationScore.notes) -> [HapticEventSpec] {
        let onsets = CelebrationScore.onsets(of: score)
        guard let chord = onsets.last else { return [] }
        let arpeggio = onsets.dropLast()
        var events: [HapticEventSpec] = []
        for (index, time) in arpeggio.enumerated() {
            let progress = arpeggio.count > 1 ? Float(index) / Float(arpeggio.count - 1) : 1
            events.append(HapticEventSpec(kind: .transient, time: time,
                                          intensity: 0.42 + 0.4 * progress, sharpness: 0.45 + 0.4 * progress))
        }
        events.append(HapticEventSpec(kind: .transient, time: chord, intensity: 1, sharpness: 0.85))
        // Épanouissement : paliers décroissants (plus prévisible qu'une enveloppe implicite).
        let steps: [Float] = [0.55, 0.42, 0.3, 0.2, 0.1]
        for (index, level) in steps.enumerated() {
            events.append(HapticEventSpec(kind: .continuous(duration: 0.07), time: chord + 0.01 + Double(index) * 0.07,
                                          intensity: level, sharpness: 0.6))
        }
        for (index, level) in [Float(0.5), 0.38, 0.26].enumerated() {
            events.append(HapticEventSpec(kind: .transient, time: chord + 0.43 + Double(index) * 0.14,
                                          intensity: level, sharpness: 1))
        }
        return events.sorted { $0.time < $1.time }
    }
}

// MARK: - Partition de la célébration

/// Une note du carillon : partagée par le son et l'haptique pour qu'ils tombent ensemble.
nonisolated struct CelebrationNote: Equatable, Sendable {
    var time: Double
    var frequency: Double
    var velocity: Float
    /// −1 (gauche) … 1 (droite)
    var pan: Float
}

nonisolated enum CelebrationScore {
    /// Arpège montant de sol majeur, puis accord final scintillant.
    static let notes: [CelebrationNote] = [
        CelebrationNote(time: 0.00, frequency: 783.99, velocity: 0.55, pan: -0.5),   // sol 5
        CelebrationNote(time: 0.09, frequency: 987.77, velocity: 0.62, pan: -0.25),  // si 5
        CelebrationNote(time: 0.18, frequency: 1174.66, velocity: 0.7, pan: 0),      // ré 6
        CelebrationNote(time: 0.27, frequency: 1567.98, velocity: 0.8, pan: 0.25),   // sol 6
        CelebrationNote(time: 0.36, frequency: 1975.53, velocity: 0.88, pan: 0.5),   // si 6
        CelebrationNote(time: 0.52, frequency: 1567.98, velocity: 0.7, pan: -0.35),  // accord : sol 6
        CelebrationNote(time: 0.52, frequency: 2349.32, velocity: 0.75, pan: 0.35),  // ré 7
        CelebrationNote(time: 0.535, frequency: 3135.96, velocity: 0.55, pan: 0),    // sol 7
    ]

    /// Attaques distinctes (les notes d'un même accord, à moins de 30 ms, n'en font qu'une).
    static func onsets(of notes: [CelebrationNote]) -> [Double] {
        var result: [Double] = []
        for time in notes.map(\.time).sorted() where result.last.map({ time - $0 > 0.03 }) ?? true {
            result.append(time)
        }
        return result
    }
}
