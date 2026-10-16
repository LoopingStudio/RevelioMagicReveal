import AVFoundation
import CoreMotion
import Foundation
import UIKit
import os

/// Micro intégré qui écoute le souffle. Le mode « mesure » ne donne qu'un canal (pas de stéréo), mais on
/// choisit lequel : celui du haut, côté écran (à côté de l'écouteur), ou celui du bas.
nonisolated enum MicSource: String, CaseIterable, Sendable {
    case front, bottom

    var title: String {
        switch self {
        case .front: "Haut (côté écran)"
        case .bottom: "Bas"
        }
    }

    var orientation: AVAudioSession.Orientation {
        switch self {
        case .front: .front
        case .bottom: .bottom
        }
    }

    /// Consigne du geste « souffler » : où diriger son souffle pour ce micro.
    var blowHint: String {
        switch self {
        case .front: "Souffle sur l'écran"
        case .bottom: "Souffle sur le bas de l'iPhone"
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
    /// Recréé à chaque démarrage : le format matériel de l'entrée peut changer d'une fois sur l'autre.
    private var audioEngine = AVAudioEngine()
    private var isRunning = false
    private let onFrame: @MainActor @Sendable (_ channels: [BlowFeatures], _ dt: Float) -> Void
    /// Fréquence d'échantillonnage et micro réellement utilisés (lus depuis le fil principal).
    private let live = OSAllocatedUnfairLock(initialState: (sampleRate: 48_000.0, sourceName: "?", channels: 1))
    let recorder: BlowRecorder

    init(recorder: BlowRecorder, onFrame: @escaping @MainActor @Sendable (_ channels: [BlowFeatures], _ dt: Float) -> Void) {
        self.recorder = recorder
        self.onFrame = onFrame
    }

    static func requestPermission() async -> Bool {
        await AVAudioApplication.requestRecordPermission()
    }

    var sampleRate: Double { live.withLock { $0.sampleRate } }
    /// Nom du micro choisi par le système (« Bas », « Avant »… selon la langue de l'appareil).
    var sourceName: String { live.withLock { $0.sourceName } }
    private let diagnosticLock = OSAllocatedUnfairLock(initialState: "")
    /// État de la session audio au démarrage (mode, micro, motif polaire, canaux) : écrit dans les
    /// enregistrements pour comprendre ce qu'iOS a accordé.
    var diagnostic: String { diagnosticLock.withLock { $0 } }

    var channelCount: Int { live.withLock { $0.channels } }

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
        try AudioSessionConfig.activate()
        AudioSessionConfig.selectMic(source)

        audioEngine = AVAudioEngine()
        let input = audioEngine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw Failure.noInput }
        let channels = min(2, Int(format.channelCount))
        let sourceName = session.inputDataSource?.dataSourceName ?? session.currentRoute.inputs.first?.portName ?? "?"
        let dataSource = session.inputDataSource
        let diagnostic = "mode=\(session.mode.rawValue) source=\(dataSource?.dataSourceName ?? "?") "
            + "polaire=\(dataSource?.selectedPolarPattern?.rawValue ?? "?") "
            + "polairesPossibles=\((dataSource?.supportedPolarPatterns ?? []).map(\.rawValue).joined(separator: "|")) "
            + "canauxMax=\(session.maximumInputNumberOfChannels) canauxSession=\(session.inputNumberOfChannels) "
            + "canauxMoteur=\(format.channelCount)"
        diagnosticLock.withLock { $0 = diagnostic }
        live.withLock { $0 = (format.sampleRate, sourceName, channels) }

        let onFrame = self.onFrame
        let deliver: @Sendable ([BlowFeatures], Float) -> Void = { features, dt in
            Task { @MainActor in onFrame(features, dt) }
        }
        let extractors = (0..<channels).map { _ in BlowFeatureExtractor(sampleRate: Float(format.sampleRate)) }
        input.installTap(onBus: 0, bufferSize: 2048, format: format,
                         block: Self.makeTap(extractors: extractors, recorder: recorder, deliver: deliver))
        do {
            try audioEngine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw error
        }
        isRunning = true
    }

    private func stopOnQueue() {
        guard isRunning else { return }
        recorder.cancel()
        audioEngine.inputNode.removeTap(onBus: 0)
        audioEngine.stop()
        isRunning = false
    }

    /// Le tap tourne sur un fil audio : il ne doit pas hériter d'une isolation d'acteur. Les tampons
    /// reçus sont recoupés en blocs de la taille de l'analyse, canal par canal.
    private static func makeTap(extractors: [BlowFeatureExtractor], recorder: BlowRecorder,
                                deliver: @escaping @Sendable ([BlowFeatures], Float) -> Void) -> AVAudioNodeTapBlock {
        let pending = extractors.map { _ in SampleQueue() }
        let size = extractors[0].frameSize
        let dt = Float(size) / extractors[0].sampleRate
        return { buffer, _ in
            guard let data = buffer.floatChannelData else { return }
            let frames = Int(buffer.frameLength)
            for c in pending.indices {
                let channel = min(c, Int(buffer.format.channelCount) - 1)
                pending[c].samples.append(contentsOf: UnsafeBufferPointer(start: data[channel], count: frames))
            }
            while pending[0].samples.count >= size {
                var features: [BlowFeatures] = []
                var blocks: [[Float]] = []
                for c in pending.indices {
                    let block = Array(pending[c].samples[0..<size])
                    features.append(block.withUnsafeBufferPointer { extractors[c].analyze($0) })
                    blocks.append(block)
                    pending[c].samples.removeFirst(size)
                }
                recorder.append(blocks, features: features)
                deliver(features, dt)
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
