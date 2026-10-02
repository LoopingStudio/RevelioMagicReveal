import CoreGraphics
import Foundation
import SwiftUI

/// Peau du ticket doré, éclairée ensuite par `rnGold`. Chaque canal porte une donnée :
/// - R : hauteur du relief (0,35 = fond, en dessous = motifs gaufrés en creux, 1 = lettrage et
///   filets), biseaux adoucis par un flou ;
/// - G : poli miroir (1 = pas de brossage, reflet serré) ;
/// - B : laque rouge (baies du houx).
///
/// Elle est rendue une seule fois en image et mise en cache par taille : le flou des biseaux
/// coûterait trop cher à refaire à chaque image.
struct GoldSkin: View {
    @Environment(\.displayScale) private var displayScale
    @State private var image: CGImage?

    var body: some View {
        Color.black
            .overlay {
                if let image {
                    Image(decorative: image, scale: displayScale)
                        .resizable()
                }
            }
            .onGeometryChange(for: CGSize.self) { $0.size } action: { size in
                image = GoldSkinCache.image(size: size, scale: displayScale)
            }
    }
}

/// Cache des peaux rendues : changer de masque ou recommencer ne refait pas le rendu.
enum GoldSkinCache {
    private static var images: [String: CGImage] = [:]

    static func image(size: CGSize, scale: CGFloat) -> CGImage? {
        guard size.width > 40, size.height > 40 else { return nil }
        let key = "\(Int(size.width.rounded()))x\(Int(size.height.rounded()))@\(scale)"
        if let cached = images[key] { return cached }
        let renderer = ImageRenderer(content: GoldSkinArtwork(size: size))
        renderer.scale = scale
        renderer.isOpaque = true
        guard let image = renderer.cgImage else { return nil }
        if images.count > 6 { images.removeAll() }
        images[key] = image
        return image
    }
}

// MARK: - Mise en page

/// Géométrie du ticket pour une taille de carte : cadres, cartouche central, motifs de fond.
struct GoldTicketLayout: Equatable {
    enum MotifKind: Equatable, CaseIterable { case star, snowflake, holly }

    struct Motif: Equatable {
        var kind: MotifKind
        var center: CGPoint
        var radius: CGFloat
        var rotation: CGFloat
    }

    let size: CGSize
    /// Filet extérieur (poli, en relief).
    let outerFrame: CGRect
    /// Filet intérieur, plus fin.
    let innerFrame: CGRect
    /// Plaque centrale qui porte le lettrage.
    let cartouche: CGRect
    let motifs: [Motif]

    /// Brin de houx à cheval sur le filet haut du cartouche.
    var emblemCenter: CGPoint { CGPoint(x: cartouche.midX, y: cartouche.minY) }
    var emblemRadius: CGFloat { max(12, cartouche.height * 0.13) }

    static let outerInset: CGFloat = 9
    static let innerInset: CGFloat = 13.5

    init(size: CGSize) {
        self.size = size
        let bounds = CGRect(origin: .zero, size: size)
        outerFrame = bounds.insetBy(dx: Self.outerInset, dy: Self.outerInset)
        innerFrame = bounds.insetBy(dx: Self.innerInset, dy: Self.innerInset)

        let cartoucheWidth = innerFrame.width * 0.86
        let cartoucheHeight = min(size.height * 0.30, cartoucheWidth * 0.56)
        cartouche = CGRect(x: bounds.midX - cartoucheWidth / 2, y: bounds.midY - cartoucheHeight / 2,
                           width: cartoucheWidth, height: cartoucheHeight)

        // Treillis en quinconce de petits motifs, hors du cartouche et à distance des filets.
        let spacing = max(24, innerFrame.width / 5.4)
        let rowStep = spacing * 0.86
        let radius = spacing * 0.2
        let keepOut = cartouche.insetBy(dx: -radius - 7, dy: -radius - 7)
        let field = innerFrame.insetBy(dx: radius + 5, dy: radius + 5)
        var motifs: [Motif] = []
        let rows = Int((innerFrame.height / rowStep).rounded(.up)) + 1
        let cols = Int((innerFrame.width / spacing).rounded(.up)) + 1
        // Treillis centré sur la carte pour rester symétrique.
        let originX = bounds.midX - CGFloat(cols / 2) * spacing
        let originY = bounds.midY - CGFloat(rows / 2) * rowStep
        for row in 0..<rows {
            for col in 0..<cols {
                let x = originX + CGFloat(col) * spacing + (row.isMultiple(of: 2) ? 0 : spacing / 2)
                let y = originY + CGFloat(row) * rowStep
                let center = CGPoint(x: x, y: y)
                guard field.contains(center), !keepOut.contains(center) else { continue }
                let kind = MotifKind.allCases[((col + 2 * row) % 3 + 3) % 3]
                let wobble = GoldTicketLayout.hash(Double(row * 31 + col * 17)) - 0.5
                motifs.append(Motif(kind: kind, center: center, radius: radius, rotation: CGFloat(wobble) * 0.5))
            }
        }
        self.motifs = motifs
    }

