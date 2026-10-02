import CoreGraphics
import SwiftUI
import UIKit
import simd

/// Papier cadeau : les morceaux encore attachés, dessinés dans la carte (rognés).
struct PaperMaskView: View {
    let engine: RevealEngine
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        let _ = engine.frame
        let sheet = engine.paper
        // Le Canvas ne se redessine que si un morceau tombe ou se soulève : la vue est équatable.
        AttachedPaperCanvas(sheet: sheet, looseLevels: PaperRender.visibleLooseLevels(sheet), scale: displayScale)
            .equatable()
            .allowsHitTesting(false)
            .onAppear {
                // Le verso n'est utile qu'à la première chute : on le prépare avant, pour ne pas perdre d'image.
                _ = PaperArtwork.verso(size: engine.cardSize, scale: displayScale)
            }
    }
}

/// Morceaux en train de tomber, dessinés hors de la carte (couche non rognée).
struct PaperFallingLayer: View {
    let engine: RevealEngine
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        let _ = engine.frame
        let sheet = engine.paper
        let cardSize = engine.cardSize
        let scale = displayScale
        // Le Canvas reste toujours dans l'arbre : l'insérer ou le retirer en même temps qu'un changement
        // de phase lui ferait prendre la transition animée de la carte (fondu parasite).
        Canvas(rendersAsynchronously: false) { context, _ in
            guard !sheet.falling.isEmpty, cardSize.width > 1 else { return }
            let margin = RevealEngine.particleMargin
            context.translateBy(x: margin, y: margin)
            PaperRender.drawFalling(sheet, cardSize: cardSize, scale: scale, in: &context)
        }
        .allowsHitTesting(false)
    }
}

// MARK: - Feuille attachée

private struct AttachedPaperCanvas: View, Equatable {
    let sheet: PaperSheet
    let looseLevels: [UInt8]
    let scale: CGFloat

    nonisolated static func == (a: Self, b: Self) -> Bool {
        a.sheet.seed == b.sheet.seed && a.scale == b.scale
            && a.sheet.attached == b.sheet.attached && a.looseLevels == b.looseLevels
    }

    var body: some View {
        Canvas(rendersAsynchronously: false) { context, size in
            PaperRender.drawAttached(sheet, looseLevels: looseLevels, size: size, scale: scale, in: &context)
        }
    }
}

// MARK: - Rendu

@MainActor
enum PaperRender {
    static let cornerRadius: CGFloat = 5
    static let looseSteps: Float = 24
    static let fringeColor = Color(red: 0.99, green: 0.975, blue: 0.945)
    static let inkEdgeColor = Color(red: 0.42, green: 0.02, blue: 0.06)
    static let casterColor = Color(uiColor: PaperArtwork.red)

    static func looseLevel(_ looseness: Float) -> UInt8 {
        UInt8(min(looseSteps, (looseness * looseSteps).rounded(.down)))
    }

    /// Niveaux de soulèvement réellement dessinés (bord libre et niveau ≥ 6), 0 sinon : la feuille
    /// attachée, équatable, ne se redessine pas pour des variations invisibles.
    static func visibleLooseLevels(_ sheet: PaperSheet) -> [UInt8] {
        sheet.pieces.indices.map { i in
            guard sheet.attached[i] else { return 0 }
            let level = looseLevel(sheet.looseness[i])
            guard level >= 6, sheet.pieces[i].edges.contains(where: { !sheet.attached[$0.neighbor] }) else { return 0 }
            return level
        }
    }

