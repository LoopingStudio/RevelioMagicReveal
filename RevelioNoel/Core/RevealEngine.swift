import CoreGraphics
import Foundation
import Observation
import simd

enum RevealPhase: Equatable, Sendable {
    /// La photo est (au moins en partie) couverte, les gestes agissent.
    case covered
    /// Auto-fin déclenchée : le reste se dissout.
    case finishing
    /// Tout est révélé.
    case revealed
}

/// Ce qui vient d'être érodé, transmis aux recettes de particules et au papier.
struct ErosionEvent: Sendable {
    enum Source: Sendable { case scratch, blow, shake, finish }

    var source: Source
    var cells: [ErodedCell]
    var cardSize: CGSize
    /// Repère écran, en points/s : vitesse du doigt (gratter), (0, −1) (souffler), direction du coup (secouer).
    var direction: SIMD2<Float>
    /// 0…1 : intensité du souffle ou de la secousse, vitesse normalisée du doigt.
    var intensity: Float

    var totalAmount: Float { cells.reduce(0) { $0 + $1.amount } }

    /// Position d'une cellule en points, dans le repère de la carte.
    func point(_ cell: ErodedCell) -> SIMD2<Float> {
        SIMD2(cell.position.x * Float(cardSize.width), cell.position.y * Float(cardSize.height))
    }
}

/// Le cœur du banc d'essai : carte de couverture, gestes, particules, auto-fin.
@Observable
final class RevealEngine {
    static let fieldColumns = 90
    static let cardAspect: Float = 3.0 / 4.0
    static let particleMargin: CGFloat = 420

    var mask: MaskKind { didSet { if mask != oldValue { reset() } } }
    var gesture: RevealGesture { didSet { if gesture != oldValue { reset() } } }

    /// Compteur d'images : les vues de rendu le lisent pour se redessiner à chaque tick.
    private(set) var frame: UInt64 = 0
    private(set) var phase: RevealPhase = .covered
    private(set) var revealed: Float = 0

    // Lectures du mode debug.
    private(set) var blowLevelDB: Float = -120
    private(set) var blowStrength: Float = 0
    private(set) var lastShakeStrength: Float = 0

    @ObservationIgnored private(set) var field: CoverageField
    @ObservationIgnored private(set) var particles = ParticleSystem()
    @ObservationIgnored private(set) var paper: PaperSheet
    @ObservationIgnored private(set) var time: Float = 0
    @ObservationIgnored var cardSize: CGSize = CGSize(width: 300, height: 400)
    /// Gravité réelle dans le repère de l'écran (norme ≈ 1).
    @ObservationIgnored var gravity: SIMD2<Float> = SIMD2(0, 1)

    @ObservationIgnored let settings: RevealSettings
    @ObservationIgnored let feedback: FeedbackCenter

    @ObservationIgnored private var seed: UInt32 = 1
    @ObservationIgnored private var rng = SeededRandom(seed: 1)
    @ObservationIgnored private var blowMap: ThresholdMap
    @ObservationIgnored private var shakeMap: ThresholdMap
    @ObservationIgnored private var blowProgress: Float = 0
    @ObservationIgnored private var shakeProgress: Float = 0
    @ObservationIgnored private var shakeTarget: Float = 0
    @ObservationIgnored private var lastShakeDirection = SIMD2<Float>(0, 1)
    @ObservationIgnored private var blowAnalyzer: BlowAnalyzer
    @ObservationIgnored private var lastScratch: (point: SIMD2<Float>, time: TimeInterval)?
    @ObservationIgnored private var scratchSpeed: Float = 0
    @ObservationIgnored private var finishElapsed: Float = 0
    @ObservationIgnored private var pendingEvents: [ErosionEvent] = []
    @ObservationIgnored private var demo: DemoPlayer?
    /// Souffle simulé (bouton debug) : remplace le micro tant qu'il est > 0.
    @ObservationIgnored var simulatedBlow: Float = 0

    init(settings: RevealSettings, feedback: FeedbackCenter, mask: MaskKind = .snow, gesture: RevealGesture = .scratch) {
        self.settings = settings
        self.feedback = feedback
        self.mask = mask
        self.gesture = gesture
        let field = CoverageField(columns: Self.fieldColumns, aspect: Self.cardAspect)
        self.field = field
        blowMap = .blowFront(cols: field.cols, rows: field.rows, aspect: field.aspect, seed: 1)
        shakeMap = .shakeChunks(cols: field.cols, rows: field.rows, aspect: field.aspect, seed: 1)
        paper = PaperSheet(aspect: field.aspect, seed: 1)
        blowAnalyzer = BlowAnalyzer(thresholdDB: Float(settings.blowThresholdDB))
    }

    // MARK: - Session

