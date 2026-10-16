import CoreGraphics
import Foundation
import Observation
import QuartzCore

/// L'écran « Message audio » : le message courant et son analyse, la lecture (avec vibrations calées
/// dessus), l'enregistrement et le scrub.
///
/// La position de lecture n'est jamais une propriété observée : les visuels la calculent à chaque
/// image (`playhead(at:)`), sinon toute la feuille se réévaluerait 120 fois par seconde.
@Observable
final class AudioMessageModel {
    enum Phase: Equatable {
        case empty
        /// Exemple en cours de rendu, micro qui s'ouvre, analyse… (texte affiché sur la scène).
        case preparing(String)
        case recording
        /// Message prêt, à l'arrêt.
        case ready
        case playing
        case failed(String)
    }

    enum Visualization: String, CaseIterable, Identifiable, Sendable {
        case halo, ring, equalizer, scope, scroll, spectrogram, orb, garland, particles, reveal

        var id: Self { self }

        var title: String {
            switch self {
            case .halo: "Halo"
            case .ring: "Couronne"
            case .equalizer: "Égaliseur"
            case .scope: "Oscillo"
            case .scroll: "Défilante"
            case .spectrogram: "Spectro"
            case .orb: "Orbe"
            case .garland: "Guirlande"
            case .particles: "Flocons"
            case .reveal: "Révéler"
            }
        }

        var symbol: String {
            switch self {
            case .halo: "circle.circle"
            case .ring: "rays"
            case .equalizer: "chart.bar.fill"
            case .scope: "waveform.path"
            case .scroll: "waveform"
            case .spectrogram: "square.grid.3x3.fill"
            case .orb: "drop.fill"
            case .garland: "lightbulb.fill"
            case .particles: "snowflake"
            case .reveal: "photo"
            }
        }
    }

    static let overviewBars = 44
    static let liveBars = 72

    private(set) var phase: Phase = .empty
    private(set) var message: AudioMessage?
    private(set) var analysis: AudioMessageAnalysis?
    private(set) var spectrogram: CGImage?
    /// Barres de la forme d'onde du message entier (barre de lecture).
    private(set) var overview: [Float] = []
    /// Niveaux reçus pendant l'enregistrement, les plus récents à la fin.
    private(set) var recordingLevels: [Float] = []
    private(set) var recordingStarted: Date?
    private(set) var isScrubbing = false
    var visualization: Visualization = .halo
    var vibrations: Bool {
        didSet { if vibrations != oldValue { vibrationsChanged() } }
    }

    @ObservationIgnored private let feedback: FeedbackCenter
    @ObservationIgnored private let settings: RevealSettings
    @ObservationIgnored private var player: MessagePlayer!
    @ObservationIgnored private var recorder: VoiceRecorder!
    @ObservationIgnored private var sample: AudioMessage?
    @ObservationIgnored private var hapticScript: [HapticEventSpec] = []
    /// Numéro de la lecture en cours : chaque départ, pause ou scrub l'incrémente, les rappels d'une
    /// lecture dépassée sont ignorés.
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var startTime: CFTimeInterval = 0
    @ObservationIgnored private var startOffset: Double = 0
    /// Position à l'arrêt (pause, scrub, fin).
    @ObservationIgnored private var position: Double = 0
    @ObservationIgnored private var resumeAfterScrub = false
    @ObservationIgnored private var endWatch: Task<Void, Never>?
    @ObservationIgnored private var work: Task<Void, Never>?
    /// Écran affiché et app au premier plan : sans ça, une étape en cours (micro qui s'ouvre, mise en
    /// forme) ne doit ni lancer la lecture ni allumer le micro.
    @ObservationIgnored private var isOpen = false
    @ObservationIgnored private var isActive = true