    /// Feuille encore en place, en une seule passe : la feuille reste continue, sans couture entre voisins.
    /// Un morceau prêt à se détacher se trahit seulement par l'ombre qui s'élargit sous ses bords déjà libres.
    static func drawAttached(_ sheet: PaperSheet, looseLevels: [UInt8], size: CGSize, scale: CGFloat,
                             in context: inout GraphicsContext) {
        guard size.width > 1, sheet.attachedCount > 0 else { return }
        let paths = PaperPathCache.paths(for: sheet, size: size)
        let rect = CGRect(origin: .zero, size: size)
        let recto = context.resolve(Image(uiImage: PaperArtwork.recto(size: size, variant: PaperArtwork.variant(for: sheet.seed), scale: scale)))

        var sheetPath = Path()
        var tears = TearStrokes()
        var lifting: [Int] = []
        for i in sheet.pieces.indices where sheet.attached[i] {
            sheetPath.addPath(paths.outlines[i])
            let free = sheet.pieces[i].edges.contains { !sheet.attached[$0.neighbor] }
            guard free else { continue }
            tears.add(piece: i, sheet: sheet, paths: paths, onlyFacingDetached: true)
            if looseLevels[i] >= 6 { lifting.append(i) }
        }

        // Ombre du papier sur la photo, le long des déchirures.
        var shadow = context
        shadow.addFilter(.shadow(color: .black.opacity(0.55), radius: 2.6, x: 0.3, y: 1.4))
        shadow.fill(sheetPath, with: .color(casterColor))

        // Les bords libres d'un morceau qui va lâcher se soulèvent : son ombre s'allonge sur la photo.
        for i in lifting {
            let lift = CGFloat(looseLevels[i]) / CGFloat(looseSteps)
            var cast = context
            cast.addFilter(.shadow(color: .black.opacity(0.2 + 0.32 * lift), radius: 2 + 5 * lift, x: 0.8 * lift, y: 1.2 + 4.5 * lift))
            cast.fill(paths.outlines[i], with: .color(casterColor))
        }

        var paper = context
        paper.clip(to: sheetPath)
        paper.draw(recto, in: rect)
        tears.draw(in: &context)
    }

    /// Morceaux qui tombent, dans le repère de la carte (origine en haut à gauche de la photo).
    static func drawFalling(_ sheet: PaperSheet, cardSize: CGSize, scale: CGFloat, in context: inout GraphicsContext) {
        let paths = PaperPathCache.paths(for: sheet, size: cardSize)
        let rect = CGRect(origin: .zero, size: cardSize)
        let recto = context.resolve(Image(uiImage: PaperArtwork.recto(size: cardSize, variant: PaperArtwork.variant(for: sheet.seed), scale: scale)))
        let verso = context.resolve(Image(uiImage: PaperArtwork.verso(size: cardSize, scale: scale)))
        // Lumière venant du haut à gauche, un peu de face.
        let light = simd_normalize(SIMD3<Float>(-0.35, -0.55, 0.76))
        func transform(of body: FallingPaper) -> CGAffineTransform {
            let c = paths.centroids[body.piece]
            let lift = CGFloat(body.lift)
            let cosFlip = cos(body.flip)
            let squash = CGFloat(cosFlip < 0 ? min(-0.03, cosFlip) : max(0.03, cosFlip))
            let grow = 1 + 0.05 * lift
            var transform = CGAffineTransform(translationX: CGFloat(body.position.x), y: CGFloat(body.position.y))
            transform = transform.rotated(by: CGFloat(body.flipAxis))
            transform = transform.scaledBy(x: 1, y: squash)
            transform = transform.rotated(by: CGFloat(body.rotation - body.flipAxis))
            transform = transform.scaledBy(x: grow, y: grow)
            return transform.translatedBy(x: -c.x, y: -c.y)
        }

        // Ombres douces, d'autant plus décalées que le morceau s'est élevé : une seule passe floutée
        // pour tous les morceaux (à l'auto-fin, jusqu'à ~50 tombent ensemble).
        context.drawLayer { layer in
            layer.addFilter(.blur(radius: sheet.falling.count > 14 ? 2.5 : 4))
            for body in sheet.falling {
                let lift = CGFloat(body.lift)
                var shadow = layer
                shadow.translateBy(x: 2 + 5 * lift, y: 4 + 11 * lift)
                shadow.concatenate(transform(of: body))
                shadow.fill(paths.fallingShapes[body.piece], with: .color(.black.opacity(Double(0.34 - 0.1 * lift))))
            }
        }

        for body in sheet.falling {
            let i = body.piece
            let cosFlip = cos(body.flip)
            let shape = paths.fallingShapes[i]

            var piece = context
            piece.concatenate(transform(of: body))
            var surface = piece
            surface.clip(to: shape)
            surface.draw(cosFlip >= 0 ? recto : verso, in: rect)

            if cosFlip >= 0 {
                TearStrokes(paths.fallingTears[i]).draw(in: &piece)
            } else {
                piece.stroke(shape, with: .color(.black.opacity(0.12)), lineWidth: 0.6)
            }

            // Éclairage, par-dessus la déchirure : la face visible penche vers la lumière ou s'en détourne.
            let axis = SIMD2<Float>(cos(body.flipAxis), sin(body.flipAxis))
            let s = sin(body.flip)
            var normal = SIMD3<Float>(s * axis.y, -s * axis.x, cosFlip)
            if cosFlip < 0 { normal = -normal }
            let shade = simd_dot(normal, light) / light.z
            if shade < 1 {
                surface.fill(shape, with: .color(.black.opacity(Double(min(0.36, (1 - shade) * 0.42)))))
            } else {
                surface.fill(shape, with: .color(.white.opacity(Double(min(0.14, (shade - 1) * 0.5)))))
            }
        }
    }
}