    func reset() {
        seed &+= 1
        rng = SeededRandom(seed: seed)
        field.reset()
        blowMap = .blowFront(cols: field.cols, rows: field.rows, aspect: field.aspect, seed: seed)
        shakeMap = .shakeChunks(cols: field.cols, rows: field.rows, aspect: field.aspect, seed: seed)
        // La découpe du papier coûte cher : on ne la refait que si ce masque est affiché
        // (passer au papier déclenche un reset, donc une découpe neuve).
        if mask == .paper { paper = PaperSheet(aspect: field.aspect, seed: seed) }
        blowProgress = 0
        shakeProgress = 0
        shakeTarget = 0
        lastScratch = nil
        finishElapsed = 0
        pendingEvents.removeAll()
        particles.removeAll()
        blowAnalyzer.reset()
        phase = .covered
        revealed = 0
        feedback.reset()
        frame &+= 1
    }

    /// Termine tout de suite (bouton « Révéler » du mode debug).
    func revealAll() {
        guard phase == .covered else { return }
        startFinishing()
    }

    // MARK: - Gestes

    func scratch(at location: CGPoint, time timestamp: TimeInterval) {
        guard gesture == .scratch, phase == .covered, cardSize.width > 0 else { return }
        let p = SIMD2(Float(location.x / cardSize.width), Float(location.y / cardSize.height))
        let radius = Float(settings.brushRadius / cardSize.width)
        let strength = Float(settings.scratchStrength)
        var velocity = SIMD2<Float>.zero
        let cells: [ErodedCell]
        if let last = lastScratch {
            let dt = Float(max(timestamp - last.time, 1.0 / 240))
            velocity = (p - last.point) * SIMD2(Float(cardSize.width), Float(cardSize.height)) / dt
            cells = field.erodeStroke(from: last.point, to: p, radius: radius, strength: strength)
        } else {
            cells = field.erodeDisc(center: p, radius: radius, strength: strength)
            feedback.scratchBegan(mask: mask)
        }
        lastScratch = (p, timestamp)
        let speed = simd_length(velocity)
        scratchSpeed = scratchSpeed * 0.6 + speed * 0.4
        let intensity = min(1, scratchSpeed / 1500)
        feedback.scratchMoved(speed: intensity, erodedAmount: cells.reduce(0) { $0 + $1.amount }, mask: mask)
        guard !cells.isEmpty else { return }
        pendingEvents.append(ErosionEvent(source: .scratch, cells: cells, cardSize: cardSize, direction: velocity, intensity: intensity))
    }

    func endScratch() {
        guard lastScratch != nil else { return }
        lastScratch = nil
        scratchSpeed = 0
        feedback.scratchEnded()
    }

    /// Niveau micro brut, appelé ~50 fois par seconde par le moniteur micro.
    func microphoneLevel(_ db: Float, dt: Float) {
        blowLevelDB = db
        blowAnalyzer.thresholdDB = Float(settings.blowThresholdDB)
        let strength = blowAnalyzer.process(levelDB: db, dt: dt)
        if strength != blowStrength { blowStrength = strength }
    }

    func shakeImpulse(_ impulse: ShakeImpulse) {
        lastShakeStrength = impulse.strength
        guard gesture == .shake, phase == .covered else { return }
        lastShakeDirection = impulse.direction
        // Une secousse franche fait tomber 3 à 4 morceaux sur 26.
        shakeTarget = min(shakeMap.completionProgress, shakeTarget + impulse.strength * 0.16 * Float(settings.shakeSpeed))
        feedback.shake(strength: impulse.strength, mask: mask)
    }

    /// Vrai quand quelque chose bouge vite (doigt posé, souffle, chute, particules, auto-fin) :
    /// l'écran tourne alors à 120 Hz, sinon il ralentit pour épargner le processeur et la batterie.
    var needsFullFrameRate: Bool {
        !particles.isEmpty
            || phase == .finishing
            || lastScratch != nil
            || blowStrength > 0 || simulatedBlow > 0
            || shakeProgress < shakeTarget
            || (demo.map { !$0.finished } ?? false)
            || (mask == .paper && !paper.falling.isEmpty)
    }

    // MARK: - Tick

    func tick(dt rawDt: Float) {
        let dt = min(max(rawDt, 0), 1.0 / 20)
        time += dt
        demo?.advance(dt: dt, engine: self)

        if phase == .covered {
            stepBlow(dt: dt)
            stepShake(dt: dt)
        } else if phase == .finishing {
            stepFinishing(dt: dt)
        }

        let events = pendingEvents
        pendingEvents.removeAll(keepingCapacity: true)
        let recipe = mask.recipe
        for event in events {
            particles.emit(contentsOf: recipe.particles(for: event, rng: &rng))
        }
        if mask == .paper {
            let scraps = paper.step(dt: dt, field: field, events: events, gravity: gravity, cardSize: cardSize, rng: &rng)
            particles.emit(contentsOf: scraps)
        }

        let margin = Self.particleMargin
        particles.step(dt: dt, gravity: gravity, time: time,
                       bounds: CGRect(origin: .zero, size: cardSize).insetBy(dx: -margin, dy: -margin))

        // Les vues observent `revealed` : on n'écrit que si la valeur change.
        let nowRevealed = mask == .paper ? paper.revealedFraction : field.revealedFraction
        if nowRevealed != revealed { revealed = nowRevealed }
        if phase == .covered, settings.autoFinishThreshold < 1, revealed >= Float(settings.autoFinishThreshold) {
            startFinishing()
        }
        frame &+= 1
    }