    /// Hachage déterministe 0…1, pour les petites variations du dessin.
    static func hash(_ x: Double) -> Double {
        let s = sin(x * 12.9898 + 78.233) * 43758.5453
        return s - s.rounded(.down)
    }
}

// MARK: - Dessin

/// La peau elle-même : un Canvas sur un fond à mi-hauteur. Les motifs de fond y sont gaufrés en
/// creux (mode normal), le reste s'additionne canal par canal (`plusLighter`).
struct GoldSkinArtwork: View {
    let size: CGSize

    /// Hauteur du fond de la feuille : laisse de la place pour graver en creux.
    static let baseHeight = 0.35

    var body: some View {
        Canvas { context, size in
            let layout = GoldTicketLayout(size: size)
            context.fill(Path(CGRect(origin: .zero, size: size)), with: Self.relief(Self.baseHeight))
            Self.drawMotifs(layout, in: &context)
            context.blendMode = .plusLighter
            Self.drawFrames(layout, in: &context)
            Self.drawCartouche(layout, in: &context)
            Self.drawLettering(layout, in: &context)
            Self.drawEmblem(layout, in: &context)
        }
        .frame(width: size.width, height: size.height)
    }

    /// Hauteur seule (R), hauteur + poli (R + G), laque (B).
    private static func relief(_ height: Double, polish: Double = 0, lacquer: Double = 0) -> GraphicsContext.Shading {
        .color(Color(red: height, green: polish, blue: lacquer))
    }

    /// Motifs de fond gaufrés en creux : on « enfonce » la hauteur sous celle du fond.
    private static func drawMotifs(_ layout: GoldTicketLayout, in context: inout GraphicsContext) {
        let pressed = relief(baseHeight - 0.24)
        context.drawLayer { layer in
            layer.addFilter(.blur(radius: 0.5))
            for motif in layout.motifs {
                var c = layer
                c.translateBy(x: motif.center.x, y: motif.center.y)
                c.rotate(by: .radians(Double(motif.rotation)))
                switch motif.kind {
                case .star:
                    c.fill(GoldShapes.star(radius: motif.radius), with: pressed)
                case .snowflake:
                    c.stroke(GoldShapes.snowflake(radius: motif.radius * 1.12),
                             with: pressed,
                             style: StrokeStyle(lineWidth: max(0.9, motif.radius * 0.085), lineCap: .round))
                case .holly:
                    GoldShapes.drawHolly(radius: motif.radius * 1.05, leaf: pressed,
                                         vein: relief(baseHeight - 0.1), berry: relief(baseHeight - 0.3), in: &c)
                }
            }
        }
    }

