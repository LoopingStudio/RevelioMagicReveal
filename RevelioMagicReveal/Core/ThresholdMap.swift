import Foundation
import simd

/// Carte de seuils pour les gestes globaux (souffler, secouer) : quand la progression du geste
/// dépasse le seuil d'une cellule, cette cellule se révèle sur une largeur `band`.
struct ThresholdMap: Sendable {
    var thresholds: [Float]
    var band: Float

    /// Progression à partir de laquelle tout est révélé.
    var completionProgress: Float {
        (thresholds.max() ?? 0) + band
    }

    /// Front qui part du bas-centre (le micro) et monte, avec un bord bruité.
    static func blowFront(cols: Int, rows: Int, aspect: Float, seed: UInt32) -> ThresholdMap {
        let origin = SIMD2<Float>(0.5, 1.04)
        var raw = [Float](repeating: 0, count: cols * rows)
        for row in 0..<rows {
            for col in 0..<cols {
                let p = SIMD2((Float(col) + 0.5) / Float(cols), (Float(row) + 0.5) / Float(rows))
                let dx = p.x - origin.x
                let dy = (p.y - origin.y) / aspect
                let distance = (dx * dx + dy * dy).squareRoot()
                let wobble = Noise.fbm(p * 3.2, seed: seed) * 2 - 1
                let grain = Noise.fbm(p * 14, seed: seed &+ 7) * 2 - 1
                raw[row * cols + col] = distance * (1 + 0.32 * wobble) + 0.035 * grain
            }
        }
        return ThresholdMap(thresholds: normalized(raw), band: 0.09)
    }

    /// Gros morceaux (Voronoï déformé) qui tombent chacun d'un bloc, dans un ordre aléatoire.
    static func shakeChunks(cols: Int, rows: Int, aspect: Float, seed: UInt32, chunkCount: Int = 26) -> ThresholdMap {
        var rng = SeededRandom(seed: seed)
        let seeds: [SIMD2<Float>] = (0..<chunkCount).map { _ in
            SIMD2(Float.random(in: 0...1, using: &rng), Float.random(in: 0...1, using: &rng))
        }
        // Les seuils sont répartis régulièrement puis mélangés : chaque secousse fait tomber à peu près autant de morceaux.
        var order = (0..<chunkCount).map { 0.04 + 0.92 * Float($0) / Float(max(1, chunkCount - 1)) }
        order.shuffle(using: &rng)

        var thresholds = [Float](repeating: 0, count: cols * rows)
        for row in 0..<rows {
            for col in 0..<cols {
                let p = SIMD2((Float(col) + 0.5) / Float(cols), (Float(row) + 0.5) / Float(rows))
                let warp = SIMD2(Noise.fbm(p * 4, seed: seed &+ 11), Noise.fbm(p * 4, seed: seed &+ 23)) - 0.5
                let q = p + warp * 0.12
                var best = Float.greatestFiniteMagnitude
                var bestIndex = 0
                for (i, s) in seeds.enumerated() {
                    let dx = q.x - s.x
                    let dy = (q.y - s.y) / aspect
                    let d = dx * dx + dy * dy
                    if d < best { best = d; bestIndex = i }
                }
                thresholds[row * cols + col] = order[bestIndex]
            }
        }
        return ThresholdMap(thresholds: thresholds, band: 0.035)
    }

    private static func normalized(_ values: [Float]) -> [Float] {
        guard let lo = values.min(), let hi = values.max(), hi > lo else { return values }
        return values.map { ($0 - lo) / (hi - lo) }
    }
}

/// Bruit de valeur déterministe, pour que les cartes soient reproductibles en test.
enum Noise {
    static func hash(_ x: Int32, _ y: Int32, seed: UInt32) -> Float {
        var h = UInt32(bitPattern: x) &* 0x8DA6B343
        h ^= UInt32(bitPattern: y) &* 0xD8163841
        h ^= seed &* 0xCB1AB31F
        h = (h ^ (h >> 13)) &* 0x5BD1E995
        h ^= h >> 15
        return Float(h & 0x00FF_FFFF) / Float(0x00FF_FFFF)
    }

    static func value(_ p: SIMD2<Float>, seed: UInt32) -> Float {
        let i = SIMD2<Float>(p.x.rounded(.down), p.y.rounded(.down))
        let f = p - i
        let u = f * f * (3 - 2 * f)
        let x = Int32(i.x), y = Int32(i.y)
        let a = hash(x, y, seed: seed), b = hash(x + 1, y, seed: seed)
        let c = hash(x, y + 1, seed: seed), d = hash(x + 1, y + 1, seed: seed)
        return (a * (1 - u.x) + b * u.x) * (1 - u.y) + (c * (1 - u.x) + d * u.x) * u.y
    }

    static func fbm(_ p: SIMD2<Float>, seed: UInt32, octaves: Int = 4) -> Float {
        var sum: Float = 0, amplitude: Float = 0.5, frequency: Float = 1, norm: Float = 0
        for o in 0..<octaves {
            sum += amplitude * value(p * frequency, seed: seed &+ UInt32(o) &* 131)
            norm += amplitude
            amplitude *= 0.5
            frequency *= 2
        }
        return sum / norm
    }
}

/// Générateur pseudo-aléatoire à graine (SplitMix64).
struct SeededRandom: RandomNumberGenerator, Sendable {
    private var state: UInt64

    init(seed: UInt32) {
        state = UInt64(seed) &+ 0x9E37_79B9_7F4A_7C15
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
