import UIKit

/// Photo d'exemple dessinée au lancement : un sapin illuminé sur fond de bokeh chaleureux.
enum SamplePhoto {
    static let size = CGSize(width: 1200, height: 1600)

    static func render() -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            let cg = context.cgContext
            var rng = SeededRandom(seed: 2026)
            drawBackground(cg)
            drawBokeh(cg, rng: &rng)
            drawFloorGlow(cg)
            drawTree(cg, rng: &rng)
            drawGifts(cg)
            drawVignette(cg)
        }
    }

    private static let space = CGColorSpace(name: CGColorSpace.sRGB)!

    private static func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
        CGColor(colorSpace: space, components: [r, g, b, a])!
    }

    private static func gradient(_ colors: [CGColor], _ locations: [CGFloat]) -> CGGradient {
        CGGradient(colorsSpace: space, colors: colors as CFArray, locations: locations)!
    }

    private static func drawBackground(_ cg: CGContext) {
        let g = gradient([color(0.10, 0.04, 0.05), color(0.30, 0.09, 0.07), color(0.16, 0.06, 0.04)], [0, 0.55, 1])
        cg.drawLinearGradient(g, start: .zero, end: CGPoint(x: 0, y: size.height), options: [])
        // Lueur chaude derrière le sapin.
        let glow = gradient([color(1.0, 0.62, 0.30, 0.45), color(1.0, 0.45, 0.20, 0)], [0, 1])
        cg.drawRadialGradient(glow, startCenter: CGPoint(x: 600, y: 820), startRadius: 0,
                              endCenter: CGPoint(x: 600, y: 820), endRadius: 760, options: [])
    }

    private static func drawBokeh(_ cg: CGContext, rng: inout SeededRandom) {
        let tints: [(CGFloat, CGFloat, CGFloat)] = [(1, 0.80, 0.45), (1, 0.62, 0.30), (1, 0.42, 0.30), (0.55, 0.85, 0.55), (1, 0.92, 0.75)]
        for _ in 0..<150 {
            let t = tints[Int.random(in: 0..<tints.count, using: &rng)]
            let r = CGFloat(rng.float(14...85))
            let p = CGPoint(x: CGFloat(rng.float(-40...1240)), y: CGFloat(rng.float(-40...1100)))
            let a = CGFloat(rng.float(0.06...0.32))
            let disc = gradient([color(t.0, t.1, t.2, a), color(t.0, t.1, t.2, a * 0.75), color(t.0, t.1, t.2, 0)], [0, 0.82, 1])
            cg.drawRadialGradient(disc, startCenter: p, startRadius: 0, endCenter: p, endRadius: r, options: [])
        }
    }

    private static func drawFloorGlow(_ cg: CGContext) {
        let floor = gradient([color(0.45, 0.20, 0.10, 0.0), color(0.55, 0.26, 0.12, 0.55)], [0, 1])
        cg.drawLinearGradient(floor, start: CGPoint(x: 0, y: 1250), end: CGPoint(x: 0, y: 1600), options: [])
    }

    private static func drawTree(_ cg: CGContext, rng: inout SeededRandom) {
        let centerX: CGFloat = 600
        let tiers: [(top: CGFloat, bottom: CGFloat, halfWidth: CGFloat)] = [
            (300, 620, 210), (470, 860, 300), (660, 1110, 390), (860, 1340, 470),
        ]
        // Tronc.
        cg.setFillColor(color(0.22, 0.12, 0.07))
        cg.fill(CGRect(x: centerX - 40, y: 1300, width: 80, height: 110))

        for tier in tiers {
            let path = CGMutablePath()
            path.move(to: CGPoint(x: centerX, y: tier.top))
            path.addQuadCurve(to: CGPoint(x: centerX + tier.halfWidth, y: tier.bottom),
                              control: CGPoint(x: centerX + tier.halfWidth * 0.45, y: tier.bottom - 120))
            path.addQuadCurve(to: CGPoint(x: centerX - tier.halfWidth, y: tier.bottom),
                              control: CGPoint(x: centerX, y: tier.bottom + 55))
            path.addQuadCurve(to: CGPoint(x: centerX, y: tier.top),
                              control: CGPoint(x: centerX - tier.halfWidth * 0.45, y: tier.bottom - 120))
            cg.saveGState()
            cg.addPath(path)
            cg.clip()
            let fir = gradient([color(0.08, 0.30, 0.18), color(0.04, 0.17, 0.10)], [0, 1])
            cg.drawLinearGradient(fir, start: CGPoint(x: centerX - tier.halfWidth, y: tier.top),
                                  end: CGPoint(x: centerX + tier.halfWidth, y: tier.bottom), options: [])
            cg.restoreGState()
        }

        // Guirlandes : arcs de petites lumières.
        let lightTints: [(CGFloat, CGFloat, CGFloat)] = [(1, 0.86, 0.55), (1, 0.55, 0.35), (1, 0.95, 0.85), (0.95, 0.35, 0.30)]
        for row in 0..<7 {
            let y0 = 470 + CGFloat(row) * 125
            let halfWidth = 120 + CGFloat(row) * 55
            for i in 0...18 {
                let t = CGFloat(i) / 18
                let x = centerX - halfWidth + t * halfWidth * 2
                let y = y0 + sin(t * .pi) * 60 + CGFloat(row % 2 == 0 ? 0 : -20)
                let tint = lightTints[Int.random(in: 0..<lightTints.count, using: &rng)]
                let p = CGPoint(x: x, y: y)
                let halo = gradient([color(tint.0, tint.1, tint.2, 0.75), color(tint.0, tint.1, tint.2, 0)], [0, 1])
                cg.drawRadialGradient(halo, startCenter: p, startRadius: 0, endCenter: p, endRadius: 26, options: [])
                cg.setFillColor(color(1, 0.97, 0.88))
                cg.fillEllipse(in: CGRect(x: x - 5, y: y - 5, width: 10, height: 10))
            }
        }

        // Boules.
        let baubles: [(CGPoint, CGFloat, (CGFloat, CGFloat, CGFloat))] = [
            (CGPoint(x: 520, y: 700), 26, (0.78, 0.10, 0.14)), (CGPoint(x: 690, y: 820), 30, (0.92, 0.72, 0.30)),
            (CGPoint(x: 470, y: 990), 32, (0.92, 0.72, 0.30)), (CGPoint(x: 730, y: 1060), 34, (0.78, 0.10, 0.14)),
            (CGPoint(x: 600, y: 1200), 34, (0.85, 0.85, 0.90)), (CGPoint(x: 380, y: 1230), 30, (0.78, 0.10, 0.14)),
            (CGPoint(x: 820, y: 1250), 30, (0.92, 0.72, 0.30)), (CGPoint(x: 610, y: 560), 22, (0.85, 0.85, 0.90)),
        ]
        for (p, r, c) in baubles {
            let ball = gradient([color(min(1, c.0 + 0.35), min(1, c.1 + 0.35), min(1, c.2 + 0.35)), color(c.0, c.1, c.2), color(c.0 * 0.4, c.1 * 0.4, c.2 * 0.4)], [0, 0.45, 1])
            cg.saveGState()
            cg.addEllipse(in: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2))
            cg.clip()
            cg.drawRadialGradient(ball, startCenter: CGPoint(x: p.x - r * 0.35, y: p.y - r * 0.4), startRadius: 0,
                                  endCenter: p, endRadius: r * 1.1, options: [.drawsAfterEndLocation])
            cg.restoreGState()
        }

        // Étoile au sommet.
        let starCenter = CGPoint(x: centerX, y: 285)
        let starGlow = gradient([color(1, 0.88, 0.50, 0.9), color(1, 0.75, 0.35, 0)], [0, 1])
        cg.drawRadialGradient(starGlow, startCenter: starCenter, startRadius: 0, endCenter: starCenter, endRadius: 170, options: [])
        let star = CGMutablePath()
        for i in 0..<10 {
            let angle = CGFloat(i) * .pi / 5 - .pi / 2
            let radius: CGFloat = i.isMultiple(of: 2) ? 62 : 26
            let point = CGPoint(x: starCenter.x + cos(angle) * radius, y: starCenter.y + sin(angle) * radius)
            if i == 0 { star.move(to: point) } else { star.addLine(to: point) }
        }
        star.closeSubpath()
        cg.addPath(star)
        cg.setFillColor(color(1, 0.86, 0.45))
        cg.fillPath()
    }

    private static func drawGifts(_ cg: CGContext) {
        let gifts: [(CGRect, (CGFloat, CGFloat, CGFloat), (CGFloat, CGFloat, CGFloat))] = [
            (CGRect(x: 250, y: 1330, width: 200, height: 170), (0.72, 0.08, 0.12), (0.95, 0.78, 0.38)),
            (CGRect(x: 690, y: 1360, width: 240, height: 150), (0.10, 0.42, 0.24), (0.86, 0.15, 0.18)),
            (CGRect(x: 470, y: 1400, width: 190, height: 130), (0.92, 0.74, 0.34), (0.10, 0.42, 0.24)),
        ]
        for (rect, box, ribbon) in gifts {
            cg.setFillColor(color(box.0, box.1, box.2))
            cg.fill(rect)
            cg.setFillColor(color(box.0 * 0.7, box.1 * 0.7, box.2 * 0.7))
            cg.fill(CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: 26))
            cg.setFillColor(color(ribbon.0, ribbon.1, ribbon.2))
            cg.fill(CGRect(x: rect.midX - 14, y: rect.minY, width: 28, height: rect.height))
            cg.fill(CGRect(x: rect.minX, y: rect.minY + 30, width: rect.width, height: 22))
            cg.fillEllipse(in: CGRect(x: rect.midX - 48, y: rect.minY - 30, width: 46, height: 34))
            cg.fillEllipse(in: CGRect(x: rect.midX + 2, y: rect.minY - 30, width: 46, height: 34))
        }
    }

    private static func drawVignette(_ cg: CGContext) {
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let vignette = gradient([color(0, 0, 0, 0), color(0, 0, 0, 0.55)], [0.55, 1])
        cg.drawRadialGradient(vignette, startCenter: center, startRadius: 0, endCenter: center, endRadius: 1050, options: [.drawsAfterEndLocation])
    }
}
