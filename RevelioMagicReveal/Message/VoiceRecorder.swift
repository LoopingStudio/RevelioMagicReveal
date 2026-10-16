import AVFAudio
import Foundation
import os

/// Enregistre un message vocal en mémoire (60 s au plus), avec un niveau en direct pour l'écran.
///
/// Moteur et file à lui, même session que le reste (mode « mesure ») : la voix arrive sans gain
/// automatique, `VoiceCleanup` la remet à niveau à la fin. Le micro du souffle doit être arrêté avant.
nonisolated final class VoiceRecorder: @unchecked Sendable {
    static let maxDuration = 60.0

    enum Failure: Error { case noInput }

    private struct Take {
        var samples: [Float] = []
        var sampleRate: Double = 48_000
        var limit = 0
        var limitReported = false
    }

    private let queue = DispatchQueue(label: "RevelioMagicReveal.voice-recorder", qos: .userInitiated)
    /// Confiné à `queue`.
    private var engine: AVAudioEngine?
    private let take = OSAllocatedUnfairLock(initialState: Take())
    private let onLevel: @MainActor @Sendable (Float) -> Void
    private let onLimit: @MainActor @Sendable () -> Void

    /// `onLevel` : niveau 0…1 de chaque tampon reçu ; `onLimit` : durée maximale atteinte.
    init(onLevel: @escaping @MainActor @Sendable (Float) -> Void, onLimit: @escaping @MainActor @Sendable () -> Void) {
        self.onLevel = onLevel
        self.onLimit = onLimit
    }

    func start(mic: MicSource) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                do {
                    try self.startOnQueue(mic: mic)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Arrête et rend le message mis en forme (sur la file de l'enregistreur : quelques centaines de ms
    /// pour une minute), nil si rien d'exploitable n'a été capté.
    func finish() async -> AudioMessage? {
        await withCheckedContinuation { (continuation: CheckedContinuation<AudioMessage?, Never>) in
            queue.async {
                self.stopOnQueue()
                let captured = self.take.withLock { take in
                    defer { take = Take() }
                    return take
                }
                continuation.resume(returning: Self.message(from: captured))
            }
        }
    }

    private static func message(from captured: Take) -> AudioMessage? {
        // Moins de 0,3 s : appui trop bref, rien à écouter.
        guard Double(captured.samples.count) >= 0.3 * captured.sampleRate else { return nil }
        let cleaned = VoiceCleanup.process(captured.samples, sampleRate: captured.sampleRate)
        guard !cleaned.isEmpty else { return nil }
        return AudioMessage(samples: cleaned, sampleRate: captured.sampleRate, source: .recording)
    }

    func cancel() {
        queue.async {
            self.stopOnQueue()
            self.take.withLock { $0 = Take() }
        }
    }

    private func startOnQueue(mic: MicSource) throws {
        stopOnQueue()
        try AudioSessionConfig.activate()
        AudioSessionConfig.selectMic(mic)
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw Failure.noInput }
        let limit = Int(Self.maxDuration * format.sampleRate)
        take.withLock {
            $0 = Take(sampleRate: format.sampleRate, limit: limit)
            $0.samples.reserveCapacity(limit)
        }
        input.installTap(onBus: 0, bufferSize: 1024, format: format,
                         block: Self.makeTap(take: take, onLevel: onLevel, onLimit: onLimit))
        do {
            engine.prepare()
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw error
        }
        self.engine = engine
    }

    private func stopOnQueue() {
        guard let engine else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        self.engine = nil
    }

    /// Le tap tourne sur un fil audio : fabriqué hors main actor, il ne fait que copier et mesurer.
    private static func makeTap(take: OSAllocatedUnfairLock<Take>,
                                onLevel: @escaping @MainActor @Sendable (Float) -> Void,
                                onLimit: @escaping @MainActor @Sendable () -> Void) -> AVAudioNodeTapBlock {
        { buffer, _ in
            guard let data = buffer.floatChannelData else { return }
            let frames = Int(buffer.frameLength)
            let samples = Array(UnsafeBufferPointer(start: data[0], count: frames))
            let reachedLimit = take.withLock { take -> Bool in
                let room = take.limit - take.samples.count
                take.samples.append(contentsOf: samples.prefix(max(0, room)))
                guard room <= frames, !take.limitReported else { return false }
                take.limitReported = true
                return true
            }
            var sum: Float = 0
            for s in samples { sum += s * s }
            let db = 10 * log10(max(sum / Float(max(frames, 1)), 1e-12))
            // Voix en mode « mesure » : −55 dB (murmure lointain) … −10 dB (près du micro).
            let level = min(max((db + 55) / 45, 0), 1)
            Task { @MainActor in
                onLevel(level)
                if reachedLimit { onLimit() }
            }
        }
    }
}
