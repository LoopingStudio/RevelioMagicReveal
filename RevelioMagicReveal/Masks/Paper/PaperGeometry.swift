import CoreGraphics
import Foundation
import simd

/// Une arête déchirée que le morceau partage avec un voisin.
struct PaperEdge: Sendable {
    /// Morceau de l'autre côté de l'arête.
    var neighbor: Int
    /// Ligne dentelée dans le sens de parcours du contour du morceau, extrémités comprises.
    var points: [SIMD2<Float>]
    /// Normale unitaire tournée vers l'intérieur du morceau, une par point.
    var inward: [SIMD2<Float>]
}

/// Un morceau de papier : cellule de Voronoï aux arêtes déchirées.
///
/// Coordonnées en **unités de largeur de carte** : x va de 0 à 1, y de 0 à 1 / aspect (vers le bas),
/// pour que les distances valent la même chose dans les deux directions.
struct PaperPiece: Sendable {
    var site: SIMD2<Float>
    /// Contour fermé, dentelé (le premier point n'est pas répété à la fin).
    var outline: [SIMD2<Float>]
    var centroid: SIMD2<Float>
    var area: Float
    /// Distance maximale du centroïde au contour.
    var radius: Float
    /// Arêtes partagées avec un voisin ; les bords de la carte restent droits et n'y figurent pas.
    var edges: [PaperEdge]
    /// Points de détection, en coordonnées normalisées de la carte de couverture (0…1 sur les deux axes).
    var samples: [SIMD2<Float>]
}

/// Découpe déterministe de la feuille : Voronoï sur grille jittérée, arêtes partagées déchirées.
enum PaperCutter {
    /// Pas des points de détection, en largeurs de carte (≈ 7 pt sur une carte de 330 pt).
    static let sampleSpacing: Float = 1.0 / 46

    static func cut(aspect: Float, seed: UInt32, columns: Int = 6) -> [PaperPiece] {
        let height = 1 / aspect
        let rows = max(2, Int((Float(columns) * height).rounded()))
        let sites = jitteredSites(columns: columns, rows: rows, height: height, seed: seed)
        let rect: [SIMD2<Float>] = [SIMD2(0, 0), SIMD2(1, 0), SIMD2(1, height), SIMD2(0, height)]

        // 1. Cellules : le rectangle de la carte rogné par les demi-plans médiateurs.
        let rawCells: [[SIMD2<Float>]] = sites.indices.map { i in
            var polygon = rect
            for j in sites.indices where j != i {
                let normal = sites[j] - sites[i]
                polygon = clip(polygon, keepingBelow: (sites[i] + sites[j]) * 0.5, normal: normal)
                if polygon.isEmpty { break }
            }
            return polygon
        }

        // 2. Sommets communs : deux cellules voisines calculent le même sommet à 1e-6 près, on les fusionne.
        let (vertices, cells) = weldVertices(rawCells, tolerance: 2e-4)

        // 3. Une ligne déchirée par arête partagée, générée une seule fois et lue dans les deux sens.
        var tears: [EdgeKey: [SIMD2<Float>]] = [:]
        func tear(_ a: Int, _ b: Int) -> [SIMD2<Float>] {
            let key = EdgeKey(a, b)
            if let line = tears[key] { return key.low == a ? line : line.reversed() }
            let line = tornLine(from: vertices[key.low], to: vertices[key.high], seed: seed, key: key)
            tears[key] = line
            return key.low == a ? line : line.reversed()
        }

        var pieces: [PaperPiece] = []
        pieces.reserveCapacity(sites.count)
        for (i, cell) in cells.enumerated() {
            var outline: [SIMD2<Float>] = []
            var edges: [PaperEdge] = []
            for k in cell.indices {
                let a = cell[k], b = cell[(k + 1) % cell.count]
                let pa = vertices[a], pb = vertices[b]
                if onSameBorder(pa, pb, height: height) {
                    outline.append(pa)
                    continue
                }
                let middle = (pa + pb) * 0.5
                let neighbor = nearestSite(to: middle, in: sites, excluding: i)
                let line = tear(a, b)
                outline.append(contentsOf: line.dropLast())
                edges.append(PaperEdge(neighbor: neighbor, points: line,
                                       inward: inwardNormals(line, toward: sites[i])))
            }
            let (area, centroid) = areaAndCentroid(outline)
            let radius = outline.reduce(Float(0)) { max($0, simd_distance($1, centroid)) }
            pieces.append(PaperPiece(site: sites[i], outline: outline, centroid: centroid, area: area,
                                     radius: radius, edges: edges, samples: []))
        }

        // 4. Points de détection : un réseau régulier, chaque point appartenant au germe le plus proche.
        let step = sampleSpacing
        var y = step * 0.5
        while y < height {
            var x = step * 0.5
            while x < 1 {
                let p = SIMD2(x, y)
                let owner = nearestSite(to: p, in: sites, excluding: -1)
                pieces[owner].samples.append(SIMD2(x, y * aspect))
                x += step
            }
            y += step
        }
        for i in pieces.indices where pieces[i].samples.isEmpty {
            pieces[i].samples = [SIMD2(pieces[i].site.x, pieces[i].site.y * aspect)]
        }
        return pieces
    }

