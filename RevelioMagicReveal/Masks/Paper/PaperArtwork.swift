import CoreGraphics
import Foundation
import SwiftUI
import UIKit
import simd

/// Le papier cadeau, dessiné une fois en Core Graphics et mis en cache par taille et variante.
///
/// Recto : rouge profond à motifs (sapins, flocons, étoiles), grain, ruban doré satiné en croix et nœud.
/// Verso : papier crème au quadrillage de découpe, comme au dos des vrais rouleaux.
enum PaperArtwork {
    static let variantCount = 3

    static let red = UIColor(red: 0.66, green: 0.06, blue: 0.11, alpha: 1)
    static let cream = UIColor(red: 0.99, green: 0.95, blue: 0.87, alpha: 1)
    static let gold = UIColor(red: 0.94, green: 0.77, blue: 0.41, alpha: 1)
    static let versoBase = UIColor(red: 0.962, green: 0.950, blue: 0.925, alpha: 1)

    static func variant(for seed: UInt32) -> Int { Int(seed % UInt32(variantCount)) }

    private struct Key: Hashable {
        var width: Int, height: Int, scale: Int, variant: Int
        init(_ size: CGSize, _ scale: CGFloat, _ variant: Int) {
            width = Int((size.width * 4).rounded())
            height = Int((size.height * 4).rounded())
            self.scale = Int((scale * 4).rounded())
            self.variant = variant
        }
    }

    private static var rectoCache: [Key: UIImage] = [:]
    private static var versoCache: [Key: UIImage] = [:]

    static func recto(size: CGSize, variant: Int, scale: CGFloat) -> UIImage {
        let key = Key(size, scale, variant)
        if let image = rectoCache[key] { return image }
        if rectoCache.count >= variantCount * 2 { rectoCache.removeAll() }
        let image = render(size: size, scale: scale) { drawRecto(in: $0, size: size, variant: variant) }
        rectoCache[key] = image
        return image
    }

    static func verso(size: CGSize, scale: CGFloat) -> UIImage {
        let key = Key(size, scale, -1)
        if let image = versoCache[key] { return image }
        if versoCache.count >= 2 { versoCache.removeAll() }
        let image = render(size: size, scale: scale) { drawVerso(in: $0, size: size) }
        versoCache[key] = image
        return image
    }