    private func stepBlow(dt: Float) {
        let strength = simulatedBlow > 0 ? simulatedBlow : blowStrength
        if simulatedBlow > 0, blowStrength != simulatedBlow { blowStrength = simulatedBlow }
        guard gesture == .blow else { return }
        feedback.blow(strength: strength, mask: mask)
        guard strength > 0 else { return }
        // Souffle maximal à vitesse 1 : tout est révélé en ~3 s.
        blowProgress = min(blowMap.completionProgress, blowProgress + strength * Float(settings.blowSpeed) * 0.36 * dt)
        let cells = field.apply(blowMap, progress: blowProgress)
        guard !cells.isEmpty else { return }
        pendingEvents.append(ErosionEvent(source: .blow, cells: cells, cardSize: cardSize, direction: SIMD2(0, -1), intensity: strength))
    }

    private func stepShake(dt: Float) {
        guard shakeProgress < shakeTarget else { return }
        // La progression rattrape la cible en ~0,2 s : chaque morceau tombe en quelques images.
        shakeProgress = min(shakeTarget, shakeProgress + max(dt * 0.8, (shakeTarget - shakeProgress) * min(1, dt * 12)))
        let cells = field.apply(shakeMap, progress: shakeProgress)
        guard !cells.isEmpty else { return }
        let amount = cells.reduce(0) { $0 + $1.amount }
        feedback.chunk(amount: amount, mask: mask)
        pendingEvents.append(ErosionEvent(source: .shake, cells: cells, cardSize: cardSize,
                                          direction: lastShakeDirection, intensity: lastShakeStrength))
    }

    private func startFinishing() {
        phase = .finishing
        finishElapsed = 0
        lastScratch = nil
        feedback.scratchEnded()
        if mask == .paper { paper.detachAll(rng: &rng) }
    }

    private func stepFinishing(dt: Float) {
        finishElapsed += dt
        let cells = field.dissolve(by: dt * 3.2)
        if !cells.isEmpty {
            pendingEvents.append(ErosionEvent(source: .finish, cells: cells, cardSize: cardSize, direction: .zero, intensity: 1))
        }
        if finishElapsed >= 0.8, field.revealedFraction >= 0.999 {
            field.clear()
            phase = .revealed
            particles.emit(contentsOf: CelebrationRecipe.burst(cardSize: cardSize, rng: &rng))
            feedback.revealCompleted(mask: mask)
        }
    }

    // MARK: - Démo (arguments de lancement)

    func startDemo(_ script: DemoScript) {
        demo = DemoPlayer(script: script)
    }

    /// Accès de la démo : souffle simulé et traits scriptés passent par les mêmes chemins que les vrais gestes.
    fileprivate func demoScratch(to normalized: SIMD2<Float>, at timestamp: TimeInterval) {
        scratch(at: CGPoint(x: CGFloat(normalized.x) * cardSize.width, y: CGFloat(normalized.y) * cardSize.height), time: timestamp)
    }
}

// MARK: - Démo

/// Script de démo lu dans les arguments de lancement, pour vérifier le rendu sans geste réel.
struct DemoScript: Equatable, Sendable {
    enum Kind: String, Sendable { case partial, finish }
    var kind: Kind
    /// Facteur de vitesse du script.
    var speed: Float = 1
}

private struct DemoPlayer {
    let script: DemoScript
    var elapsed: Float = 0
    var finished = false
    var nextShake: Float = 0.25

    mutating func advance(dt: Float, engine: RevealEngine) {
        guard !finished else { return }
        elapsed += dt * script.speed
        let duration: Float = 1.6
        switch engine.gesture {
        case .scratch:
            if elapsed <= duration {
                // Un « S » qui traverse la carte.
                let t = elapsed / duration
                let x = 0.2 + 0.6 * (0.5 + 0.5 * sin(t * .pi * 3))
                let y = 0.12 + 0.76 * t
                engine.demoScratch(to: SIMD2(x, y), at: TimeInterval(elapsed))
            } else {
                engine.endScratch()
            }
        case .blow:
            engine.simulatedBlow = elapsed <= duration ? 0.85 : 0
        case .shake:
            if elapsed >= nextShake, elapsed <= duration {
                engine.shakeImpulse(ShakeImpulse(strength: 0.9, direction: SIMD2(elapsed.truncatingRemainder(dividingBy: 0.5) < 0.25 ? 1 : -1, 0.3)))
                nextShake += 0.45
            }
        }
        if elapsed > duration {
            finished = true
            engine.simulatedBlow = 0
            if script.kind == .finish { engine.revealAll() }
        }
    }
}