/// Bords déchirés : bande blanche du cœur du papier, liseré d'encre, fibres qui dépassent.
private struct TearStrokes {
    var bands = Path()
    var inkLines = Path()
    var fibers = Path()

    init() {}

    init(_ combined: PaperTearPaths) {
        bands = combined.band
        inkLines = combined.inkLine
        fibers = combined.fibers
    }

    mutating func add(piece i: Int, sheet: PaperSheet, paths: PaperPaths, onlyFacingDetached: Bool) {
        for (k, edge) in sheet.pieces[i].edges.enumerated() where !onlyFacingDetached || !sheet.attached[edge.neighbor] {
            let tear = paths.tears[i][k]
            bands.addPath(tear.band)
            inkLines.addPath(tear.inkLine)
            fibers.addPath(tear.fibers)
        }
    }

    func draw(in context: inout GraphicsContext) {
        guard !bands.isEmpty else { return }
        context.fill(bands, with: .color(PaperRender.fringeColor))
        context.stroke(inkLines, with: .color(PaperRender.inkEdgeColor.opacity(0.45)), lineWidth: 0.55)
        context.stroke(fibers, with: .color(.white.opacity(0.85)), style: StrokeStyle(lineWidth: 0.5, lineCap: .round))
    }
}

// MARK: - Chemins en points

struct PaperTearPaths {
    var band: Path
    var inkLine: Path
    var fibers: Path
}

struct PaperPaths {
    var outlines: [Path]
    var centroids: [CGPoint]
    /// Par morceau, par arête partagée (même ordre que `PaperPiece.edges`).
    var tears: [[PaperTearPaths]]
    /// Contours des morceaux qui tombent : ceux des coins sont rognés par l'arrondi de la carte.
    var fallingShapes: [Path]
    /// Toutes les déchirures d'un morceau réunies : constantes pendant sa chute.
    var fallingTears: [PaperTearPaths]
}

/// Chemins des morceaux en points, calculés une fois par feuille et par taille de carte.
@MainActor
enum PaperPathCache {
    private struct Key: Hashable {
        var seed: UInt32, width: Int, height: Int
    }

    private static var cache: [Key: PaperPaths] = [:]

    static func paths(for sheet: PaperSheet, size: CGSize) -> PaperPaths {
        let key = Key(seed: sheet.seed, width: Int((size.width * 4).rounded()), height: Int((size.height * 4).rounded()))
        if let paths = cache[key] { return paths }
        if cache.count >= 3 { cache.removeAll() }
        let paths = build(sheet, size: size)
        cache[key] = paths
        return paths
    }

    private static func build(_ sheet: PaperSheet, size: CGSize) -> PaperPaths {
        func pt(_ p: SIMD2<Float>) -> CGPoint {
            let q = sheet.point(p, cardSize: size)
            return CGPoint(x: CGFloat(q.x), y: CGFloat(q.y))
        }
        var outlines: [Path] = []
        var centroids: [CGPoint] = []
        var tears: [[PaperTearPaths]] = []
        var fallingShapes: [Path] = []
        var fallingTears: [PaperTearPaths] = []
        let cornerZone = PaperRender.cornerRadius + 1
        let roundedCard = Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: PaperRender.cornerRadius)

