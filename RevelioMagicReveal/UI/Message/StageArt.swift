import SwiftUI

/// Ce qu'une scène lit pour dessiner une image : l'analyse, le son brut, l'instant de lecture.
struct StageInput {
    let analysis: AudioMessageAnalysis
    let message: AudioMessage
    let time: Double
    let photo: MessagePhoto?
}

/// Le dessin des visualisations du message. Chacune est une fonction de l'instant de lecture, sans
/// état : on peut scrubber, revenir en arrière, la même seconde donne la même image.
enum StageArt {
    static func draw(_ kind: AudioMessageModel.Visualization, in context: inout GraphicsContext, size: CGSize,
                     input: StageInput) {
        switch kind {
        case .halo: halo(&context, size, input)
        case .ring: ring(&context, size, input)
        case .scope: scope(&context, size, input)
        case .scroll: scroll(&context, size, input)
        case .orb: orb(&context, size, input)
        }
    }

    private static let gold = Palette.gold
    private static let cream = Palette.cream
    private static let fir = Palette.fir

    // MARK: - Halo

    /// La photo en médaillon qui palpite. Trois anneaux suivent chacun leur registre (graves au plus
    /// près, aigus au plus loin), le halo se réchauffe ou s'éclaircit avec le timbre, et chaque syllabe
    /// lance une onde qui s'éloigne en ralentissant.
    private static func halo(_ ctx: inout GraphicsContext, _ size: CGSize, _ s: StageInput) {
        let c = CGPoint(x: size.width / 2, y: size.height / 2)
        let side = min(size.width, size.height)
        let level = CGFloat(s.analysis.level(at: s.time))
        let registers = registerEnergy(s.analysis.spectrum(at: s.time))
        let tone = gold.mix(with: cream, by: Double(s.analysis.centroid(at: s.time)) * 0.8)
        let r = side * 0.22 * (1 + 0.04 * level)

        let glow = r * (1.35 + 0.9 * level)
        ctx.fill(circle(c, glow), with: .radialGradient(Gradient(colors: [tone.opacity(0.12 + 0.45 * level), tone.opacity(0)]),
                                                         center: c, startRadius: r * 0.9, endRadius: glow))
        for onset in s.analysis.onsets(in: (s.time - 1.6)...s.time) {
            let age = CGFloat((s.time - onset.time) / 1.6)
            let travel = 1 - (1 - age) * (1 - age)
            ctx.stroke(circle(c, r * (1.06 + 1.35 * travel)),
                       with: .color(cream.opacity(pow(1 - age, 1.5) * 0.6 * CGFloat(onset.strength))),
                       lineWidth: 1 + 2.5 * (1 - age))
        }
        for (k, energy) in registers.enumerated() {
            let kk = CGFloat(k)
            let color = gold.mix(with: cream, by: 0.3 * Double(k))
            ctx.stroke(circle(c, r * (1.12 + 0.18 * kk) + side * 0.05 * energy),
                       with: .color(color.opacity(0.3 + 0.55 * energy)), lineWidth: 1.2 + 2.6 * energy)
        }
        drawPhoto(&ctx, s.photo?.photo, clip: circle(c, r), frame: square(c, r))
        ctx.stroke(circle(c, r), with: .color(gold), lineWidth: 3)
    }

    // MARK: - Couronne