    private static func drawFrames(_ layout: GoldTicketLayout, in context: inout GraphicsContext) {
        context.drawLayer { layer in
            layer.addFilter(.blur(radius: 0.6))
            layer.stroke(Path(roundedRect: layout.outerFrame, cornerRadius: 4),
                         with: relief(1, polish: 1), lineWidth: 1.7)
            layer.stroke(Path(roundedRect: layout.innerFrame, cornerRadius: 2),
                         with: relief(0.7, polish: 0.8), lineWidth: 0.7)
            // Étincelles aux quatre coins, à cheval sur les filets.
            let corners = [
                CGPoint(x: layout.outerFrame.minX + 2, y: layout.outerFrame.minY + 2),
                CGPoint(x: layout.outerFrame.maxX - 2, y: layout.outerFrame.minY + 2),
                CGPoint(x: layout.outerFrame.minX + 2, y: layout.outerFrame.maxY - 2),
                CGPoint(x: layout.outerFrame.maxX - 2, y: layout.outerFrame.maxY - 2),
            ]
            for corner in corners {
                var c = layer
                c.blendMode = .normal
                c.fill(Path(ellipseIn: CGRect(x: corner.x - 6, y: corner.y - 6, width: 12, height: 12)), with: .color(.black))
                c.translateBy(x: corner.x, y: corner.y)
                c.fill(GoldShapes.sparkle(radius: 6), with: relief(1, polish: 1))
            }
        }
    }

    private static func drawCartouche(_ layout: GoldTicketLayout, in context: inout GraphicsContext) {
        let plate = layout.cartouche
        let notch: CGFloat = min(14, plate.height * 0.16)
        // Plaque légèrement en relief et satinée : large biseau doux.
        context.drawLayer { layer in
            layer.addFilter(.blur(radius: 1.6))
            layer.fill(GoldShapes.notchedRect(plate, notch: notch), with: relief(0.3, polish: 0.22))
        }
        // Double filet poli.
        context.drawLayer { layer in
            layer.addFilter(.blur(radius: 0.55))
            layer.stroke(GoldShapes.notchedRect(plate, notch: notch), with: relief(0.68, polish: 0.68), lineWidth: 1.7)
            let inner = plate.insetBy(dx: 4.5, dy: 4.5)
            layer.stroke(GoldShapes.notchedRect(inner, notch: max(2, notch - 4.5)), with: relief(0.5, polish: 0.5), lineWidth: 0.6)
            // Les filets s'interrompent sous l'emblème.
            let c = layout.emblemCenter, r = layout.emblemRadius
            var gap = layer
            gap.blendMode = .normal
            gap.fill(Path(ellipseIn: CGRect(x: c.x - r * 1.6, y: c.y - r * 0.8, width: r * 3.2, height: r * 1.6)),
                     with: .color(.black))
        }
    }

    private static func drawLettering(_ layout: GoldTicketLayout, in context: inout GraphicsContext) {
        let plate = layout.cartouche
        context.drawLayer { layer in
            layer.addFilter(.blur(radius: 0.7))

            // « Gratte-moi » en anglaise, ajusté à la largeur de la plaque.
            let script = layer.resolve(
                Text("Gratte-moi")
                    .font(.custom("SnellRoundhand-Black", size: 60))
                    .foregroundStyle(Color(red: 0.68, green: 0.68, blue: 0))
            )
            let measured = script.measure(in: CGSize(width: 2000, height: 400))
            let fit = min(plate.width * 0.84 / max(measured.width, 1), plate.height * 0.46 / max(measured.height, 1))
            var c = layer
            c.translateBy(x: plate.midX, y: plate.midY + plate.height * 0.04)
            c.scaleBy(x: fit, y: fit)
            c.draw(script, at: .zero, anchor: .center)

            // « JOYEUX NOËL » en capitales espacées, au-dessus.
            let titleSize = max(9, plate.height * 0.085)
            let title = layer.resolve(
                Text("JOYEUX NOËL")
                    .font(.custom("Didot-Bold", size: titleSize))
                    .tracking(titleSize * 0.42)
                    .foregroundStyle(Color(red: 0.68, green: 0.68, blue: 0))
            )
            layer.draw(title, at: CGPoint(x: plate.midX + titleSize * 0.21, y: plate.minY + plate.height * 0.2), anchor: .center)

        }
        // Sous-titre en italique, entre deux filets et deux étincelles : biseau plus fin, il est petit.
        context.drawLayer { layer in
            layer.addFilter(.blur(radius: 0.4))
            let subtitleSize = max(10, plate.height * 0.094)
            let subtitle = layer.resolve(
                Text("une surprise t’attend")
                    .font(.custom("Didot-Italic", size: subtitleSize))
                    .foregroundStyle(Color(red: 0.55, green: 0.6, blue: 0))
            )
            let subtitleY = plate.maxY - plate.height * 0.19
            let subtitleWidth = subtitle.measure(in: CGSize(width: 1000, height: 100)).width
            layer.draw(subtitle, at: CGPoint(x: plate.midX, y: subtitleY), anchor: .center)
            let gap = subtitleWidth / 2 + 10
            for side: CGFloat in [-1, 1] {
                var s = layer
                s.translateBy(x: plate.midX + side * gap, y: subtitleY)
                s.fill(GoldShapes.sparkle(radius: 3.6), with: relief(0.7, polish: 0.7))
                var line = Path()
                line.move(to: CGPoint(x: side * 7, y: 0))
                line.addLine(to: CGPoint(x: side * 26, y: 0))
                s.stroke(line, with: relief(0.5, polish: 0.5), lineWidth: 0.6)
            }
        }
    }