        for (i, piece) in sheet.pieces.enumerated() {
            var outline = Path()
            outline.addLines(piece.outline.map(pt))
            outline.closeSubpath()
            outlines.append(outline)
            centroids.append(pt(piece.centroid))
            let box = outline.boundingRect
            let inCorner = (box.minX < cornerZone || box.maxX > size.width - cornerZone)
                && (box.minY < cornerZone || box.maxY > size.height - cornerZone)
            fallingShapes.append(inCorner ? outline.intersection(roundedCard) : outline)

            var rng = SeededRandom(seed: sheet.seed &* 977 &+ UInt32(i) &* 131)
            let pieceTears = piece.edges.map { edge in tearPaths(edge, pt: pt, rng: &rng) }
            tears.append(pieceTears)
            var combined = PaperTearPaths(band: Path(), inkLine: Path(), fibers: Path())
            for tear in pieceTears {
                combined.band.addPath(tear.band)
                combined.inkLine.addPath(tear.inkLine)
                combined.fibers.addPath(tear.fibers)
            }
            fallingTears.append(combined)
        }
        return PaperPaths(outlines: outlines, centroids: centroids, tears: tears, fallingShapes: fallingShapes,
                          fallingTears: fallingTears)
    }

    /// Bande blanche de largeur irrégulière vers l'intérieur du morceau, et fibres vers l'extérieur.
    private static func tearPaths(_ edge: PaperEdge, pt: (SIMD2<Float>) -> CGPoint, rng: inout SeededRandom) -> PaperTearPaths {
        let points = edge.points.map(pt)
        let normals: [CGPoint] = edge.inward.map { n in
            let length = max(1e-6, hypot(CGFloat(n.x), CGFloat(n.y)))
            return CGPoint(x: CGFloat(n.x) / length, y: CGFloat(n.y) / length)
        }
        var widths: [CGFloat] = []
        var current = CGFloat(rng.float(0.9...2.2))
        for k in points.indices {
            current = current * 0.55 + CGFloat(rng.float(0.35...1.25))
            let atEnd = k == 0 || k == points.count - 1
            widths.append(atEnd ? 1.0 : min(3.2, current))
        }
        var inner: [CGPoint] = []
        for k in points.indices {
            inner.append(CGPoint(x: points[k].x + normals[k].x * widths[k], y: points[k].y + normals[k].y * widths[k]))
        }
        var band = Path()
        band.addLines(points + inner.reversed())
        band.closeSubpath()

        var inkLine = Path()
        inkLine.addLines(inner)

        var fibers = Path()
        for k in points.indices.dropFirst().dropLast() where rng.chance(0.7) {
            for _ in 0..<(rng.chance(0.35) ? 2 : 1) {
                let n = normals[k]
                let tangent = CGPoint(x: -n.y, y: n.x)
                let length = CGFloat(rng.float(0.8...2.8))
                let slant = CGFloat(rng.float(-0.9...0.9))
                let along = CGFloat(rng.float(-1.5...1.5))
                let start = CGPoint(x: points[k].x + n.x * 0.6 + tangent.x * along, y: points[k].y + n.y * 0.6 + tangent.y * along)
                fibers.move(to: start)
                fibers.addLine(to: CGPoint(x: start.x - n.x * length + tangent.x * slant * length,
                                           y: start.y - n.y * length + tangent.y * slant * length))
            }
        }
        return PaperTearPaths(band: band, inkLine: inkLine, fibers: fibers)
    }
}

// MARK: - Particules

enum PaperRecipe: ParticleRecipe {
    /// Une érosion seule ne dit pas si du papier est encore là : les lambeaux sont émis par `PaperSheet`,
    /// qui sait quels morceaux tiennent encore (voir `scrap` et `crumb`).
    static func particles(for event: ErosionEvent, rng: inout SeededRandom) -> [Particle] {
        []
    }