    /// Les fréquences en rayons autour de la photo (graves en haut, aigus en bas, symétrique), avec une
    /// crête qui retombe doucement au bout de chacun. La couronne tourne lentement à mesure que la voix
    /// avance.
    private static func ring(_ ctx: inout GraphicsContext, _ size: CGSize, _ s: StageInput) {
        let c = CGPoint(x: size.width / 2, y: size.height / 2)
        let side = min(size.width, size.height)
        let level = CGFloat(s.analysis.level(at: s.time))
        let r = side * 0.17
        let inner = r * 1.28
        let maxLength = side * 0.19
        let bands = s.analysis.spectrum(at: s.time)
        let peaks = s.analysis.peaks(at: s.time)
        let count = AudioMessageAnalysis.bandCount * 2
        let rotation = Double(s.analysis.cumulative(at: s.time)) * 0.5

        ctx.fill(circle(c, inner), with: .radialGradient(Gradient(colors: [gold.opacity(0.1 + 0.35 * level), gold.opacity(0)]),
                                                          center: c, startRadius: r, endRadius: inner))
        ctx.stroke(circle(c, inner - 5), with: .color(gold.opacity(0.35)), lineWidth: 1)

        var rays = Path(), tips = Path()
        for i in 0..<count {
            let band = i < count / 2 ? i : count - 1 - i
            let fraction = (Double(i) + 0.5) / Double(count)
            let angle: Double = fraction * 2 * Double.pi - Double.pi / 2 + rotation
            let length = 3 + CGFloat(bands[band]) * maxLength
            rays.move(to: polar(c, angle, inner))
            rays.addLine(to: polar(c, angle, inner + length))
            let tip = polar(c, angle, inner + 9 + CGFloat(peaks[band]) * maxLength)
            tips.addEllipse(in: CGRect(x: tip.x - 1.6, y: tip.y - 1.6, width: 3.2, height: 3.2))
        }
        var glow = ctx
        glow.blendMode = .plusLighter
        glow.opacity = 0.3
        glow.stroke(rays, with: .color(gold), style: StrokeStyle(lineWidth: 8, lineCap: .round))
        ctx.stroke(rays, with: .radialGradient(Gradient(colors: [gold, cream]), center: c, startRadius: inner,
                                               endRadius: inner + maxLength),
                   style: StrokeStyle(lineWidth: 3.5, lineCap: .round))
        ctx.fill(tips, with: .color(cream.opacity(0.85)))

        let photoRadius = r * (1 + 0.05 * level)
        drawPhoto(&ctx, s.photo?.photo, clip: circle(c, photoRadius), frame: square(c, photoRadius))
        ctx.stroke(circle(c, photoRadius), with: .color(gold), lineWidth: 2)
    }

    // MARK: - Oscilloscope

    /// La forme d'onde elle-même. L'axe du temps est plus serré vers les bords (« fisheye ») : les périodes
    /// de la voix n'ont pas toutes la même largeur et ne se répètent plus à l'identique sur toute la
    /// largeur. Silhouette en dôme arrondi (ni losange, ni bande uniforme). Les trois traces précédentes
    /// restent en rémanence, comme sur un écran à phosphore.
    private static func scope(_ ctx: inout GraphicsContext, _ size: CGSize, _ s: StageInput) {
        let mid = size.height / 2
        var axis = Path()
        axis.move(to: CGPoint(x: 16, y: mid))
        axis.addLine(to: CGPoint(x: size.width - 16, y: mid))
        ctx.stroke(axis, with: .color(cream.opacity(0.08)), lineWidth: 1)

        let left: CGFloat = 16, width = size.width - 32
        let amplitude = size.height * 0.4 / CGFloat(max(s.analysis.peak, 0.05))
        let limit = size.height * 0.44
        let echoes: [(lag: Double, opacity: Double)] = [(0.09, 0.1), (0.06, 0.18), (0.03, 0.32), (0, 1)]
        for echo in echoes {
            let trace = scopeTrace(s.message, at: s.time - echo.lag, left: left, width: width, mid: mid,
                                   amplitude: amplitude, limit: limit)
            guard echo.lag == 0 else {
                var ghost = ctx
                ghost.opacity = echo.opacity
                ghost.stroke(trace, with: .color(gold), style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                continue
            }
            // Le corps de l'onde, plein vers ses crêtes, transparent sur l'axe.
            var body = trace
            body.addLine(to: CGPoint(x: left + width, y: mid))
            body.addLine(to: CGPoint(x: left, y: mid))
            body.closeSubpath()
            ctx.fill(body, with: .linearGradient(Gradient(colors: [gold.opacity(0.28), gold.opacity(0), gold.opacity(0.28)]),
                                                 startPoint: CGPoint(x: 0, y: mid - limit), endPoint: CGPoint(x: 0, y: mid + limit)))
            var glow = ctx
            glow.blendMode = .plusLighter
            glow.stroke(trace, with: .color(gold.opacity(0.18)), style: StrokeStyle(lineWidth: 10, lineCap: .round, lineJoin: .round))
            glow.stroke(trace, with: .color(gold.opacity(0.45)), style: StrokeStyle(lineWidth: 4.5, lineCap: .round, lineJoin: .round))
            ctx.stroke(trace, with: .color(cream), style: StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round))
        }
    }