    // MARK: - Germes

    static func jitteredSites(columns: Int, rows: Int, height: Float, seed: UInt32) -> [SIMD2<Float>] {
        var rng = SeededRandom(seed: seed &* 0x9E37 &+ 0x51)
        let cw = 1 / Float(columns), ch = height / Float(rows)
        var sites: [SIMD2<Float>] = []
        sites.reserveCapacity(columns * rows)
        for row in 0..<rows {
            for col in 0..<columns {
                let jx = Float.random(in: -0.42...0.42, using: &rng)
                let jy = Float.random(in: -0.42...0.42, using: &rng)
                sites.append(SIMD2((Float(col) + 0.5 + jx) * cw, (Float(row) + 0.5 + jy) * ch))
            }
        }
        return sites
    }

    // MARK: - Voronoï

    /// Sutherland–Hodgman : garde la partie du polygone où `(p − m) · normal ≤ 0`.
    static func clip(_ polygon: [SIMD2<Float>], keepingBelow m: SIMD2<Float>, normal: SIMD2<Float>) -> [SIMD2<Float>] {
        guard !polygon.isEmpty else { return [] }
        var result: [SIMD2<Float>] = []
        result.reserveCapacity(polygon.count + 1)
        for k in polygon.indices {
            let a = polygon[k], b = polygon[(k + 1) % polygon.count]
            let da = simd_dot(a - m, normal), db = simd_dot(b - m, normal)
            let aInside = da <= 0, bInside = db <= 0
            if aInside { result.append(a) }
            if aInside != bInside {
                let t = da / (da - db)
                result.append(a + (b - a) * t)
            }
        }
        return result
    }

    /// Fusionne les sommets proches (union-find, donc transitif) et rend chaque cellule en indices de sommets.
    static func weldVertices(_ cells: [[SIMD2<Float>]], tolerance: Float) -> (vertices: [SIMD2<Float>], cells: [[Int]]) {
        var points: [SIMD2<Float>] = []
        var owner: [[Int]] = []
        for cell in cells {
            owner.append(cell.indices.map { points.count + $0 })
            points.append(contentsOf: cell)
        }
        var parent = Array(points.indices)
        func find(_ x: Int) -> Int {
            var x = x
            while parent[x] != x { parent[x] = parent[parent[x]]; x = parent[x] }
            return x
        }
        let tolerance2 = tolerance * tolerance
        for i in points.indices {
            for j in (i + 1)..<points.count where simd_distance_squared(points[i], points[j]) < tolerance2 {
                let ri = find(i), rj = find(j)
                if ri != rj { parent[max(ri, rj)] = min(ri, rj) }
            }
        }
        var index: [Int: Int] = [:]
        var vertices: [SIMD2<Float>] = []
        for i in points.indices {
            let root = find(i)
            if index[root] == nil {
                index[root] = vertices.count
                vertices.append(points[root])
            }
        }
        let welded: [[Int]] = owner.map { ids in
            var cell: [Int] = []
            for id in ids {
                let v = index[find(id)]!
                if cell.last != v { cell.append(v) }
            }
            if cell.count > 1, cell.first == cell.last { cell.removeLast() }
            return cell
        }
        return (vertices, welded)
    }

    static func onSameBorder(_ a: SIMD2<Float>, _ b: SIMD2<Float>, height: Float) -> Bool {
        let e: Float = 1e-4
        return (abs(a.x) < e && abs(b.x) < e) || (abs(a.x - 1) < e && abs(b.x - 1) < e)
            || (abs(a.y) < e && abs(b.y) < e) || (abs(a.y - height) < e && abs(b.y - height) < e)
    }

