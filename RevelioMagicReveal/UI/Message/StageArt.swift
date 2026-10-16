import SwiftUI

/// Ce qu'une scène lit pour dessiner une image : l'analyse, le son brut, l'instant de lecture.
struct StageInput {
    let analysis: AudioMessageAnalysis
    let message: AudioMessage
    let time: Double
    let photo: MessagePhoto?
    let spectrogram: CGImage?
}

/// Le dessin des visualisations du message. Chacune est une fonction de l'instant de lecture, sans
/// état : on peut scrubber, revenir en arrière, la même seconde donne la même image.
enum StageArt {
    static func draw(_ kind: AudioMessageModel.Visualization, in context: inout GraphicsContext, size: CGSize,
                     input: StageInput) {
        switch kind {
        case .halo: halo(&context, size, input)
        case .ring: ring(&context, size, input)
        case .equalizer: equalizer(&context, size, input)
        case .scope: scope(&context, size, input)
        case .scroll: scroll(&context, size, input)
        case .spectrogram: spectrogram(&context, size, input)
        case .orb: orb(&context, size, input)
        case .garland: garland(&context, size, input)
        case .particles: particles(&context, size, input)
        case .reveal: reveal(&context, size, input)
        }
    }

    private static let gold = Palette.gold
    private static let cream = Palette.cream
    private static let berry = Palette.berry
    private static let fir = Palette.fir

    // MARK: - Halo

    /// La photo en médaillon, des anneaux qui respirent avec la voix et une onde par syllabe.
    private static func halo(_ ctx: inout GraphicsContext, _ size: CGSize, _ s: StageInput) {
        let c = CGPoint(x: size.width / 2, y: size.height / 2)
        let side = min(size.width, size.height)
        let level = CGFloat(s.analysis.level(at: s.time))
        let r = side * 0.22
        let glow = r * (1.3 + level)
        ctx.fill(circle(c, glow), with: .radialGradient(Gradient(colors: [gold.opacity(0.15 + 0.5 * level), gold.opacity(0)]),
                                                         center: c, startRadius: r * 0.9, endRadius: glow))
        for onset in s.analysis.onsets(in: (s.time - 1.4)...s.time) {
            let age = CGFloat((s.time - onset.time) / 1.4)
            ctx.stroke(circle(c, r * (1.05 + 1.25 * age)),
                       with: .color(cream.opacity((1 - age) * 0.55 * CGFloat(onset.strength))),
                       lineWidth: 1.5 + 3 * (1 - age))
        }
        for k in 0..<3 {
            let kk = CGFloat(k)
            ctx.stroke(circle(c, r * (1.1 + 0.17 * kk + 0.12 * (kk + 1) * level)),
                       with: .color(gold.opacity(0.55 - 0.15 * kk)), lineWidth: 2)
        }
        drawPhoto(&ctx, s.photo?.photo, clip: circle(c, r), frame: square(c, r))
        ctx.stroke(circle(c, r), with: .color(gold), lineWidth: 3)
    }

    // MARK: - Couronne

    /// Les fréquences en rayons autour de la photo : graves en haut, aigus en bas, symétrique.
    private static func ring(_ ctx: inout GraphicsContext, _ size: CGSize, _ s: StageInput) {
        let c = CGPoint(x: size.width / 2, y: size.height / 2)
        let side = min(size.width, size.height)
        let r = side * 0.17
        let inner = r * 1.28
        let maxLength = side * 0.2
        let bands = s.analysis.spectrum(at: s.time)
        let count = AudioMessageAnalysis.bandCount * 2
        var rays = Path()
        for i in 0..<count {
            let band = i < count / 2 ? i : count - 1 - i
            let fraction = (Double(i) + 0.5) / Double(count)
            let angle: Double = fraction * 2 * Double.pi - Double.pi / 2
            let length = 3 + CGFloat(bands[band]) * maxLength
            rays.move(to: polar(c, angle, inner))
            rays.addLine(to: polar(c, angle, inner + length))
        }
        var glow = ctx
        glow.blendMode = .plusLighter
        glow.opacity = 0.3
        glow.stroke(rays, with: .color(gold), style: StrokeStyle(lineWidth: 8, lineCap: .round))
        ctx.stroke(rays, with: .radialGradient(Gradient(colors: [gold, cream]), center: c, startRadius: inner,
                                               endRadius: inner + maxLength),
                   style: StrokeStyle(lineWidth: 3.5, lineCap: .round))
        let level = CGFloat(s.analysis.level(at: s.time))
        let photoRadius = r * (1 + 0.05 * level)
        drawPhoto(&ctx, s.photo?.photo, clip: circle(c, photoRadius), frame: square(c, photoRadius))
        ctx.stroke(circle(c, photoRadius), with: .color(gold), lineWidth: 2)
    }