    /// Une trace d'oscilloscope calée sur un passage par zéro montant juste avant `time`. 60 ms de son :
    /// la durée par point grandit vers les bords (sinh) ; un profil en dôme (racine du sinus : large et
    /// arrondi, sans pointe au centre) ramène les bords à plat.
    private static func scopeTrace(_ message: AudioMessage, at time: Double, left: CGFloat, width: CGFloat,
                                   mid: CGFloat, amplitude: CGFloat, limit: CGFloat) -> Path {
        let span = 0.06, curvature = 2.8, count = 240
        let center = message.risingZeroCrossing(before: time, within: 0.012)
        let norm = 2 * sinh(curvature / 2)
        let points = (0...count).map { i -> CGPoint in
            let x = Double(i) / Double(count)
            let u = x - 0.5
            let offset = span * sinh(curvature * u) / norm
            let perPoint = span * curvature * cosh(curvature * u) / norm / Double(count)
            let value = CGFloat(message.average(at: center + offset, window: perPoint))
            let envelope = CGFloat(sin(Double.pi * x).squareRoot())
            let y = min(max(value * amplitude * envelope, -limit), limit)
            return CGPoint(x: left + CGFloat(x) * width, y: mid - y)
        }
        return smooth(points)
    }

    // MARK: - Onde défilante

    /// Façon dictaphone : l'onde symétrique défile, la tête de lecture reste au centre. Hauteur contenue
    /// (40 % de la scène au plus) : plus haut, l'onde écrasait le cadre.
    private static func scroll(_ ctx: inout GraphicsContext, _ size: CGSize, _ s: StageInput) {
        let window = 4.0, step = 0.06
        let perSecond = size.width / window
        let centerX = size.width / 2, mid = size.height / 2
        let width = max(2, perSecond * step * 0.55)
        let corner = CGSize(width: width / 2, height: width / 2)
        var past = Path(), future = Path()
        let first = Int(((s.time - window / 2) / step).rounded(.down))
        let last = Int(((s.time + window / 2) / step).rounded(.up))
        for i in first...last {
            let t = Double(i) * step
            guard t >= 0, t <= s.analysis.duration else { continue }
            let x = centerX + CGFloat(t - s.time) * perSecond
            let peak = AudioMessageAnalysis.waveHeight(s.analysis.envelopePeak(in: t...(t + step)))
            let height = 2 + CGFloat(peak) * size.height * 0.2
            let bar = CGRect(x: x - width / 2, y: mid - height, width: width, height: height * 2)
            if t <= s.time {
                past.addRoundedRect(in: bar, cornerSize: corner)
            } else {
                future.addRoundedRect(in: bar, cornerSize: corner)
            }
        }
        ctx.fill(past, with: .color(gold))
        ctx.fill(future, with: .color(cream.opacity(0.3)))
        let reach = size.height * 0.27
        var head = Path()
        head.move(to: CGPoint(x: centerX, y: mid - reach))
        head.addLine(to: CGPoint(x: centerX, y: mid + reach))
        ctx.stroke(head, with: .color(cream), lineWidth: 2)
        ctx.fill(circle(CGPoint(x: centerX, y: mid - reach), 4.5), with: .color(cream))
        fadeEdges(&ctx, size)
    }

    // MARK: - Orbe

    /// Trois bulles superposées (graves, médiums, aigus) dont le contour ondule avec leurs fréquences.
    private static func orb(_ ctx: inout GraphicsContext, _ size: CGSize, _ s: StageInput) {
        let c = CGPoint(x: size.width / 2, y: size.height / 2)
        let side = min(size.width, size.height)
        let level = CGFloat(s.analysis.level(at: s.time))
        let bands = s.analysis.spectrum(at: s.time).map { CGFloat($0) }
        let groups = [0..<11, 11..<22, 22..<32]
        // Bords lumineux plutôt que centres pleins : trois centres superposés en mode additif tournent au blanc.
        let colors = [gold, Color(red: 0.95, green: 0.42, blue: 0.36), Color(red: 0.45, green: 0.85, blue: 0.75)]
        var layer = ctx
        layer.blendMode = .plusLighter
        layer.opacity = 0.75
        for (index, group) in groups.enumerated() {
            let values = Array(bands[group])
            let energy = values.reduce(0, +) / CGFloat(values.count)
            let radius = side * (0.15 + 0.04 * CGFloat(index)) * (1 + 0.3 * level + 0.15 * energy)
            let quarter = max(1, values.count / 4)
            let ripples = (0..<4).map { k -> CGFloat in
                let slice = values[min(k * quarter, values.count - 1)..<min((k + 1) * quarter, values.count)]
                return slice.reduce(0, +) / CGFloat(max(slice.count, 1)) * 0.1
            }
            let spin = s.time * (0.5 + 0.25 * Double(index)) * (index.isMultiple(of: 2) ? 1 : -1)
            let points = (0..<96).map { p -> CGPoint in
                let angle = Double(p) / 96 * 2 * .pi
                var scale: CGFloat = 1
                for (k, ripple) in ripples.enumerated() {
                    scale += ripple * CGFloat(sin(Double(k + 2) * angle + spin * Double(k + 1) + Double(index) * 1.7))
                }
                return polar(c, angle, radius * min(scale, 1.3))
            }
            let color = colors[index]
            let rim = Gradient(stops: [.init(color: color.opacity(0.12), location: 0),
                                       .init(color: color.opacity(0.7), location: 0.7),
                                       .init(color: color.opacity(0), location: 1)])
            layer.fill(smoothLoop(points),
                       with: .radialGradient(rim, center: c, startRadius: 0, endRadius: radius * 1.25))
        }
        let core = side * 0.05 * (1 + level)
        ctx.fill(circle(c, core), with: .radialGradient(Gradient(colors: [cream.opacity(0.9), cream.opacity(0)]),
                                                         center: c, startRadius: 0, endRadius: core))
    }