    init(feedback: FeedbackCenter, settings: RevealSettings) {
        self.feedback = feedback
        self.settings = settings
        vibrations = settings.hapticsEnabled
        player = MessagePlayer { [weak self] generation, reason in
            self?.playerStopped(generation, reason)
        }
        recorder = VoiceRecorder { [weak self] level in
            self?.recorded(level)
        } onLimit: { [weak self] in
            self?.finishRecording()
        }
    }

    var duration: Double { analysis?.duration ?? 0 }
    var isRecording: Bool { phase == .recording }
    var isPlaying: Bool { phase == .playing }
    /// Les visuels bougent : lecture en cours ou doigt sur la barre de lecture.
    var isAnimating: Bool { phase == .playing || isScrubbing }
    var canPlay: Bool {
        guard message != nil else { return false }
        switch phase {
        case .ready, .playing, .failed: return true
        default: return false
        }
    }

    /// Position de lecture à l'instant `now` (horloge `CACurrentMediaTime`, celle de l'audio).
    func playhead(at now: CFTimeInterval = CACurrentMediaTime()) -> Double {
        guard phase == .playing else { return position }
        return min(max(startOffset + max(0, now - startTime), 0), duration)
    }

    // MARK: - Écran

    /// Ouverture : l'exemple se prépare s'il n'y a encore rien à écouter.
    func open(autoplay: Bool = false) {
        isOpen = true
        isActive = true
        if message == nil, phase == .empty { loadSample(autoplay: autoplay) }
    }

    /// Fermeture : plus de son, plus de micro, moteur libéré. Une étape en cours est abandonnée (le
    /// rendu de l'exemple, lui, finit en arrière-plan et reste en cache).
    func close() {
        isOpen = false
        switch phase {
        case .recording, .preparing:
            work?.cancel()
            recorder.cancel()
            recordingStarted = nil
            phase = message == nil ? .empty : .ready
        default:
            break
        }
        pause()
        player.shutdown()
        feedback.endVoiceSession()
    }

    /// L'app quitte le premier plan : l'enregistrement se termine, la lecture se met en pause.
    func suspend() {
        isActive = false
        if phase == .recording { finishRecording() }
        pause()
    }

    func resume() {
        isActive = true
    }

    // MARK: - Sources

    func loadSample(autoplay: Bool = true) {
        guard phase != .recording else { return }
        pause()
        if let sample {
            work = Task { await install(sample, autoplay: autoplay) }
            return
        }
        work?.cancel()
        phase = .preparing("Préparation de l'exemple…")
        work = Task {
            do {
                let rendered = try await SpeechSample.render()
                guard !Task.isCancelled else { return }
                sample = rendered
                await install(rendered, autoplay: autoplay)
            } catch {
                guard !Task.isCancelled else { return }
                phase = .failed(error as? SpeechSample.Failure == .noVoice
                    ? "Aucune voix française sur cet appareil"
                    : "L'exemple n'a pas pu être préparé")
            }
        }
    }

    func toggleRecording() {
        if phase == .recording { finishRecording() } else { startRecording() }
    }

    private func startRecording() {
        pause()
        work?.cancel()
        recordingLevels = []
        phase = .preparing("Ouverture du micro…")
        work = Task {
            guard await MicrophoneMonitor.requestPermission() else {
                phase = .failed("Micro refusé : autorise-le dans Réglages")
                return
            }
            do {
                try await recorder.start(mic: settings.mic)
                guard !Task.isCancelled, isOpen else {
                    recorder.cancel()
                    return
                }
                recordingStarted = .now
                phase = .recording
            } catch {
                phase = .failed("Micro indisponible")
            }
        }
    }

    private func finishRecording() {
        guard phase == .recording else { return }
        recordingStarted = nil
        phase = .preparing("Mise en forme du message…")
        work = Task {
            guard let recorded = await recorder.finish() else {
                phase = .failed("Rien entendu : réessaie plus près du micro")
                return
            }
            await install(recorded, autoplay: true)
        }
    }

    private func recorded(_ level: Float) {
        guard phase == .recording else { return }
        recordingLevels.append(level)
        if recordingLevels.count > Self.liveBars * 2 { recordingLevels.removeFirst(Self.liveBars) }
    }

