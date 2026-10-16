import AVFAudio
import CoreAudioTypes
import Foundation
import QuartzCore
import Synchronization
import os

/// Sons procéduraux : grattement (bruit filtré temps réel), whoosh des morceaux, carillon de fin.
///
/// Façade main actor : les commandes à haute fréquence ne font qu'écrire des atomiques lus par le
/// thread audio ; tout ce qui parle au serveur audio (session, moteur) part sur la file d'`AudioOutput`.
final class ProceduralSound {
    private let parameters = SynthParameters()
    private let output: AudioOutput
    private var wantsRunning = false
    private var lastRestartRequest: CFTimeInterval = -.infinity

    init() {
        output = AudioOutput(parameters: parameters)
    }

    // MARK: - Cycle de vie

    func start() {
        wantsRunning = true
        lastRestartRequest = CACurrentMediaTime()
        output.start()
    }

    /// Coupe le son (réglage désactivé, arrière-plan). Le graphe est gardé pour repartir vite.
    func stop() {
        wantsRunning = false
        parameters.setScratch(gain: 0, brightness: 0.5, timbre: .snow)
        output.stop()
    }

    // MARK: - Commandes (jusqu'à 120 Hz : atomiques uniquement)

    func setScratch(gain: Float, brightness: Float, timbre: FeedbackTimbre) {
        parameters.setScratch(gain: gain, brightness: brightness, timbre: timbre)
        restartIfNeeded()
    }

    func silenceScratch(timbre: FeedbackTimbre) {
        parameters.setScratch(gain: 0, brightness: 0.5, timbre: timbre)
    }

    func whoosh(amplitude: Float, timbre: FeedbackTimbre) {
        restartIfNeeded()
        parameters.triggerWhoosh(amplitude: amplitude, timbre: timbre)
    }

    func playChime() {
        restartIfNeeded()
        output.playChime()
    }

    func playJingle() {
        restartIfNeeded()
        output.playJingle()
    }

    /// Le fichier audio tel quel, démarré à l'heure hôte donnée (même départ que les vibrations).
    func playFile(at url: URL, atHostTime hostTime: UInt64) {
        restartIfNeeded()
        output.playFile(at: url, atHostTime: hostTime)
    }

    func stopPlayback() {
        output.stopPlayback()
    }

    func allowHapticsDuringRecording() {
        output.allowHapticsDuringRecording()
    }

    /// Le système a pu arrêter le moteur sans prévenir (interruption, reconfiguration) : pendant
    /// l'usage, on fait vérifier son état réel par la file audio, au plus une fois par seconde.
    private func restartIfNeeded() {
        guard wantsRunning else { return }
        let now = CACurrentMediaTime()
        guard now - lastRestartRequest > 1 else { return }
        lastRestartRequest = now
        output.ensureRunning()
    }
}

