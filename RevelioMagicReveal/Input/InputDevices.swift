import AVFoundation
import CoreMotion
import Foundation
import UIKit
import os

/// Micro intégré à utiliser : l'iPhone en a un en bas, un à l'avant (écouteur) et un à l'arrière.
nonisolated enum MicSource: String, CaseIterable, Sendable {
    case auto, bottom, front, back

    var title: String {
        switch self {
        case .auto: "Automatique"
        case .bottom: "Bas"
        case .front: "Avant"
        case .back: "Arrière"
        }
    }

    var orientation: AVAudioSession.Orientation? {
        switch self {
        case .auto: nil
        case .bottom: .bottom
        case .front: .front
        case .back: .back
        }
    }
}

/// Analyse le micro par blocs (~40 ms) et livre leurs mesures sur le main actor.
///
/// L'activation de la session et le démarrage du moteur audio peuvent bloquer plusieurs secondes
/// (serveur audio lent ou occupé) : tout ce qui touche à l'audio passe par une file série dédiée,
/// jamais par le fil principal.
nonisolated final class MicrophoneMonitor: @unchecked Sendable {
    enum Failure: Error { case noInput }

    /// Seule file qui touche `audioEngine` et `isRunning`.
    private let queue = DispatchQueue(label: "RevelioMagicReveal.microphone", qos: .userInitiated)
    private let audioEngine = AVAudioEngine()
    private var isRunning = false
    private let onFrame: @MainActor @Sendable (_ features: BlowFeatures, _ dt: Float) -> Void
    /// Fréquence d'échantillonnage et micro réellement utilisés (lus depuis le fil principal).
    private let live = OSAllocatedUnfairLock(initialState: (sampleRate: 48_000.0, sourceName: "?"))
    let recorder: BlowRecorder

    init(recorder: BlowRecorder, onFrame: @escaping @MainActor @Sendable (_ features: BlowFeatures, _ dt: Float) -> Void) {
        self.recorder = recorder
        self.onFrame = onFrame
    }

    static func requestPermission() async -> Bool {
        await AVAudioApplication.requestRecordPermission()
    }

    var sampleRate: Double { live.withLock { $0.sampleRate } }
    /// Nom du micro choisi par le système (« Bas », « Avant »… selon la langue de l'appareil).
    var sourceName: String { live.withLock { $0.sourceName } }

    func start(source: MicSource) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                do {
                    try self.startOnQueue(source: source)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func stop() {
        queue.async { self.stopOnQueue() }
    }

    private func startOnQueue(source: MicSource) throws {
        guard !isRunning else { return }
        let session = AVAudioSession.sharedInstance()
        // Même configuration que la sortie audio (Feedback/ProceduralSound) : souvent déjà en place.
        let options: AVAudioSession.CategoryOptions = [.mixWithOthers, .defaultToSpeaker]
        if session.category != .playAndRecord || session.mode != .measurement || session.categoryOptions != options {
            try session.setCategory(.playAndRecord, mode: .measurement, options: options)
        }
        try session.setActive(true)
        selectBuiltInMic(source, in: session)

        let input = audioEngine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw Failure.noInput }
        let sourceName = session.inputDataSource?.dataSourceName ?? session.currentRoute.inputs.first?.portName ?? "?"
        live.withLock { $0 = (format.sampleRate, sourceName) }

        let onFrame = self.onFrame
        let deliver: @Sendable (BlowFeatures, Float) -> Void = { features, dt in
            Task { @MainActor in onFrame(features, dt) }
        }
        let extractor = BlowFeatureExtractor(sampleRate: Float(format.sampleRate))
        input.installTap(onBus: 0, bufferSize: 2048, format: format,
                         block: Self.makeTap(extractor: extractor, recorder: recorder, deliver: deliver))
        do {
            try audioEngine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw error
        }
        isRunning = true
    }

    /// Choisit le micro intégré demandé ; « Automatique » laisse le choix au système.
    private func selectBuiltInMic(_ source: MicSource, in session: AVAudioSession) {
        guard let builtIn = session.availableInputs?.first(where: { $0.portType == .builtInMic }) else { return }
        try? session.setPreferredInput(builtIn)
        guard let orientation = source.orientation,
              let dataSource = builtIn.dataSources?.first(where: { $0.orientation == orientation }) else { return }
        try? builtIn.setPreferredDataSource(dataSource)
    }

    private func stopOnQueue() {
        guard isRunning else { return }
        recorder.cancel()
        audioEngine.inputNode.removeTap(onBus: 0)
        audioEngine.stop()
        isRunning = false
    }

    /// Le tap tourne sur un fil audio : il ne doit pas hériter d'une isolation d'acteur. Les tampons
    /// reçus sont recoupés en blocs de la taille de l'analyse.
    private static func makeTap(extractor: BlowFeatureExtractor, recorder: BlowRecorder,
                                deliver: @escaping @Sendable (BlowFeatures, Float) -> Void) -> AVAudioNodeTapBlock {
        let pending = SampleQueue()
        let size = extractor.frameSize
        let dt = Float(size) / extractor.sampleRate
        return { buffer, _ in
            guard let channel = buffer.floatChannelData?[0] else { return }
            pending.samples.append(contentsOf: UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
            while pending.samples.count >= size {
                pending.samples.withUnsafeBufferPointer { all in
                    let block = UnsafeBufferPointer(rebasing: all[0..<size])
                    let features = extractor.analyze(block)
                    recorder.append(block, features: features)
                    deliver(features, dt)
                }
                pending.samples.removeFirst(size)
            }
        }
    }
}

/// Reliquat d'échantillons entre deux tampons du tap (utilisé par un seul fil).
nonisolated private final class SampleQueue: @unchecked Sendable {
    var samples: [Float] = []
}

/// Mouvement de l'appareil (gravité, accélération utilisateur) à 60 Hz, sur le main actor.
final class MotionMonitor {
    private let manager = CMMotionManager()

    var isAvailable: Bool { manager.isDeviceMotionAvailable }

    func start(_ handler: @escaping @MainActor (CMDeviceMotion) -> Void) {
        guard manager.isDeviceMotionAvailable, !manager.isDeviceMotionActive else { return }
        manager.deviceMotionUpdateInterval = 1.0 / 60
        manager.startDeviceMotionUpdates(to: .main) { motion, _ in
            guard let motion else { return }
            MainActor.assumeIsolated { handler(motion) }
        }
    }

    func stop() {
        manager.stopDeviceMotionUpdates()
    }
}

extension Notification.Name {
    /// Secousse système (menu Device > Shake du simulateur, ⌃⌘Z).
    static let deviceDidShake = Notification.Name("RevelioMagicReveal.deviceDidShake")
}

extension UIWindow {
    open override func motionEnded(_ motion: UIEvent.EventSubtype, with event: UIEvent?) {
        if motion == .motionShake {
            NotificationCenter.default.post(name: .deviceDidShake, object: nil)
        }
        super.motionEnded(motion, with: event)
    }
}