    /// Lambeau arraché quand un morceau se détache : confetti de papier qui tournoie.
    static func scrap(at point: SIMD2<Float>, inheriting velocity: SIMD2<Float>, rng: inout SeededRandom) -> Particle {
        let life = rng.float(0.9...1.7)
        return Particle(
            kind: .paperScrap,
            position: point + SIMD2(rng.float(-2...2), rng.float(-2...2)),
            velocity: velocity * rng.float(0.25...0.6) + SIMD2(rng.float(-150...150), rng.float(-220 ... -40)),
            size: rng.float(1.8...4.2),
            rotation: rng.float(0...6.28),
            spin: rng.float(-10...10),
            flip: rng.float(0...6.28),
            flipSpeed: rng.float(5...13),
            life: life, maxLife: life,
            gravityScale: 0.55,
            drag: 2.2,
            wobble: rng.float(0.4...1.4),
            hue: rng.float(0...0.999),
            seed: rng.float(0...1)
        )
    }

    /// Miette sous le doigt pendant qu'on gratte : surtout des fibres blanches, quelques éclats rouges.
    static func crumb(at point: SIMD2<Float>, fingerVelocity: SIMD2<Float>, rng: inout SeededRandom) -> Particle {
        let life = rng.float(0.35...0.7)
        return Particle(
            kind: .paperScrap,
            position: point + SIMD2(rng.float(-6...6), rng.float(-6...6)),
            velocity: fingerVelocity * 0.15 + SIMD2(rng.float(-90...90), rng.float(-160 ... -30)),
            size: rng.float(0.9...1.9),
            rotation: rng.float(0...6.28),
            spin: rng.float(-12...12),
            flip: rng.float(0...6.28),
            flipSpeed: rng.float(6...14),
            life: life, maxLife: life,
            gravityScale: 0.6,
            drag: 2.6,
            hue: rng.chance(0.65) ? rng.float(0.6...0.84) : rng.float(0...0.5),
            seed: rng.float(0...1)
        )
    }
}

enum PaperArt {
    private static let reds: [Color] = [
        Color(red: 0.70, green: 0.07, blue: 0.12),
        Color(red: 0.60, green: 0.05, blue: 0.10),
        Color(red: 0.80, green: 0.12, blue: 0.17),
    ]
    private static let fiber = Color(red: 0.99, green: 0.97, blue: 0.93)
    private static let ribbon = Color(red: 0.93, green: 0.77, blue: 0.42)

    /// `hue` : < 0,6 éclat rouge (verso crème quand il se retourne), < 0,85 fibre blanche, sinon brin de ruban.
    static func draw(_ p: Particle, in context: inout GraphicsContext) {
        let fade = Double(min(1, p.lifeFraction * 3))
        let s = CGFloat(p.size)
        var c = context
        c.translateBy(x: CGFloat(p.position.x), y: CGFloat(p.position.y))
        c.rotate(by: .radians(Double(p.rotation)))
        let squash = CGFloat(cos(p.flip))
        c.scaleBy(x: 1, y: max(0.12, abs(squash)))

        let color: Color
        var shape = Path()
        if p.hue < 0.6 {
            color = squash >= 0 ? reds[Int(p.hue / 0.2) % reds.count] : fiber
            // Quadrilatère irrégulier, différent pour chaque lambeau.
            let k = CGFloat(p.seed)
            shape.move(to: CGPoint(x: -s * (0.8 + 0.4 * k), y: -s * 0.7))
            shape.addLine(to: CGPoint(x: s * (0.9 - 0.3 * k), y: -s * (0.9 - 0.5 * k)))
            shape.addLine(to: CGPoint(x: s * (0.7 + 0.3 * k), y: s * 0.8))
            shape.addLine(to: CGPoint(x: -s * (0.6 + 0.2 * k), y: s * (0.6 + 0.4 * k)))
            shape.closeSubpath()
        } else if p.hue < 0.85 {
            color = fiber
            shape = Path(roundedRect: CGRect(x: -s * 1.2, y: -s * 0.22, width: s * 2.4, height: s * 0.44), cornerRadius: s * 0.2)
        } else {
            color = ribbon
            shape = Path(CGRect(x: -s * 0.9, y: -s * 0.45, width: s * 1.8, height: s * 0.9))
        }
        // Une face tournée vers la lumière, l'autre un peu dans l'ombre.
        let shade = 0.78 + 0.22 * Double(abs(squash))
        c.fill(shape, with: .color(color.opacity(fade * shade)))
    }
}