    // MARK: - Outils

    /// Énergie moyenne des graves, des médiums et des aigus (bandes 0-10, 11-21, 22-31).
    private static func registerEnergy(_ bands: [Float]) -> [CGFloat] {
        [0..<11, 11..<22, 22..<32].map { range in
            CGFloat(range.reduce(Float(0)) { $0 + bands[$1] } / Float(range.count))
        }
    }

    private static func circle(_ c: CGPoint, _ r: CGFloat) -> Path {
        Path(ellipseIn: square(c, r))
    }

    private static func square(_ c: CGPoint, _ r: CGFloat) -> CGRect {
        CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)
    }

    private static func polar(_ c: CGPoint, _ angle: Double, _ distance: CGFloat) -> CGPoint {
        CGPoint(x: c.x + CGFloat(cos(angle)) * distance, y: c.y + CGFloat(sin(angle)) * distance)
    }

    private static func aspectFill(_ image: CGSize, in rect: CGRect) -> CGRect {
        guard image.width > 0, image.height > 0 else { return rect }
        let scale = max(rect.width / image.width, rect.height / image.height)
        let size = CGSize(width: image.width * scale, height: image.height * scale)
        return CGRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2, width: size.width, height: size.height)
    }

    private static func drawPhoto(_ ctx: inout GraphicsContext, _ image: UIImage?, clip: Path, frame: CGRect) {
        guard let image else {
            ctx.fill(clip, with: .color(fir))
            return
        }
        var inner = ctx
        inner.clip(to: clip)
        inner.draw(Image(uiImage: image), in: aspectFill(image.size, in: frame))
    }

    /// Courbe lisse passant au milieu de chaque segment (quadratiques).
    private static func smooth(_ points: [CGPoint]) -> Path {
        var path = Path()
        guard points.count > 2 else {
            path.addLines(points)
            return path
        }
        func mid(_ a: CGPoint, _ b: CGPoint) -> CGPoint { CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2) }
        path.move(to: points[0])
        for i in 1..<(points.count - 1) {
            path.addQuadCurve(to: mid(points[i], points[i + 1]), control: points[i])
        }
        path.addLine(to: points[points.count - 1])
        return path
    }

    /// Contour fermé lisse passant au milieu de chaque segment.
    private static func smoothLoop(_ points: [CGPoint]) -> Path {
        var path = Path()
        guard points.count > 2 else {
            path.addLines(points)
            return path
        }
        func mid(_ a: CGPoint, _ b: CGPoint) -> CGPoint { CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2) }
        path.move(to: mid(points[points.count - 1], points[0]))
        for i in points.indices {
            path.addQuadCurve(to: mid(points[i], points[(i + 1) % points.count]), control: points[i])
        }
        path.closeSubpath()
        return path
    }

    /// Bords gauche et droit fondus dans la nuit.
    private static func fadeEdges(_ ctx: inout GraphicsContext, _ size: CGSize) {
        let band = size.width * 0.16
        let night = Palette.night
        ctx.fill(Path(CGRect(x: 0, y: 0, width: band, height: size.height)),
                 with: .linearGradient(Gradient(colors: [night.opacity(0.85), night.opacity(0)]),
                                       startPoint: .zero, endPoint: CGPoint(x: band, y: 0)))
        ctx.fill(Path(CGRect(x: size.width - band, y: 0, width: band, height: size.height)),
                 with: .linearGradient(Gradient(colors: [night.opacity(0), night.opacity(0.85)]),
                                       startPoint: CGPoint(x: size.width - band, y: 0),
                                       endPoint: CGPoint(x: size.width, y: 0)))
    }
}