    private static func render(size: CGSize, scale: CGFloat, _ draw: (CGContext) -> Void) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = true
        let safe = CGSize(width: max(size.width, 1), height: max(size.height, 1))
        return UIGraphicsImageRenderer(size: safe, format: format).image { draw($0.cgContext) }
    }

    // MARK: - Recto

    private struct RibbonLayout {
        var x: CGFloat, y: CGFloat
    }

    private static func layout(_ variant: Int) -> RibbonLayout {
        switch variant {
        case 1: RibbonLayout(x: 0.36, y: 0.35)
        case 2: RibbonLayout(x: 0.5, y: 0.41)
        default: RibbonLayout(x: 0.635, y: 0.37)
        }
    }

    private static func drawRecto(in g: CGContext, size: CGSize, variant: Int) {
        let w = size.width, h = size.height
        let space = CGColorSpaceCreateDeviceRGB()

        // Fond : rouge profond, éclairé en haut à gauche.
        let base = CGGradient(colorsSpace: space, colors: [
            rgb(0.80, 0.11, 0.16), rgb(0.67, 0.06, 0.11), rgb(0.46, 0.03, 0.07),
        ] as CFArray, locations: [0, 0.5, 1])!
        g.drawRadialGradient(base, startCenter: CGPoint(x: w * 0.3, y: h * 0.2), startRadius: 0,
                             endCenter: CGPoint(x: w * 0.3, y: h * 0.2), endRadius: hypot(w, h) * 0.95,
                             options: [.drawsAfterEndLocation])

        drawPattern(in: g, size: size, variant: variant)
        drawGrain(in: g, light: 0.05, dark: 0.07)

        // Brillant du papier glacé : une large bande diagonale très douce.
        let sheen = CGGradient(colorsSpace: space, colors: [
            rgb(1, 1, 1, 0), rgb(1, 1, 1, 0.075), rgb(1, 1, 1, 0), rgb(1, 1, 1, 0.04), rgb(1, 1, 1, 0),
        ] as CFArray, locations: [0, 0.3, 0.48, 0.62, 0.8])!
        g.drawLinearGradient(sheen, start: .zero, end: CGPoint(x: w, y: h), options: [])

        let ribbon = layout(variant)
        let rx = w * ribbon.x, ry = h * ribbon.y
        let band = w * 0.13
        drawRibbon(in: g, rect: CGRect(x: -2, y: ry - band / 2, width: w + 4, height: band), vertical: false, unit: w)
        drawRibbon(in: g, rect: CGRect(x: rx - band / 2, y: -2, width: band, height: h + 4), vertical: true, unit: w)
        drawBow(in: g, at: CGPoint(x: rx, y: ry), unit: w * 0.84)

        // Le papier s'assombrit vers les bords, comme replié sur la boîte.
        let vignette = CGGradient(colorsSpace: space, colors: [rgb(0, 0, 0, 0), rgb(0, 0, 0, 0.26)] as CFArray,
                                  locations: [0, 1])!
        let diagonal = hypot(w, h) / 2
        g.drawRadialGradient(vignette, startCenter: CGPoint(x: w / 2, y: h / 2), startRadius: diagonal * 0.45,
                             endCenter: CGPoint(x: w / 2, y: h / 2), endRadius: diagonal * 1.02,
                             options: [.drawsAfterEndLocation])
    }

    /// Motif en quinconce : diagonales de sapins, flocons et étoiles, petits points entre eux.
    private static func drawPattern(in g: CGContext, size: CGSize, variant: Int) {
        let w = size.width, h = size.height
        let step = w * 0.165
        let rowStep = step * 0.9
        let offset = CGPoint(x: CGFloat(variant) * step * 0.37, y: CGFloat(variant) * rowStep * 0.21)
        let rows = Int(h / rowStep) + 3, cols = Int(w / step) + 3

        g.saveGState()
        g.setAlpha(0.93)
        g.beginTransparencyLayer(auxiliaryInfo: nil)
        for row in -1..<rows {
            for col in -1..<cols {
                let shift: CGFloat = row.isMultiple(of: 2) ? 0 : 0.5
                let c = CGPoint(x: (CGFloat(col) + 0.5 + shift) * step + offset.x - step,
                                y: (CGFloat(row) + 0.5) * rowStep + offset.y - rowStep)
                switch ((col - row) % 3 + 3) % 3 {
                case 0: drawTree(in: g, at: c, height: w * 0.092)
                case 1: drawSnowflake(in: g, at: c, radius: w * 0.04, lineWidth: max(1, w * 0.0042))
                default: drawStarCluster(in: g, at: c, radius: w * 0.022)
                }
                // Points crème entre deux motifs d'une même rangée.
                g.setFillColor(cream.withAlphaComponent(0.55).cgColor)
                let r = w * 0.0048
                g.fillEllipse(in: CGRect(x: c.x + step / 2 - r, y: c.y - r, width: r * 2, height: r * 2))
            }
        }
        g.endTransparencyLayer()
        g.restoreGState()
    }

    private static func drawTree(in g: CGContext, at c: CGPoint, height hh: CGFloat) {
        let tree = CGMutablePath()
        for tier in 0..<3 {
            let t = CGFloat(tier)
            let top = c.y - hh * 0.5 + t * hh * 0.21
            let bottom = top + hh * 0.36
            let half = hh * (0.15 + 0.085 * t)
            tree.move(to: CGPoint(x: c.x, y: top))
            tree.addQuadCurve(to: CGPoint(x: c.x + half, y: bottom), control: CGPoint(x: c.x + half * 0.35, y: bottom - hh * 0.12))
            tree.addQuadCurve(to: CGPoint(x: c.x - half, y: bottom), control: CGPoint(x: c.x, y: bottom + hh * 0.07))
            tree.addQuadCurve(to: CGPoint(x: c.x, y: top), control: CGPoint(x: c.x - half * 0.35, y: bottom - hh * 0.12))
            tree.closeSubpath()
        }
        tree.addRect(CGRect(x: c.x - hh * 0.045, y: c.y + hh * 0.35, width: hh * 0.09, height: hh * 0.13))
        g.setFillColor(cream.cgColor)
        g.addPath(tree)
        g.fillPath()
        // Guirlande de perles dorées et étoile au sommet.
        g.setFillColor(gold.cgColor)
        for (dx, dy) in [(-0.07, -0.13), (0.09, -0.05), (-0.11, 0.08), (0.05, 0.15), (0.15, 0.24), (-0.16, 0.27)] as [(CGFloat, CGFloat)] {
            let r = hh * 0.028
            g.fillEllipse(in: CGRect(x: c.x + dx * hh - r, y: c.y + dy * hh - r, width: r * 2, height: r * 2))
        }
        g.addPath(starPath(center: CGPoint(x: c.x, y: c.y - hh * 0.52), radius: hh * 0.1, inner: 0.45))
        g.fillPath()
    }

    private static func drawSnowflake(in g: CGContext, at c: CGPoint, radius r: CGFloat, lineWidth: CGFloat) {
        let flake = CGMutablePath()
        for k in 0..<6 {
            let angle = CGFloat(k) * .pi / 3 - .pi / 2
            let dir = CGPoint(x: cos(angle), y: sin(angle))
            func at(_ d: CGFloat) -> CGPoint { CGPoint(x: c.x + dir.x * d, y: c.y + dir.y * d) }
            flake.move(to: at(r * 0.16))
            flake.addLine(to: at(r))
            for (d, length) in [(0.5, 0.3), (0.76, 0.2)] as [(CGFloat, CGFloat)] {
                for side in [-1.0, 1.0] as [CGFloat] {
                    let branch = angle + side * .pi / 4.2
                    let start = at(r * d)
                    flake.move(to: start)
                    flake.addLine(to: CGPoint(x: start.x + cos(branch) * r * length, y: start.y + sin(branch) * r * length))
                }
            }
        }
        g.setStrokeColor(cream.cgColor)
        g.setLineWidth(lineWidth)
        g.setLineCap(.round)
        g.addPath(flake)
        g.strokePath()
        g.setFillColor(cream.cgColor)
        let dot = r * 0.13
        g.fillEllipse(in: CGRect(x: c.x - dot, y: c.y - dot, width: dot * 2, height: dot * 2))
    }

    private static func drawStarCluster(in g: CGContext, at c: CGPoint, radius r: CGFloat) {
        g.setFillColor(gold.cgColor)
        g.addPath(starPath(center: c, radius: r, inner: 0.44))
        g.fillPath()
        g.setFillColor(cream.withAlphaComponent(0.85).cgColor)
        for (dx, dy, s) in [(1.5, -1.2, 0.2), (-1.6, 0.9, 0.16), (1.1, 1.5, 0.13)] as [(CGFloat, CGFloat, CGFloat)] {
            let rr = r * s
            g.fillEllipse(in: CGRect(x: c.x + dx * r - rr, y: c.y + dy * r - rr, width: rr * 2, height: rr * 2))
        }
    }

    private static func starPath(center c: CGPoint, radius r: CGFloat, inner: CGFloat) -> CGPath {
        let path = CGMutablePath()
        for i in 0..<10 {
            let angle = CGFloat(i) * .pi / 5 - .pi / 2
            let radius = i.isMultiple(of: 2) ? r : r * inner
            let p = CGPoint(x: c.x + cos(angle) * radius, y: c.y + sin(angle) * radius)
            if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
        }
        path.closeSubpath()
        return path
    }

    // MARK: - Ruban

    /// Ruban satiné : dégradé en travers, reflets en long, trame fine, lisières.
    private static func drawRibbon(in g: CGContext, rect: CGRect, vertical: Bool, unit w: CGFloat) {
        let space = CGColorSpaceCreateDeviceRGB()
        g.saveGState()
        g.setShadow(offset: CGSize(width: w * 0.002, height: w * 0.005), blur: w * 0.016, color: rgb(0.15, 0, 0.02, 0.55))
        g.setFillColor(rgb(0.80, 0.62, 0.28))
        g.fill(rect)
        g.restoreGState()

        g.saveGState()
        g.clip(to: rect)
        let across = CGGradient(colorsSpace: space, colors: [
            rgb(0.56, 0.39, 0.13), rgb(0.84, 0.66, 0.30), rgb(0.99, 0.91, 0.62), rgb(0.93, 0.79, 0.44),
            rgb(0.78, 0.59, 0.25), rgb(0.88, 0.72, 0.37), rgb(0.55, 0.38, 0.12),
        ] as CFArray, locations: [0, 0.1, 0.33, 0.5, 0.7, 0.88, 1])!
        let (a0, a1) = vertical
            ? (CGPoint(x: rect.minX, y: rect.midY), CGPoint(x: rect.maxX, y: rect.midY))
            : (CGPoint(x: rect.midX, y: rect.minY), CGPoint(x: rect.midX, y: rect.maxY))
        g.drawLinearGradient(across, start: a0, end: a1, options: [])

        // Reflets satinés le long du ruban.
        let along = CGGradient(colorsSpace: space, colors: [
            rgb(1, 1, 1, 0), rgb(1, 0.97, 0.85, 0.16), rgb(1, 1, 1, 0), rgb(0.3, 0.2, 0, 0.08),
            rgb(1, 0.97, 0.85, 0.2), rgb(1, 1, 1, 0), rgb(1, 0.97, 0.85, 0.1), rgb(1, 1, 1, 0),
        ] as CFArray, locations: [0, 0.14, 0.3, 0.45, 0.6, 0.74, 0.88, 1])!
        let (b0, b1) = vertical
            ? (CGPoint(x: rect.midX, y: rect.minY), CGPoint(x: rect.midX, y: rect.maxY))
            : (CGPoint(x: rect.minX, y: rect.midY), CGPoint(x: rect.maxX, y: rect.midY))
        g.drawLinearGradient(along, start: b0, end: b1, options: [])

        // Trame : fines lignes dans le sens du ruban.
        let thickness = vertical ? rect.width : rect.height
        var d: CGFloat = 0.6
        var light = true
        g.setLineWidth(0.35)
        while d < thickness {
            g.setStrokeColor(light ? rgb(1, 0.96, 0.8, 0.07) : rgb(0.25, 0.15, 0, 0.06))
            if vertical {
                g.move(to: CGPoint(x: rect.minX + d, y: rect.minY)); g.addLine(to: CGPoint(x: rect.minX + d, y: rect.maxY))
            } else {
                g.move(to: CGPoint(x: rect.minX, y: rect.minY + d)); g.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + d))
            }
            g.strokePath()
            d += 0.9
            light.toggle()
        }

        // Lisières : un trait sombre au bord, un trait clair juste à l'intérieur.
        for (inset, color, width) in [(0.5, rgb(0.42, 0.27, 0.07, 0.8), 1.0), (2.4, rgb(1, 0.93, 0.66, 0.55), 0.6)] as [(CGFloat, CGColor, CGFloat)] {
            g.setStrokeColor(color)
            g.setLineWidth(width)
            if vertical {
                for x in [rect.minX + inset, rect.maxX - inset] {
                    g.move(to: CGPoint(x: x, y: rect.minY)); g.addLine(to: CGPoint(x: x, y: rect.maxY))
                }
            } else {
                for y in [rect.minY + inset, rect.maxY - inset] {
                    g.move(to: CGPoint(x: rect.minX, y: y)); g.addLine(to: CGPoint(x: rect.maxX, y: y))
                }
            }
            g.strokePath()
        }
        g.restoreGState()
    }

    // MARK: - Nœud

    private static func drawBow(in g: CGContext, at k: CGPoint, unit u: CGFloat) {
        let space = CGColorSpaceCreateDeviceRGB()
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: k.x + x * u, y: k.y + y * u) }

        func loop(_ s: CGFloat) -> CGPath {
            let path = CGMutablePath()
            path.move(to: p(0.018 * s, -0.022))
            path.addCurve(to: p(0.215 * s, -0.118), control1: p(0.06 * s, -0.085), control2: p(0.14 * s, -0.15))
            path.addCurve(to: p(0.232 * s, 0.01), control1: p(0.29 * s, -0.085), control2: p(0.29 * s, -0.02))
            path.addCurve(to: p(0.018 * s, 0.024), control1: p(0.16 * s, 0.04), control2: p(0.07 * s, 0.045))
            path.closeSubpath()
            return path
        }
        func hollow(_ s: CGFloat) -> CGPath {
            let path = CGMutablePath()
            path.move(to: p(0.062 * s, -0.004))
            path.addCurve(to: p(0.2 * s, -0.074), control1: p(0.1 * s, -0.05), control2: p(0.16 * s, -0.088))
            path.addCurve(to: p(0.214 * s, -0.004), control1: p(0.242 * s, -0.056), control2: p(0.246 * s, -0.02))
            path.addCurve(to: p(0.062 * s, 0.01), control1: p(0.15 * s, 0.012), control2: p(0.095 * s, 0.02))
            path.closeSubpath()
            return path
        }
        /// Pan de ruban qui pend, terminé en queue d'aronde.
        func tail(_ s: CGFloat) -> (CGPath, CGPoint, CGPoint) {
            let start = SIMD2<Double>(Double(0.014 * s), 0.012)
            let control = SIMD2<Double>(Double(0.045 * s), 0.12)
            let end = SIMD2<Double>(Double(0.14 * s), 0.235)
            var left: [CGPoint] = [], right: [CGPoint] = []
            let n = 18
            for i in 0...n {
                let t = Double(i) / Double(n)
                let a = (1 - t) * (1 - t), b = 2 * (1 - t) * t, c = t * t
                let q = start * a + control * b + end * c
                let d = simd_normalize((control - start) * (2 * (1 - t)) + (end - control) * (2 * t))
                let half = 0.047 - 0.005 * t
                let normal = SIMD2(-d.y, d.x) * half
                left.append(p(CGFloat(q.x + normal.x), CGFloat(q.y + normal.y)))
                right.append(p(CGFloat(q.x - normal.x), CGFloat(q.y - normal.y)))
            }
            let endDir = simd_normalize(end - control)
            let notch = end - endDir * 0.034
            let path = CGMutablePath()
            path.addLines(between: left)
            path.addLine(to: p(CGFloat(notch.x), CGFloat(notch.y)))
            path.addLines(between: right.reversed())
            path.closeSubpath()
            let mid = start * 0.25 + control * 0.5 + end * 0.25
            let midDir = simd_normalize(end - start)
            let across = SIMD2(-midDir.y, midDir.x) * 0.05
            return (path, p(CGFloat(mid.x + across.x), CGFloat(mid.y + across.y)), p(CGFloat(mid.x - across.x), CGFloat(mid.y - across.y)))
        }
        let knotRect = CGRect(x: k.x - 0.052 * u, y: k.y - 0.046 * u, width: 0.104 * u, height: 0.092 * u)
        let knot = CGPath(roundedRect: knotRect, cornerWidth: 0.026 * u, cornerHeight: 0.026 * u, transform: nil)
        let tails = [tail(-1), tail(1)]
        let loops = [loop(-1), loop(1)]

        // Ombre de l'ensemble sur le papier.
        let silhouette = CGMutablePath()
        for t in tails { silhouette.addPath(t.0) }
        for l in loops { silhouette.addPath(l) }
        silhouette.addPath(knot)
        g.saveGState()
        g.setShadow(offset: CGSize(width: 0.006 * u, height: 0.018 * u), blur: 0.035 * u, color: rgb(0.12, 0, 0.02, 0.6))
        g.setFillColor(rgb(0.8, 0.62, 0.28))
        g.addPath(silhouette)
        g.fillPath()
        g.restoreGState()

        let satin = CGGradient(colorsSpace: space, colors: [
            rgb(0.55, 0.38, 0.12), rgb(0.86, 0.68, 0.32), rgb(0.99, 0.91, 0.63), rgb(0.86, 0.68, 0.31), rgb(0.6, 0.42, 0.14),
        ] as CFArray, locations: [0, 0.22, 0.48, 0.75, 1])!

        // Pans.
        for t in tails {
            g.saveGState()
            g.addPath(t.0)
            g.clip()
            g.drawLinearGradient(satin, start: t.1, end: t.2, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
            // Le pan s'assombrit sous le nœud.
            let shade = CGGradient(colorsSpace: space, colors: [rgb(0.2, 0.1, 0, 0.45), rgb(0.2, 0.1, 0, 0)] as CFArray, locations: [0, 1])!
            g.drawRadialGradient(shade, startCenter: k, startRadius: 0, endCenter: k, endRadius: 0.12 * u, options: [])
            g.restoreGState()
            g.addPath(t.0)
            g.setStrokeColor(rgb(0.45, 0.3, 0.08, 0.7))
            g.setLineWidth(0.6)
            g.strokePath()
        }

        // Boucles : satin qui s'éclaire vers l'extrémité, creux sombre, reflet sur l'arête du haut.
        for (index, l) in loops.enumerated() {
            let s: CGFloat = index == 0 ? -1 : 1
            g.saveGState()
            g.addPath(l)
            g.clip()
            let lit = CGGradient(colorsSpace: space, colors: [
                rgb(0.6, 0.42, 0.14), rgb(0.9, 0.73, 0.37), rgb(1, 0.92, 0.66), rgb(0.84, 0.65, 0.29),
            ] as CFArray, locations: [0, 0.45, 0.72, 1])!
            g.drawLinearGradient(lit, start: p(0.02 * s, 0.02), end: p(0.27 * s, -0.08), options: [.drawsAfterEndLocation])
            g.addPath(hollow(s))
            g.clip()
            let inside = CGGradient(colorsSpace: space, colors: [rgb(0.38, 0.24, 0.06), rgb(0.62, 0.44, 0.15), rgb(0.78, 0.6, 0.26)] as CFArray,
                                    locations: [0, 0.6, 1])!
            g.drawLinearGradient(inside, start: p(0.14 * s, -0.07), end: p(0.14 * s, 0.015), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
            g.restoreGState()

            let ridge = CGMutablePath()
            ridge.move(to: p(0.04 * s, -0.04))
            ridge.addCurve(to: p(0.21 * s, -0.108), control1: p(0.08 * s, -0.088), control2: p(0.15 * s, -0.132))
            g.addPath(ridge)
            g.setStrokeColor(rgb(1, 0.98, 0.88, 0.6))
            g.setLineWidth(0.007 * u)
            g.setLineCap(.round)
            g.strokePath()

            g.addPath(l)
            g.setStrokeColor(rgb(0.45, 0.3, 0.08, 0.75))
            g.setLineWidth(0.6)
            g.strokePath()
        }

        // Nœud central, bombé.
        g.saveGState()
        g.addPath(knot)
        g.clip()
        let knotGradient = CGGradient(colorsSpace: space, colors: [rgb(1, 0.93, 0.68), rgb(0.9, 0.73, 0.37), rgb(0.62, 0.44, 0.15)] as CFArray,
                                      locations: [0, 0.45, 1])!
        g.drawLinearGradient(knotGradient, start: CGPoint(x: knotRect.midX, y: knotRect.minY),
                             end: CGPoint(x: knotRect.midX, y: knotRect.maxY), options: [])
        g.setStrokeColor(rgb(0.45, 0.3, 0.08, 0.35))
        g.setLineWidth(0.6)
        for dx in [-0.022, 0.024] as [CGFloat] {
            g.move(to: CGPoint(x: k.x + dx * u, y: knotRect.minY + 1))
            g.addQuadCurve(to: CGPoint(x: k.x + dx * u * 0.8, y: knotRect.maxY - 1), control: CGPoint(x: k.x + dx * u * 1.5, y: k.y))
        }
        g.strokePath()
        g.restoreGState()
        g.addPath(knot)
        g.setStrokeColor(rgb(0.45, 0.3, 0.08, 0.8))
        g.setLineWidth(0.7)
        g.strokePath()
    }

    // MARK: - Verso

    private static func drawVerso(in g: CGContext, size: CGSize) {
        let w = size.width, h = size.height
        g.setFillColor(versoBase.cgColor)
        g.fill(CGRect(origin: .zero, size: size))
        drawGrain(in: g, light: 0.05, dark: 0.045)
        // Quadrillage de découpe, un trait plus marqué toutes les quatre cases.
        let cell = w * 0.05
        var i = 0
        var x: CGFloat = cell * 0.5
        while x < w {
            g.setStrokeColor(rgb(0.52, 0.6, 0.72, i % 4 == 0 ? 0.32 : 0.16))
            g.setLineWidth(i % 4 == 0 ? 0.7 : 0.45)
            g.move(to: CGPoint(x: x, y: 0)); g.addLine(to: CGPoint(x: x, y: h)); g.strokePath()
            x += cell; i += 1
        }
        i = 0
        var y: CGFloat = cell * 0.5
        while y < h {
            g.setStrokeColor(rgb(0.52, 0.6, 0.72, i % 4 == 0 ? 0.32 : 0.16))
            g.setLineWidth(i % 4 == 0 ? 0.7 : 0.45)
            g.move(to: CGPoint(x: 0, y: y)); g.addLine(to: CGPoint(x: w, y: y)); g.strokePath()
            y += cell; i += 1
        }
    }

    // MARK: - Grain

    /// Grain du papier : une petite tuile de bruit répétée.
    private static func drawGrain(in g: CGContext, light: CGFloat, dark: CGFloat) {
        guard let tile = noiseTile(light: light, dark: dark) else { return }
        g.saveGState()
        // La tuile est en pixels : on la dessine à la résolution de l'écran.
        let pixel = 1 / max(1, g.ctm.a)
        g.draw(tile, in: CGRect(x: 0, y: 0, width: CGFloat(tile.width) * pixel, height: CGFloat(tile.height) * pixel), byTiling: true)
        g.restoreGState()
    }

    private static func noiseTile(light: CGFloat, dark: CGFloat) -> CGImage? {
        let side = 160
        var rng = SeededRandom(seed: 4242)
        var bytes = [UInt8](repeating: 0, count: side * side * 4)
        for i in 0..<(side * side) {
            let r = Float.random(in: 0..<1, using: &rng)
            let isLight = r < 0.5
            let strength = CGFloat(Float.random(in: 0..<1, using: &rng)) * (isLight ? light : dark)
            let alpha = UInt8(min(255, strength * 255))
            let value: UInt8 = isLight ? alpha : 0   // prémultiplié
            bytes[i * 4] = value
            bytes[i * 4 + 1] = value
            bytes[i * 4 + 2] = value
            bytes[i * 4 + 3] = alpha
        }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(width: side, height: side, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: side * 4,
                       space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    private static func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
        CGColor(red: r, green: g, blue: b, alpha: a)
    }
}