    static func nearestSite(to p: SIMD2<Float>, in sites: [SIMD2<Float>], excluding excluded: Int) -> Int {
        var best = Float.greatestFiniteMagnitude
        var bestIndex = 0
        for (j, s) in sites.enumerated() where j != excluded {
            let d = simd_distance_squared(p, s)
            if d < best { best = d; bestIndex = j }
        }
        return bestIndex
    }

    // MARK: - Déchirure

    struct EdgeKey: Hashable {
        let low: Int, high: Int
        init(_ a: Int, _ b: Int) { low = min(a, b); high = max(a, b) }
    }

    /// Ligne déchirée de `a` à `b` : ondulation lente + marche aléatoire + dents fines, nulle aux extrémités
    /// pour que les lignes se raccordent exactement aux sommets.
    static func tornLine(from a: SIMD2<Float>, to b: SIMD2<Float>, seed: UInt32, key: EdgeKey) -> [SIMD2<Float>] {
        let delta = b - a
        let length = simd_length(delta)
        guard length > 0.012 else { return [a, b] }
        var rng = SeededRandom(seed: seed &* 0x2C1B_3C6D &+ UInt32(truncatingIfNeeded: key.low &* 7919 &+ key.high &* 104_729))
        let tangent = delta / length
        let normal = SIMD2(-tangent.y, tangent.x)
        let segments = max(3, Int((length / 0.0125).rounded()))

        let waveAmplitude = min(0.0085, length * 0.075) * Float.random(in: 0.5...1, using: &rng)
        let waveFrequency = Float.random(in: 0.6...1.6, using: &rng)
        let wavePhase = Float.random(in: 0...(2 * .pi), using: &rng)
        let rippleAmplitude = min(0.0035, length * 0.04)
        let rippleFrequency = Float.random(in: 2.5...4.5, using: &rng)
        let ripplePhase = Float.random(in: 0...(2 * .pi), using: &rng)

        var points: [SIMD2<Float>] = [a]
        points.reserveCapacity(segments + 1)
        var walk: Float = 0
        for k in 1..<segments {
            let t = (Float(k) + Float.random(in: -0.32...0.32, using: &rng)) / Float(segments)
            let envelope = sin(.pi * t)
            let nearEnds = min(1, min(t, 1 - t) * 7)
            walk = walk * 0.72 + Float.random(in: -0.0022...0.0022, using: &rng)
            let tooth = Float.random(in: -0.0026...0.0026, using: &rng)
            let offset = envelope * (waveAmplitude * sin(2 * .pi * waveFrequency * t + wavePhase)
                                     + rippleAmplitude * sin(2 * .pi * rippleFrequency * t + ripplePhase))
                + nearEnds * (walk + tooth)
            points.append(a + delta * t + normal * offset)
        }
        points.append(b)
        return points
    }

    /// Normales vers l'intérieur : moitié normale locale (suit les dents), moitié normale de l'arête (stabilise).
    static func inwardNormals(_ line: [SIMD2<Float>], toward site: SIMD2<Float>) -> [SIMD2<Float>] {
        guard let first = line.first, let last = line.last, line.count > 1 else { return [] }
        let chord = simd_normalize(last - first)
        var chordNormal = SIMD2(-chord.y, chord.x)
        if simd_dot(chordNormal, site - (first + last) * 0.5) < 0 { chordNormal = -chordNormal }
        return line.indices.map { k in
            let previous = line[max(0, k - 1)], next = line[min(line.count - 1, k + 1)]
            let t = next - previous
            guard simd_length_squared(t) > 1e-12 else { return chordNormal }
            var n = SIMD2(-t.y, t.x) / simd_length(t)
            if simd_dot(n, chordNormal) < 0 { n = -n }
            return simd_normalize(n + chordNormal)
        }
    }

    /// Aire (positive) et centroïde d'un polygone, formule du lacet.
    static func areaAndCentroid(_ polygon: [SIMD2<Float>]) -> (Float, SIMD2<Float>) {
        guard polygon.count >= 3 else { return (0, polygon.first ?? .zero) }
        var twiceArea: Float = 0
        var c = SIMD2<Float>.zero
        for k in polygon.indices {
            let p = polygon[k], q = polygon[(k + 1) % polygon.count]
            let cross = p.x * q.y - q.x * p.y
            twiceArea += cross
            c += (p + q) * cross
        }
        guard abs(twiceArea) > 1e-12 else { return (0, polygon[0]) }
        return (abs(twiceArea) * 0.5, c / (3 * twiceArea))
    }
}