    /// Analyse (hors fil principal), image du spectrogramme et script de vibrations, puis prêt à lire.
    private func install(_ message: AudioMessage, autoplay: Bool) async {
        pause()
        phase = .preparing("Analyse du message…")
        let (analysis, script) = await Task.detached(priority: .userInitiated) {
            let analysis = AudioMessageAnalysis.analyze(message)
            return (analysis, HapticScripts.voice(analysis))
        }.value
        guard !Task.isCancelled else { return }
        self.message = message
        self.analysis = analysis
        hapticScript = script
        overview = analysis.overview(bars: Self.overviewBars)
        spectrogram = SpectrogramImage.make(analysis)
        position = 0
        player.load(message)
        phase = .ready
        if autoplay, isOpen, isActive { play() }
    }

    // MARK: - Lecture

    func togglePlay() {
        if phase == .playing { pause() } else { play() }
    }

    func play() {
        guard canPlay, phase != .playing, isOpen else { return }
        let offset = position >= duration - 0.05 ? 0 : position
        generation += 1
        let current = generation
        position = offset
        startOffset = offset
        startTime = CACurrentMediaTime() + 0.12
        phase = .playing
        // Motif haptique prêt avant le départ audio, pour démarrer les deux ensemble.
        let haptics = vibrations && feedback.prepareVoiceHaptics(HapticScripts.slice(hapticScript, from: offset))
        Task {
            guard let start = await player.play(from: offset, generation: current) else {
                if current == generation {
                    feedback.stopVoiceHaptics()
                    phase = .ready
                }
                return
            }
            guard current == generation else { return }
            startTime = start
            if haptics { feedback.startVoiceHaptics(atMediaTime: start) }
            watchForEnd(current, at: start + duration - offset)
        }
    }

    func pause() {
        guard phase == .playing else { return }
        position = playhead()
        generation += 1
        player.stop()
        feedback.stopVoiceHaptics()
        endWatch?.cancel()
        phase = .ready
    }

    func beginScrub() {
        guard canPlay, !isScrubbing else { return }
        resumeAfterScrub = phase == .playing
        pause()
        isScrubbing = true
    }

    func scrub(to time: Double) {
        guard isScrubbing else { return }
        position = min(max(time, 0), duration)
    }

    func endScrub(at time: Double) {
        guard isScrubbing else { return }
        position = min(max(time, 0), duration)
        isScrubbing = false
        if resumeAfterScrub { play() }
    }

    private func playerStopped(_ stopped: Int, _ reason: MessagePlayer.StopReason) {
        guard stopped == generation, phase == .playing else { return }
        switch reason {
        case .ended: reachEnd()
        case .interrupted: pause()
        }
    }

    private func reachEnd() {
        generation += 1
        position = duration
        feedback.stopVoiceHaptics()
        endWatch?.cancel()
        phase = .ready
    }

    /// Filet de sécurité si le rappel de fin du lecteur ne venait pas.
    private func watchForEnd(_ current: Int, at end: CFTimeInterval) {
        endWatch?.cancel()
        endWatch = Task {
            try? await Task.sleep(for: .seconds(max(0, end - CACurrentMediaTime()) + 0.35))
            guard !Task.isCancelled, current == generation, phase == .playing else { return }
            reachEnd()
        }
    }

    /// Interrupteur basculé en pleine lecture : les vibrations repartent (ou s'arrêtent) là où en est l'audio.
    private func vibrationsChanged() {
        guard phase == .playing else { return }
        guard vibrations else {
            feedback.stopVoiceHaptics()
            return
        }
        let start = CACurrentMediaTime() + 0.08
        if feedback.prepareVoiceHaptics(HapticScripts.slice(hapticScript, from: playhead(at: start))) {
            feedback.startVoiceHaptics(atMediaTime: start)
        }
    }
}
