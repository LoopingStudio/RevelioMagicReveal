import Foundation
import simd

/// Une cellule dont la couverture vient de baisser, en coordonnées normalisées de la carte.
struct ErodedCell: Equatable, Sendable {
    var position: SIMD2<Float>
    var amount: Float
}

/// Grille de couverture : 1 = couvert, 0 = révélé. Les valeurs ne font que descendre.
///
/// Coordonnées normalisées : x et y vont de 0 à 1 sur la carte (y vers le bas). Les distances
/// sont exprimées en largeurs de carte, `aspect` (largeur / hauteur) sert à garder le pinceau rond.
struct CoverageField: Sendable {
    let cols: Int
    let rows: Int
    let aspect: Float
    private(set) var values: [Float]

    init(cols: Int, rows: Int, aspect: Float) {
        precondition(cols > 1 && rows > 1)
        self.cols = cols
        self.rows = rows
        self.aspect = aspect
        values = Array(repeating: 1, count: cols * rows)
    }

    /// Grille aux cellules carrées pour une carte au ratio donné.
    init(columns: Int, aspect: Float) {
        self.init(cols: columns, rows: max(2, Int((Float(columns) / aspect).rounded())), aspect: aspect)
    }

    var count: Int { values.count }

    var revealedFraction: Float {
        1 - values.reduce(0, +) / Float(values.count)
    }

    subscript(col: Int, row: Int) -> Float {
        values[row * cols + col]
    }

    func cellCenter(_ index: Int) -> SIMD2<Float> {
        SIMD2((Float(index % cols) + 0.5) / Float(cols), (Float(index / cols) + 0.5) / Float(rows))
    }

    /// Échantillonnage bilinéaire, comme côté shader.
    func sample(at p: SIMD2<Float>) -> Float {
        let x = min(max(p.x * Float(cols) - 0.5, 0), Float(cols - 1))
        let y = min(max(p.y * Float(rows) - 0.5, 0), Float(rows - 1))
        let x0 = Int(x), y0 = Int(y)
        let x1 = min(x0 + 1, cols - 1), y1 = min(y0 + 1, rows - 1)
        let fx = x - Float(x0), fy = y - Float(y0)
        let top = self[x0, y0] * (1 - fx) + self[x1, y0] * fx
        let bottom = self[x0, y1] * (1 - fx) + self[x1, y1] * fx
        return top * (1 - fy) + bottom * fy
    }

    mutating func reset() {
        for i in values.indices { values[i] = 1 }
    }

    /// Pinceau doux : plein jusqu'à 55 % du rayon puis décroissance jusqu'au bord.
    @discardableResult
    mutating func erodeDisc(center: SIMD2<Float>, radius: Float, strength: Float) -> [ErodedCell] {
        guard radius > 0, strength > 0 else { return [] }
        let radiusY = radius * aspect
        let c0 = max(0, Int(((center.x - radius) * Float(cols)).rounded(.down)))
        let c1 = min(cols - 1, Int(((center.x + radius) * Float(cols)).rounded(.up)))
        let r0 = max(0, Int(((center.y - radiusY) * Float(rows)).rounded(.down)))
        let r1 = min(rows - 1, Int(((center.y + radiusY) * Float(rows)).rounded(.up)))
        guard c0 <= c1, r0 <= r1 else { return [] }

        var eroded: [ErodedCell] = []
        for row in r0...r1 {
            for col in c0...c1 {
                let index = row * cols + col
                let p = cellCenter(index)
                let dx = p.x - center.x
                let dy = (p.y - center.y) / aspect
                let d = (dx * dx + dy * dy).squareRoot()
                guard d < radius else { continue }
                let falloff = 1 - smoothstep(radius * 0.55, radius, d)
                let old = values[index]
                let new = max(0, old - strength * falloff)
                if new < old {
                    values[index] = new
                    eroded.append(ErodedCell(position: p, amount: old - new))
                }
            }
        }
        return eroded
    }

    /// Trait entre deux points : un disque tous les 35 % du rayon pour ne pas laisser de trous.
    @discardableResult
    mutating func erodeStroke(from a: SIMD2<Float>, to b: SIMD2<Float>, radius: Float, strength: Float) -> [ErodedCell] {
        let delta = SIMD2(b.x - a.x, (b.y - a.y) / aspect)
        let length = (delta.x * delta.x + delta.y * delta.y).squareRoot()
        let steps = max(1, Int((length / (radius * 0.35)).rounded(.up)))
        // Chaque disque n'applique qu'une part de la force, sinon un trait lent effacerait d'un coup.
        let perStep = strength * min(1, 1.5 / Float(steps).squareRoot())
        var eroded: [ErodedCell] = []
        for step in 1...steps {
            let t = Float(step) / Float(steps)
            eroded += erodeDisc(center: a + (b - a) * t, radius: radius, strength: perStep)
        }
        return eroded
    }

    /// Applique une carte de seuils : une cellule de seuil `t` descend à `(t − progress) / band`.
    @discardableResult
    mutating func apply(_ map: ThresholdMap, progress: Float) -> [ErodedCell] {
        precondition(map.thresholds.count == values.count)
        var eroded: [ErodedCell] = []
        for i in values.indices {
            let target = min(max((map.thresholds[i] - progress) / map.band, 0), 1)
            let old = values[i]
            if target < old {
                values[i] = target
                eroded.append(ErodedCell(position: cellCenter(i), amount: old - target))
            }
        }
        return eroded
    }

    /// Dissolution de fin : chaque cellule perd une fraction de ce qui lui reste.
    @discardableResult
    mutating func dissolve(by fraction: Float, minimumStep: Float = 0.02) -> [ErodedCell] {
        var eroded: [ErodedCell] = []
        for i in values.indices where values[i] > 0 {
            let old = values[i]
            let new = max(0, old - max(old * fraction, minimumStep))
            values[i] = new
            eroded.append(ErodedCell(position: cellCenter(i), amount: old - new))
        }
        return eroded
    }

    mutating func clear() {
        for i in values.indices { values[i] = 0 }
    }
}

func smoothstep(_ edge0: Float, _ edge1: Float, _ x: Float) -> Float {
    let t = min(max((x - edge0) / (edge1 - edge0), 0), 1)
    return t * t * (3 - 2 * t)
}