    // MARK: - Égaliseur

    /// 32 barres de fréquences, des crêtes qui retombent doucement, un reflet sous la ligne.
    private static func equalizer(_ ctx: inout GraphicsContext, _ size: CGSize, _ s: StageInput) {
        let bands = s.analysis.spectrum(at: s.time)
        let peaks = s.analysis.peaks(at: s.time)
        let count = AudioMessageAnalysis.bandCount
        let inset: CGFloat = 22
        let slot = (size.width - 2 * inset) / CGFloat(count)
        let width = slot * 0.66
        let base = size.height * 0.7
        let maxHeight = size.height * 0.56
        let corner = CGSize(width: width / 2, height: width / 2)
        var bars = Path(), reflection = Path(), caps = Path()
        for b in 0..<count {
            let x = inset + slot * CGFloat(b) + (slot - width) / 2
            let height = 3 + CGFloat(bands[b]) * maxHeight
            bars.addRoundedRect(in: CGRect(x: x, y: base - height, width: width, height: height), cornerSize: corner)
            reflection.addRoundedRect(in: CGRect(x: x, y: base + 5, width: width, height: height * 0.35), cornerSize: corner)
            let capY = base - 8 - CGFloat(peaks[b]) * maxHeight
            caps.addRoundedRect(in: CGRect(x: x, y: capY, width: width, height: 2.5), cornerSize: CGSize(width: 1.2, height: 1.2))
        }
        let gradient = Gradient(stops: [.init(color: cream, location: 0), .init(color: gold, location: 0.45),
                                        .init(color: berry, location: 1)])
        ctx.fill(bars, with: .linearGradient(gradient, startPoint: CGPoint(x: 0, y: base - maxHeight),
                                             endPoint: CGPoint(x: 0, y: base)))
        var mirror = ctx
        mirror.opacity = 0.2
        mirror.fill(reflection, with: .linearGradient(Gradient(colors: [gold, gold.opacity(0)]),
                                                      startPoint: CGPoint(x: 0, y: base),
                                                      endPoint: CGPoint(x: 0, y: base + maxHeight * 0.35)))
        ctx.fill(caps, with: .color(cream.opacity(0.9)))
    }

    // MARK: - Oscilloscope

