import AVFAudio
import Foundation
import QuartzCore

/// Lit un message vocal sur un petit moteur à lui, qui n'existe que pendant que l'écran du message est
/// ouvert.
///
/// Séparé de la sortie des retours (`AudioOutput`) : le réglage « Son » coupe celle-ci, alors qu'un
/// message doit s'écouter même bruitages coupés ; et quand le système arrête le moteur (interruption,
/// changement de route ou de configuration), un message se met en pause à sa position au lieu de
/// repartir de zéro. Tout ce qui touche au moteur passe par une file série dédiée.
nonisolated final class MessagePlayer: @unchecked Sendable {
    enum StopReason: Sendable { case ended, interrupted }

    private let queue = DispatchQueue(label: "RevelioMagicReveal.message-player", qos: .userInitiated)
    private let onStop: @MainActor @Sendable (_ generation: Int, _ reason: StopReason) -> Void

    // État confiné à `queue`.
    private var engine: AVAudioEngine?
    private var node: AVAudioPlayerNode?
    private var format: AVAudioFormat?
    private var message: AudioMessage?
    private var generation = 0
    private var observers: [NSObjectProtocol] = []

    /// `onStop` reçoit le numéro de lecture concerné : à l'appelant d'ignorer ceux qu'il a dépassés.
    init(onStop: @escaping @MainActor @Sendable (_ generation: Int, _ reason: StopReason) -> Void) {
        self.onStop = onStop
    }

    func load(_ message: AudioMessage) {
        queue.async {
            self.node?.stop()
            self.message = message
        }
    }

    /// Lit depuis `offset` secondes. Renvoie l'instant (`CACurrentMediaTime`) où le son sort du
    /// haut-parleur, sur lequel caler vibrations et visuels ; nil si la lecture n'a pas pu partir.
    func play(from offset: Double, generation: Int, lead: Double = 0.12) async -> CFTimeInterval? {
        await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(returning: self.playOnQueue(from: offset, generation: generation, lead: lead))
            }
        }
    }

    func stop() {
        queue.async { self.node?.stop() }
    }

    /// Fermeture de l'écran : moteur libéré (le message, lui, est partagé avec le modèle de l'écran).
    func shutdown() {
        queue.async { self.tearDown() }
    }

    // MARK: - File du lecteur

    private func playOnQueue(from offset: Double, generation: Int, lead: Double) -> CFTimeInterval? {
        guard let message, !message.samples.isEmpty else { return nil }
        do {
            try AudioSessionConfig.activate()
            guard let (engine, node, format) = try prepareEngine(sampleRate: message.sampleRate) else { return nil }
            node.stop()
            self.generation = generation
            let first = min(max(Int(offset * message.sampleRate), 0), message.samples.count)
            let remaining = message.samples.count - first
            guard remaining > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(remaining)),
                  let channel = buffer.floatChannelData?[0] else { return nil }
            buffer.frameLength = AVAudioFrameCount(remaining)
            message.samples.withUnsafeBufferPointer { channel.update(from: $0.baseAddress! + first, count: remaining) }
            if !engine.isRunning {
                // Après un changement de configuration, la sortie peut avoir changé de format matériel.
                let hardware = engine.outputNode.outputFormat(forBus: 0)
                if hardware.sampleRate > 0, hardware.channelCount > 0,
                   let output = AVAudioFormat(standardFormatWithSampleRate: hardware.sampleRate, channels: hardware.channelCount) {
                    engine.connect(engine.mainMixerNode, to: engine.outputNode, format: output)
                }
                engine.prepare()
                try engine.start()
            }
            node.scheduleBuffer(buffer, at: nil, options: [], completionCallbackType: .dataPlayedBack,
                                completionHandler: Self.makeCompletion { [weak self] in
                                    guard let self else { return }
                                    queue.async { self.bufferFinished(generation: generation) }
                                })
            let startHost = mach_absolute_time() + AVAudioTime.hostTime(forSeconds: lead)
            node.play(at: AVAudioTime(hostTime: startHost))
            return AVAudioTime.seconds(forHostTime: startHost) + AVAudioSession.sharedInstance().outputLatency
        } catch {
            FeedbackLog.report("message.play", error)
            return nil
        }
    }

    /// Le rappel de fin part aussi quand on arrête le lecteur (pause, scrub) ou quand le système arrête
    /// le moteur : seule une fin pendant que tout tourne encore est la vraie fin du message.
    private func bufferFinished(generation: Int) {
        guard generation == self.generation, engine?.isRunning == true, node?.isPlaying == true else { return }
        node?.stop()
        let onStop = self.onStop
        Task { @MainActor in onStop(generation, .ended) }
    }

    private func prepareEngine(sampleRate: Double) throws -> (AVAudioEngine, AVAudioPlayerNode, AVAudioFormat)? {
        guard let wanted = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1) else { return nil }
        if let engine, let node, let format, format == wanted { return (engine, node, format) }
        let engine = self.engine ?? AVAudioEngine()
        let node = self.node ?? AVAudioPlayerNode()
        if self.engine == nil {
            engine.attach(node)
            observe(engine)
        } else {
            // Nouveau message à une autre fréquence (voix de synthèse ↔ micro) : on rebranche à l'arrêt.
            node.stop()
            engine.stop()
        }
        engine.connect(node, to: engine.mainMixerNode, format: wanted)
        self.engine = engine
        self.node = node
        format = wanted
        return (engine, node, wanted)
    }

    private func observe(_ engine: AVAudioEngine) {
        let center = NotificationCenter.default
        let session = AVAudioSession.sharedInstance()
        let interrupted: @Sendable (Notification) -> Void = { [weak self] _ in
            guard let self else { return }
            queue.async { self.systemStopped() }
        }
        observers = [
            center.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil, using: interrupted),
            center.addObserver(forName: AVAudioSession.interruptionNotification, object: session, queue: nil, using: interrupted),
            center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: session, queue: nil) { [weak self] _ in
                guard let self else { return }
                queue.async {
                    self.tearDown()
                    let onStop = self.onStop, generation = self.generation
                    Task { @MainActor in onStop(generation, .interrupted) }
                }
            },
        ]
    }

    /// Le système a arrêté (ou va arrêter) le son : pause à la position courante, l'écran reprendra.
    private func systemStopped() {
        node?.stop()
        let onStop = self.onStop, generation = self.generation
        Task { @MainActor in onStop(generation, .interrupted) }
    }

    private func tearDown() {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
        node?.stop()
        engine?.stop()
        engine = nil
        node = nil
        format = nil
    }

    /// Le rappel de fin tourne sur un fil audio : fabriqué hors main actor.
    private static func makeCompletion(
        _ handler: @escaping @Sendable () -> Void
    ) -> @Sendable (AVAudioPlayerNodeCompletionCallbackType) -> Void {
        { _ in handler() }
    }
}