/// Moteur `AVAudioEngine` de sortie, piloté depuis une file série dédiée : les appels à la session
/// et au moteur peuvent bloquer (IPC avec le serveur audio) et n'ont rien à faire sur le main thread.
///
/// Moteur distinct de celui du micro, mais même session et même catégorie (`.playAndRecord` /
/// `.measurement`) : passer en `.playback` casserait la détection du souffle.
nonisolated final class AudioOutput: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.pictarine.proto.RevelioMagicReveal.feedback-audio", qos: .userInitiated)
    private let parameters: SynthParameters

    // État confiné à `queue` (d'où `@unchecked Sendable`).
    private var wantsRunning = false
    private var engine: AVAudioEngine?
    private var chimeNode: AVAudioPlayerNode?
    private var chimeBuffer: AVAudioPCMBuffer?
    private var chimeRequested = false
    /// Jingle Bells au glockenspiel (~13 s), calculé à l'avance pour partir en même temps que l'haptique.
    private var jingleBuffer: AVAudioPCMBuffer?
    /// Lecteur des fichiers audio dont on déduit les vibrations (rebranché au format de chaque fichier).
    private var fileNode: AVAudioPlayerNode?
    private var engineObservers: [NSObjectProtocol] = []
    private var sessionObservers: [NSObjectProtocol] = []
    private let chimeFormat = AVAudioFormat(standardFormatWithSampleRate: ChimeSynth.sampleRate, channels: 2)

    init(parameters: SynthParameters) {
        self.parameters = parameters
    }

    func start() {
        queue.async { [self] in
            wantsRunning = true
            observeSessionIfNeeded()
            startEngine()
            renderChimeIfNeeded()
        }
    }

    func stop() {
        queue.async { [self] in
            wantsRunning = false
            chimeNode?.stop()
            engine?.stop()
        }
    }

    /// Relance le moteur s'il s'est arrêté (état réel, pas un drapeau qui pourrait mentir).
    func ensureRunning() {
        queue.async { [self] in
            if engine?.isRunning != true { startEngine() }
        }
    }

    func playChime() {
        queue.async { [self] in
            if engine?.isRunning != true { startEngine() }
            guard let engine, let chimeNode, let chimeBuffer else { return }
            // `play()` sur un moteur arrêté lève une exception Objective-C : on vérifie l'état réel.
            guard engine.isRunning else { return }
            // Arrêt puis relance : repart du début même si le nœud a gardé un état d'avant un redémarrage.
            chimeNode.stop()
            chimeNode.scheduleBuffer(chimeBuffer, at: nil)
            chimeNode.play()
        }
    }

    /// Lit le fichier lui-même (décodé par AVAudioFile, sans retouche), sur un lecteur dédié branché au
    /// format du fichier, à l'heure hôte donnée.
    func playFile(at url: URL, atHostTime hostTime: UInt64) {
        queue.async { [self] in
            if engine?.isRunning != true { startEngine() }
            guard let engine, engine.isRunning, let file = try? AVAudioFile(forReading: url) else { return }
            fileNode?.stop()
            if let old = fileNode { engine.detach(old) }
            let node = AVAudioPlayerNode()
            engine.attach(node)
            engine.connect(node, to: engine.mainMixerNode, format: file.processingFormat)
            fileNode = node
            node.scheduleFile(file, at: nil)
            node.play(at: AVAudioTime(hostTime: hostTime))
        }
    }

    func stopPlayback() {
        queue.async { [self] in fileNode?.stop() }
    }

    func playJingle() {
        queue.async { [self] in
            if engine?.isRunning != true { startEngine() }
            guard let engine, let chimeNode, let jingleBuffer, engine.isRunning else { return }
            chimeNode.stop()
            chimeNode.scheduleBuffer(jingleBuffer, at: nil)
            chimeNode.play()
        }
    }

    /// Par défaut, iOS coupe l'haptique quand l'app enregistre : sans ça, le grondement du souffle
    /// (micro actif) ne se sentirait pas. Ne touche ni à la catégorie ni au mode de la session.
    func allowHapticsDuringRecording() {
        queue.async {
            let session = AVAudioSession.sharedInstance()
            guard !session.allowHapticsAndSystemSoundsDuringRecording else { return }
            do {
                try session.setAllowHapticsAndSystemSoundsDuringRecording(true)
            } catch {
                FeedbackLog.report("haptics.recording", error)
            }
        }
    }

    // MARK: - Moteur (sur `queue`)

    private func startEngine() {
        guard wantsRunning else { return }
        do {
            try Self.configureSession()
            let engine = try self.engine ?? buildEngine()
            if !engine.isRunning {
                engine.prepare()
                try engine.start()
                FeedbackLog.note("sortie audio démarrée (\(Int(engine.outputNode.outputFormat(forBus: 0).sampleRate)) Hz)")
            }
        } catch {
            FeedbackLog.report("audio.start", error)
        }
    }

    private func buildEngine() throws -> AVAudioEngine {
        let session = AVAudioSession.sharedInstance()
        let sampleRate = session.sampleRate > 0 ? session.sampleRate : 48_000
        guard let sourceFormat = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1),
              let chimeFormat else { throw SoundError.format }

        let engine = AVAudioEngine()
        let renderer = SynthRenderer(parameters: parameters, sampleRate: Float(sampleRate))
        let source = AVAudioSourceNode(format: sourceFormat, renderBlock: Self.makeRenderBlock(renderer))
        let chime = AVAudioPlayerNode()
        engine.attach(source)
        engine.attach(chime)
        engine.connect(source, to: engine.mainMixerNode, format: sourceFormat)
        engine.connect(chime, to: engine.mainMixerNode, format: chimeFormat)
        chime.volume = 0.85
        engine.mainMixerNode.outputVolume = 0.9

        engineObservers.append(NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            queue.async { self.handleConfigurationChange() }
        })
        self.engine = engine
        chimeNode = chime
        return engine
    }

    private func tearDownEngine() {
        engine?.stop()
        for observer in engineObservers { NotificationCenter.default.removeObserver(observer) }
        engineObservers.removeAll()
        engine = nil
        chimeNode = nil
        fileNode = nil
    }

    /// Le rendu tourne sur le thread temps réel : le bloc ne fait que déléguer au `SynthRenderer`
    /// (aucune allocation, aucun verrou). Fabrique statique : le bloc ne capture rien d'autre.
    private static func makeRenderBlock(_ renderer: SynthRenderer) -> AVAudioSourceNodeRenderBlock {
        { isSilence, _, frameCount, audioBufferList in
            let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
            guard buffers.count > 0, let data = buffers[0].mData else { return noErr }
            let frames = Int(frameCount)
            let first = data.assumingMemoryBound(to: Float.self)
            let silent = renderer.render(into: first, frames: frames)
            // Format mono : un seul tampon en pratique, on recopie au cas où.
            if buffers.count > 1 {
                for index in 1..<buffers.count {
                    buffers[index].mData?.assumingMemoryBound(to: Float.self).update(from: first, count: frames)
                }
            }
            if silent { isSilence.pointee = true }
            return noErr
        }
    }

    /// Même catégorie, même mode, mêmes options que le micro : on ne la change que si besoin.
    private static func configureSession() throws {
        try AudioSessionConfig.activate()
    }

    // MARK: - Évènements système

    private func observeSessionIfNeeded() {
        guard sessionObservers.isEmpty else { return }
        let center = NotificationCenter.default
        let session = AVAudioSession.sharedInstance()
        sessionObservers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: session, queue: nil) { [weak self] note in
            let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            let type = raw.flatMap(AVAudioSession.InterruptionType.init(rawValue:))
            guard let self else { return }
            queue.async { self.handleInterruption(type) }
        })
        sessionObservers.append(center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: session, queue: nil) { [weak self] _ in
            guard let self else { return }
            queue.async { self.handleMediaServicesReset() }
        })
    }

    private func handleConfigurationChange() {
        // Le moteur s'est arrêté seul (route, fréquence, démarrage du micro…) : on rebranche la sortie
        // sur le format matériel courant puis on repart.
        guard let engine, wantsRunning else { return }
        FeedbackLog.note("configuration audio modifiée : on relance la sortie")
        let hardware = engine.outputNode.outputFormat(forBus: 0)
        if hardware.sampleRate > 0, hardware.channelCount > 0,
           let format = AVAudioFormat(standardFormatWithSampleRate: hardware.sampleRate, channels: hardware.channelCount) {
            engine.connect(engine.mainMixerNode, to: engine.outputNode, format: format)
        }
        startEngine()
    }

    private func handleInterruption(_ type: AVAudioSession.InterruptionType?) {
        // Pendant l'interruption, le système a arrêté le moteur ; à la fin, on repart.
        if type == .ended { startEngine() }
    }

    private func handleMediaServicesReset() {
        // Tout l'audio du système a redémarré : objets invalides, on reconstruit.
        tearDownEngine()
        startEngine()
    }

    // MARK: - Carillon

    private func renderChimeIfNeeded() {
        guard chimeBuffer == nil, !chimeRequested else { return }
        chimeRequested = true
        // Calcul à part (quelques dizaines de ms, davantage en Debug) pour garder la file réactive.
        Task.detached(priority: .utility) { [self] in
            let samples = ChimeSynth.render()
            queue.async { self.chimeBuffer = self.makeBuffer(samples) }
            let jingle = ChimeSynth.render(score: JingleBells.audioScore, duration: JingleBells.duration + 2)
            queue.async { self.jingleBuffer = self.makeBuffer(jingle) }
        }
    }

    private func makeBuffer(_ samples: ChimeSynth.Samples) -> AVAudioPCMBuffer? {
        guard let chimeFormat, samples.frameCount > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: chimeFormat, frameCapacity: AVAudioFrameCount(samples.frameCount)),
              let channels = buffer.floatChannelData else { return nil }
        buffer.frameLength = AVAudioFrameCount(samples.frameCount)
        samples.left.withUnsafeBufferPointer { channels[0].update(from: $0.baseAddress!, count: $0.count) }
        samples.right.withUnsafeBufferPointer { channels[1].update(from: $0.baseAddress!, count: $0.count) }
        return buffer
    }

    private enum SoundError: Error { case format }
}

/// Journal des retours : une seule ligne par type d'erreur, pour ne pas inonder la console.
/// Appelable depuis n'importe quel fil (file audio, main actor).
nonisolated enum FeedbackLog {
    private static let logger = Logger(subsystem: "com.pictarine.proto.RevelioMagicReveal", category: "Feedback")
    private static let reported = Mutex<Set<String>>([])

    static func report(_ key: String, _ error: any Error) {
        let isNew = reported.withLock { $0.insert(key).inserted }
        guard isNew else { return }
        logger.error("\(key, privacy: .public) : \(String(describing: error), privacy: .public)")
    }

    /// Repère de cycle de vie (niveau notice : conservé, visible dans Console), quelques lignes par session.
    static func note(_ message: String) {
        logger.notice("\(message, privacy: .public)")
    }
}