    /// La forme d'onde elle-même sur ~45 ms, calée sur un passage par zéro, en trait lumineux.
    private static func scope(_ ctx: inout GraphicsContext, _ size: CGSize, _ s: StageInput) {
        var grid = Path()
        for k in 1..<8 {
            let x = size.width * CGFloat(k) / 8
            grid.move(to: CGPoint(x: x, y: 18))
            grid.addLine(to: CGPoint(x: x, y: size.height - 18))
        }
        grid.move(to: CGPoint(x: 16, y: size.height / 2))
        grid.addLine(to: CGPoint(x: size.width - 16, y: size.height / 2))
        ctx.stroke(grid, with: .color(cream.opacity(0.07)), lineWidth: 1)

        let values = s.message.scope(at: s.time, span: 0.045, points: 220)
        let amplitude = size.height * 0.34 / CGFloat(max(s.analysis.peak, 0.05))
        let limit = size.height * 0.42
        let points = values.enumerated().map { index, value in
            CGPoint(x: 16 + CGFloat(index) / CGFloat(values.count - 1) * (size.width - 32),
                    y: size.height / 2 - min(max(CGFloat(value) * amplitude, -limit), limit))
        }
        let trace = smooth(points, closed: false)
        var glow = ctx
        glow.blendMode = .plusLighter
        glow.stroke(trace, with: .color(gold.opacity(0.18)), style: StrokeStyle(lineWidth: 10, lineCap: .round, lineJoin: .round))
        glow.stroke(trace, with: .color(gold.opacity(0.45)), style: StrokeStyle(lineWidth: 4.5, lineCap: .round, lineJoin: .round))
        ctx.stroke(trace, with: .color(cream), style: StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round))
    }

    // MARK: - Onde défilante

    /// Façon dictaphone : l'onde symétrique défile, la tête de lecture reste au centre.
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
            let height = 2 + CGFloat(peak) * size.height * 0.34
            let bar = CGRect(x: x - width / 2, y: mid - height, width: width, height: height * 2)
            if t <= s.time {
                past.addRoundedRect(in: bar, cornerSize: corner)
            } else {
                future.addRoundedRect(in: bar, cornerSize: corner)
            }
        }
        ctx.fill(past, with: .color(gold))
        ctx.fill(future, with: .color(cream.opacity(0.3)))
        var head = Path()
        head.move(to: CGPoint(x: centerX, y: 20))
        head.addLine(to: CGPoint(x: centerX, y: size.height - 20))
        ctx.stroke(head, with: .color(cream), lineWidth: 2)
        ctx.fill(circle(CGPoint(x: centerX, y: 20), 4.5), with: .color(cream))
        fadeEdges(&ctx, size)
    }

    // MARK: - Spectrogramme

    /// Le temps de gauche à droite, les fréquences de bas en haut, l'intensité en couleur ; l'image
    /// précalculée défile sous la tête de lecture.
    private static func spectrogram(_ ctx: inout GraphicsContext, _ size: CGSize, _ s: StageInput) {
        guard let image = s.spectrogram else { return }
        let perSecond = size.width / 6
        let headX = size.width * 0.7
        let top: CGFloat = 22, height = size.height - 44
        ctx.draw(Image(decorative: image, scale: 1).interpolation(.high),
                 in: CGRect(x: headX - CGFloat(s.time) * perSecond, y: top,
                            width: CGFloat(s.analysis.duration) * perSecond, height: height))
        ctx.fill(Path(CGRect(x: headX, y: top, width: size.width - headX, height: height)),
                 with: .color(Palette.night.opacity(0.5)))
        var head = Path()
        head.move(to: CGPoint(x: headX, y: top - 6))
        head.addLine(to: CGPoint(x: headX, y: top + height + 6))
        ctx.stroke(head, with: .color(cream), lineWidth: 2)
        let label = { (text: String) in Text(text).font(.caption2.weight(.semibold)).foregroundStyle(cream.opacity(0.55)) }
        ctx.draw(label("8 kHz"), at: CGPoint(x: 12, y: top + 4), anchor: .topLeading)
        ctx.draw(label("100 Hz"), at: CGPoint(x: 12, y: top + height - 4), anchor: .bottomLeading)
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
            layer.fill(smooth(points, closed: true),
                       with: .radialGradient(rim, center: c, startRadius: 0, endRadius: radius * 1.25))
        }
        let core = side * 0.05 * (1 + level)
        ctx.fill(circle(c, core), with: .radialGradient(Gradient(colors: [cream.opacity(0.9), cream.opacity(0)]),
                                                         center: c, startRadius: 0, endRadius: core))
    }

    // MARK: - Guirlande

    /// Deux guirlandes de 16 ampoules : chacune s'allume avec sa bande de fréquences.
    private static func garland(_ ctx: inout GraphicsContext, _ size: CGSize, _ s: StageInput) {
        let bands = s.analysis.spectrum(at: s.time)
        let colors = [Color(red: 1, green: 0.32, blue: 0.3), Color(red: 1, green: 0.8, blue: 0.36),
                      Color(red: 0.42, green: 0.92, blue: 0.56), Color(red: 0.52, green: 0.73, blue: 1)]
        let perStrand = AudioMessageAnalysis.bandCount / 2
        var glow = ctx
        glow.blendMode = .plusLighter
        for strand in 0..<2 {
            let y0 = size.height * (strand == 0 ? 0.18 : 0.5)
            let sag = size.height * 0.17
            let wireY = { (x: CGFloat) -> CGFloat in
                let u = (x - size.width / 2) / (size.width / 2 + 12)
                return y0 + sag * (1 - u * u)
            }
            var wire = Path()
            wire.move(to: CGPoint(x: -12, y: wireY(-12)))
            for k in 1...24 {
                let x = -12 + (size.width + 24) * CGFloat(k) / 24
                wire.addLine(to: CGPoint(x: x, y: wireY(x)))
            }
            ctx.stroke(wire, with: .color(Color(red: 0.1, green: 0.24, blue: 0.17)), lineWidth: 2.2)
            for i in 0..<perStrand {
                let value = CGFloat(bands[i * 2 + strand])
                let x = (CGFloat(i) + 0.5) / CGFloat(perStrand) * size.width
                let top = wireY(x)
                let bulbCenter = CGPoint(x: x, y: top + 12)
                let color = colors[(i + strand * 2) % colors.count]
                let halo = 8 + 30 * value
                glow.fill(circle(bulbCenter, halo),
                          with: .radialGradient(Gradient(colors: [color.opacity(0.15 + 0.7 * value), color.opacity(0)]),
                                                center: bulbCenter, startRadius: 0, endRadius: halo))
                ctx.fill(Path(roundedRect: CGRect(x: x - 3, y: top, width: 6, height: 5), cornerRadius: 1.5), with: .color(fir))
                ctx.fill(Path(ellipseIn: CGRect(x: x - 5, y: top + 4, width: 10, height: 15)),
                         with: .color(color.opacity(0.3 + 0.7 * value)))
                ctx.fill(circle(CGPoint(x: x - 1.8, y: top + 9), 1.6), with: .color(.white.opacity(0.3 + 0.6 * value)))
            }
        }
    }

    // MARK: - Flocons

    /// La neige tombe plus vite quand la voix porte ; chaque syllabe lance une gerbe de paillettes dorées.
    private static func particles(_ ctx: inout GraphicsContext, _ size: CGSize, _ s: StageInput) {
        let level = CGFloat(s.analysis.level(at: s.time))
        let fall = 0.035 * s.time + 0.6 * Double(s.analysis.cumulative(at: s.time))
        ctx.fill(Path(CGRect(x: 0, y: size.height * 0.55, width: size.width, height: size.height * 0.45)),
                 with: .linearGradient(Gradient(colors: [gold.opacity(0), gold.opacity(0.08 + 0.3 * level)]),
                                       startPoint: CGPoint(x: 0, y: size.height * 0.55),
                                       endPoint: CGPoint(x: 0, y: size.height)))
        var flakes = Path()
        for i in 0..<90 {
            let speed = 0.6 + 0.8 * Double(noise(i, 2))
            let y = (Double(noise(i, 1)) + fall * speed).truncatingRemainder(dividingBy: 1.1) - 0.05
            let x = noise(i, 3) * size.width + CGFloat(sin(s.time * 0.9 * speed + Double(noise(i, 4)) * 6.28)) * 10
            let r = 1.2 + 2.6 * noise(i, 5)
            flakes.addEllipse(in: CGRect(x: x - r, y: CGFloat(y) * size.height - r, width: 2 * r, height: 2 * r))
        }
        ctx.fill(flakes, with: .color(cream.opacity(0.55 + 0.4 * level)))

        var glow = ctx
        glow.blendMode = .plusLighter
        for onset in s.analysis.onsets(in: (s.time - 1.6)...s.time) {
            let age = s.time - onset.time
            let seed = Int(onset.time * 1000)
            let origin = CGPoint(x: size.width * (0.25 + 0.5 * noise(seed, 7)), y: size.height * (0.3 + 0.3 * noise(seed, 8)))
            let fade = pow(1 - age / 1.6, 1.5)
            let strength = Double(onset.strength)
            for k in 0..<16 {
                let angle = Double(noise(seed + k, 9)) * 2 * .pi
                let speed = (70 + 170 * Double(noise(seed + k, 10))) * (0.6 + strength)
                let p = CGPoint(x: origin.x + CGFloat(cos(angle) * speed * age),
                                y: origin.y + CGFloat(sin(angle) * speed * age + 90 * age * age))
                let radius = (2.5 + 4 * noise(seed + k, 11)) * CGFloat(0.6 + 0.4 * strength)
                glow.fill(circle(p, radius * 2.6),
                          with: .radialGradient(Gradient(colors: [gold.opacity(0.5 * fade), gold.opacity(0)]),
                                                center: p, startRadius: 0, endRadius: radius * 2.6))
                ctx.fill(star(p, radius), with: .color(cream.opacity(fade)))
            }
        }
    }

    // MARK: - La voix révèle la photo

    /// Le givre fond depuis le centre à mesure que le message avance : l'énergie de la voix dit jusqu'où.
    private static func reveal(_ ctx: inout GraphicsContext, _ size: CGSize, _ s: StageInput) {
        guard let photo = s.photo else { return }
        let frame = CGRect(origin: .zero, size: size)
        let imageRect = aspectFill(photo.photo.size, in: frame)
        ctx.draw(Image(uiImage: photo.photo), in: imageRect)
        let progress = CGFloat(min(s.analysis.cumulative(at: s.time) / max(s.analysis.totalEnergy, 0.001), 1))
        let level = CGFloat(s.analysis.level(at: s.time))
        let c = CGPoint(x: size.width / 2, y: size.height / 2)
        let radius = progress * hypot(size.width, size.height) / 2 * 1.4 + (progress > 0 ? level * 16 : 0)
        ctx.drawLayer { layer in
            layer.draw(Image(uiImage: photo.frosted), in: imageRect)
            layer.fill(Path(frame), with: .color(.white.opacity(0.22)))
            guard radius > 1 else { return }
            layer.blendMode = .destinationOut
            layer.fill(circle(c, radius), with: .radialGradient(
                Gradient(stops: [.init(color: .black, location: 0), .init(color: .black, location: 0.7),
                                 .init(color: .black.opacity(0), location: 1)]),
                center: c, startRadius: 0, endRadius: radius))
        }
        if radius > 1, progress < 1 {
            ctx.stroke(circle(c, radius * 0.85), with: .color(cream.opacity(0.15 + 0.35 * level)), lineWidth: 1.5)
        }
    }

    // MARK: - Outils

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

    /// Courbe lisse passant au milieu de chaque segment (quadratiques), ouverte ou fermée.
    private static func smooth(_ points: [CGPoint], closed: Bool) -> Path {
        var path = Path()
        guard points.count > 2 else {
            path.addLines(points)
            return path
        }
        func mid(_ a: CGPoint, _ b: CGPoint) -> CGPoint { CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2) }
        if closed {
            path.move(to: mid(points[points.count - 1], points[0]))
            for i in points.indices {
                path.addQuadCurve(to: mid(points[i], points[(i + 1) % points.count]), control: points[i])
            }
            path.closeSubpath()
        } else {
            path.move(to: points[0])
            for i in 1..<(points.count - 1) {
                path.addQuadCurve(to: mid(points[i], points[i + 1]), control: points[i])
            }
            path.addLine(to: points[points.count - 1])
        }
        return path
    }

    /// Étoile à quatre branches.
    private static func star(_ c: CGPoint, _ r: CGFloat) -> Path {
        var path = Path()
        for k in 0..<8 {
            let angle = Double(k) * .pi / 4 - .pi / 2
            let point = polar(c, angle, k.isMultiple(of: 2) ? r : r * 0.32)
            if k == 0 { path.move(to: point) } else { path.addLine(to: point) }
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

    /// Hasard figé : la même particule tombe toujours au même endroit au même instant.
    private static func noise(_ i: Int, _ salt: Int) -> CGFloat {
        var x = UInt64(bitPattern: Int64(i &* 73_856_093 ^ salt &* 19_349_663))
        x = (x ^ (x >> 30)) &* 0xBF58_476D_1CE4_E5B9
        x = (x ^ (x >> 27)) &* 0x94D0_49BB_1331_11EB
        x ^= x >> 31
        return CGFloat(x % 10_000) / 10_000
    }
}