    /// Brin de houx à cheval sur le filet haut du cartouche, baies laquées rouges.
    private static func drawEmblem(_ layout: GoldTicketLayout, in context: inout GraphicsContext) {
        let center = layout.emblemCenter
        let radius = layout.emblemRadius
        context.drawLayer { layer in
            layer.addFilter(.blur(radius: 0.65))
            var c = layer
            c.translateBy(x: center.x, y: center.y)
            GoldShapes.drawHolly(radius: radius, leaf: relief(0.6, polish: 0.75), vein: relief(0.25, polish: 0.4),
                                 berry: relief(0.65, polish: 0.9, lacquer: 1), in: &c)
        }
    }
}

// MARK: - Formes

enum GoldShapes {
    static func star(radius r: CGFloat, points: Int = 5, innerRatio: CGFloat = 0.42) -> Path {
        var path = Path()
        for i in 0..<(points * 2) {
            let angle = CGFloat(i) * .pi / CGFloat(points) - .pi / 2
            let radius = i.isMultiple(of: 2) ? r : r * innerRatio
            let point = CGPoint(x: cos(angle) * radius, y: sin(angle) * radius)
            if i == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        path.closeSubpath()
        return path
    }

    /// Étincelle à quatre branches effilées.
    static func sparkle(radius r: CGFloat) -> Path {
        var path = Path()
        let k = r * 0.16
        path.move(to: CGPoint(x: 0, y: -r))
        path.addQuadCurve(to: CGPoint(x: r, y: 0), control: CGPoint(x: k, y: -k))
        path.addQuadCurve(to: CGPoint(x: 0, y: r), control: CGPoint(x: k, y: k))
        path.addQuadCurve(to: CGPoint(x: -r, y: 0), control: CGPoint(x: -k, y: k))
        path.addQuadCurve(to: CGPoint(x: 0, y: -r), control: CGPoint(x: -k, y: -k))
        path.closeSubpath()
        return path
    }

    /// Flocon à six branches, chacune avec une ramure en V (à tracer en trait).
    static func snowflake(radius r: CGFloat) -> Path {
        var path = Path()
        for i in 0..<6 {
            let a = CGFloat(i) * .pi / 3 - .pi / 2
            let dir = CGPoint(x: cos(a), y: sin(a))
            path.move(to: .zero)
            path.addLine(to: CGPoint(x: dir.x * r, y: dir.y * r))
            for (along, length) in [(0.58, 0.34)] as [(CGFloat, CGFloat)] {
                let base = CGPoint(x: dir.x * r * along, y: dir.y * r * along)
                for side: CGFloat in [-1, 1] {
                    let b = a + side * .pi / 4
                    path.move(to: base)
                    path.addLine(to: CGPoint(x: base.x + cos(b) * r * length, y: base.y + sin(b) * r * length))
                }
            }
        }
        return path
    }

    /// Feuille de houx le long de +x (base en 0, pointe en `length`), trois piquants par côté.
    static func hollyLeaf(length: CGFloat, width: CGFloat) -> Path {
        let spikes = 3
        let steps = spikes + 1
        func edge(_ i: Int, side: CGFloat) -> CGPoint {
            let x = length * CGFloat(i) / CGFloat(steps)
            let y = (i == 0 || i == steps) ? 0 : side * width * sin(.pi * x / length) * 1.05
            return CGPoint(x: x, y: y)
        }
        var path = Path()
        path.move(to: .zero)
        var previous = CGPoint.zero
        for i in 1...steps {
            let point = edge(i, side: -1)
            let control = CGPoint(x: (previous.x + point.x) / 2, y: (previous.y + point.y) / 2 * 0.45)
            path.addQuadCurve(to: point, control: control)
            previous = point
        }
        for i in stride(from: steps - 1, through: 0, by: -1) {
            let point = edge(i, side: 1)
            let control = CGPoint(x: (previous.x + point.x) / 2, y: (previous.y + point.y) / 2 * 0.45)
            path.addQuadCurve(to: point, control: control)
            previous = point
        }
        path.closeSubpath()
        return path
    }

    /// Deux feuilles en V au-dessus de trois baies. Tout est peint en mode normal dans le calque :
    /// la nervure remplace la feuille sous elle, les baies passent par-dessus.
    static func drawHolly(radius r: CGFloat, leaf: GraphicsContext.Shading, vein: GraphicsContext.Shading,
                          berry: GraphicsContext.Shading, in context: inout GraphicsContext) {
        let shape = hollyLeaf(length: r * 1.35, width: r * 0.4)
        var base = context
        base.blendMode = .normal
        for angle in [-0.95, Double.pi + 0.95] {
            var c = base
            c.translateBy(x: 0, y: r * 0.1)
            c.rotate(by: .radians(angle))
            c.translateBy(x: r * 0.16, y: 0)
            c.fill(shape, with: leaf)
            var line = Path()
            line.move(to: CGPoint(x: r * 0.1, y: 0))
            line.addLine(to: CGPoint(x: r * 1.15, y: 0))
            c.stroke(line, with: vein, lineWidth: max(0.55, r * 0.05))
        }
        let berryRadius = r * 0.19
        for (dx, dy) in [(-0.2, 0.3), (0.2, 0.3), (0.0, 0.08)] as [(CGFloat, CGFloat)] {
            let rect = CGRect(x: dx * r - berryRadius, y: dy * r - berryRadius, width: berryRadius * 2, height: berryRadius * 2)
            base.fill(Path(ellipseIn: rect), with: berry)
        }
    }

    /// Rectangle aux coins creusés en quart de cercle, façon étiquette.
    static func notchedRect(_ rect: CGRect, notch n: CGFloat) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX + n, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - n, y: rect.minY))
        path.addArc(center: CGPoint(x: rect.maxX, y: rect.minY), radius: n,
                    startAngle: .degrees(180), endAngle: .degrees(90), clockwise: true)
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - n))
        path.addArc(center: CGPoint(x: rect.maxX, y: rect.maxY), radius: n,
                    startAngle: .degrees(270), endAngle: .degrees(180), clockwise: true)
        path.addLine(to: CGPoint(x: rect.minX + n, y: rect.maxY))
        path.addArc(center: CGPoint(x: rect.minX, y: rect.maxY), radius: n,
                    startAngle: .degrees(0), endAngle: .degrees(270), clockwise: true)
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + n))
        path.addArc(center: CGPoint(x: rect.minX, y: rect.minY), radius: n,
                    startAngle: .degrees(90), endAngle: .degrees(0), clockwise: true)
        path.closeSubpath()
        return path
    }
}
