import AVFAudio
import Accelerate
import Foundation
import os

/// Message d'exemple dit par la voix de synthèse d'iOS, rendu en mémoire sur l'appareil : aucun son
/// tiers embarqué, donc aucune licence à respecter.
nonisolated enum SpeechSample {
    static let text = "Joyeux Noël ! J'espère que cette photo te fera sourire. Je t'embrasse fort, à très vite !"

    enum Failure: Error { case noVoice, timeout, empty }

    /// Rend le texte en tampons (sans toucher à la session audio de l'app) et les rassemble en un message.
    /// Le rendu prend plusieurs secondes : le résultat est gardé dans les caches pour les fois suivantes.
    static func render() async throws -> AudioMessage {
        guard let voice = bestVoice() else { throw Failure.noVoice }
        let cache = cacheURL(voice: voice)
        if let cached = load(cache) { return cached }
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = voice
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 0.95
        utterance.pitchMultiplier = 1.05
        let synthesizer = AVSpeechSynthesizer()
        // Le rendu en tampons n'a pas besoin de la session : sans ça, le synthétiseur pourrait la
        // reconfigurer et casser le mode « mesure » du souffle.
        synthesizer.usesApplicationAudioSession = false
        let collector = Collector(synthesizer: synthesizer)
        let (samples, sampleRate) = try await withCheckedThrowingContinuation { continuation in
            collector.begin(continuation)
            synthesizer.write(utterance, toBufferCallback: makeBufferCallback(collector))
        }
        let cleaned = VoiceCleanup.process(samples, sampleRate: sampleRate)
        guard !cleaned.isEmpty else { throw Failure.empty }
        let message = AudioMessage(samples: cleaned, sampleRate: sampleRate, source: .sample)
        save(message, to: cache)
        return message
    }

    // MARK: - Cache

    /// Un fichier par texte et par voix (empreinte FNV-1a stable d'un lancement à l'autre).
    private static func cacheURL(voice: AVSpeechSynthesisVoice) -> URL {
        var hash: UInt64 = 0xCBF2_9CE4_8422_2325
        for byte in (text + "|" + voice.identifier).utf8 {
            hash = (hash ^ UInt64(byte)) &* 0x100_0000_01B3
        }
        return URL.cachesDirectory.appending(path: "message-exemple-\(String(hash, radix: 16)).caf")
    }

    private static func load(_ url: URL) -> AudioMessage? {
        guard let file = try? AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)),
              (try? file.read(into: buffer)) != nil else { return nil }
        let samples = floats(from: buffer)
        guard !samples.isEmpty else { return nil }
        return AudioMessage(samples: samples, sampleRate: file.processingFormat.sampleRate, source: .sample)
    }

    private static func save(_ message: AudioMessage, to url: URL) {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: message.sampleRate, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(message.samples.count)),
              let channel = buffer.floatChannelData?[0] else { return }
        buffer.frameLength = AVAudioFrameCount(message.samples.count)
        message.samples.withUnsafeBufferPointer { channel.update(from: $0.baseAddress!, count: $0.count) }
        do {
            let file = try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: .pcmFormatFloat32,
                                       interleaved: false)
            try file.write(from: buffer)
        } catch {
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// Meilleure voix française installée (premium, puis améliorée, puis standard), hors voix fantaisie.
    static func bestVoice() -> AVSpeechSynthesisVoice? {
        let french = AVSpeechSynthesisVoice.speechVoices().filter {
            $0.language == "fr-FR" && !$0.voiceTraits.contains(.isNoveltyVoice)
        }
        return french.max { $0.quality.rawValue < $1.quality.rawValue } ?? AVSpeechSynthesisVoice(language: "fr-FR")
    }

    /// Échantillons du premier canal en Float : voix compactes en Int16, voix améliorées en Float32.
    static func floats(from buffer: AVAudioPCMBuffer) -> [Float] {
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return [] }
        let stride = buffer.stride
        switch buffer.format.commonFormat {
        case .pcmFormatFloat32:
            guard let data = buffer.floatChannelData else { return [] }
            return (0..<frames).map { data[0][$0 * stride] }
        case .pcmFormatInt16:
            guard let data = buffer.int16ChannelData else { return [] }
            var out = [Float](repeating: 0, count: frames)
            vDSP_vflt16(data[0], vDSP_Stride(stride), &out, 1, vDSP_Length(frames))
            var scale: Float = 1 / 32_768
            vDSP_vsmul(out, 1, &scale, &out, 1, vDSP_Length(frames))
            return out
        default:
            return converted(buffer)
        }
    }

    private static func converted(_ buffer: AVAudioPCMBuffer) -> [Float] {
        guard let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: buffer.format.sampleRate,
                                         channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: buffer.format, to: target),
              let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: buffer.frameLength) else { return [] }
        do {
            try converter.convert(to: out, from: buffer)
        } catch {
            return []
        }
        return floats(from: out)
    }

    /// Rappel appelé sur un fil interne du synthétiseur : fabriqué hors main actor.
    private static func makeBufferCallback(_ collector: Collector) -> AVSpeechSynthesizer.BufferCallback {
        { buffer in
            guard let pcm = buffer as? AVAudioPCMBuffer else { return }
            // Le dernier tampon est vide : le texte est entièrement rendu.
            if pcm.frameLength == 0 {
                collector.finish()
            } else {
                collector.append(floats(from: pcm), sampleRate: pcm.format.sampleRate)
            }
        }
    }

    /// Rassemble les tampons et reprend l'attente une seule fois (fin, ou délai dépassé). Garde le
    /// synthétiseur en vie jusque-là.
    private final class Collector: @unchecked Sendable {
        private struct State {
            var samples: [Float] = []
            var sampleRate: Double = 0
            var continuation: CheckedContinuation<([Float], Double), Error>?
            var synthesizer: AVSpeechSynthesizer?
        }

        private let state: OSAllocatedUnfairLock<State>

        init(synthesizer: AVSpeechSynthesizer) {
            state = OSAllocatedUnfairLock(uncheckedState: State(synthesizer: synthesizer))
        }

        func begin(_ continuation: CheckedContinuation<([Float], Double), Error>) {
            state.withLockUnchecked { $0.continuation = continuation }
            // Plusieurs secondes de rendu sur simulateur, parfois davantage au premier chargement de la voix.
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 30) { [self] in
                resume(with: .failure(Failure.timeout))
            }
        }

        func append(_ samples: [Float], sampleRate: Double) {
            state.withLockUnchecked {
                $0.samples.append(contentsOf: samples)
                $0.sampleRate = sampleRate
            }
        }

        func finish() {
            let (samples, sampleRate) = state.withLockUnchecked { ($0.samples, $0.sampleRate) }
            resume(with: samples.isEmpty || sampleRate <= 0 ? .failure(Failure.empty) : .success((samples, sampleRate)))
        }

        private func resume(with result: Result<([Float], Double), Error>) {
            let continuation = state.withLockUnchecked { state -> CheckedContinuation<([Float], Double), Error>? in
                defer {
                    state.continuation = nil
                    state.synthesizer = nil
                }
                return state.continuation
            }
            continuation?.resume(with: result)
        }
    }
}
