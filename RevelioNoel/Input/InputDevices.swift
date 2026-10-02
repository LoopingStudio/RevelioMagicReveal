import AVFoundation
import CoreMotion
import Foundation
import UIKit

/// Niveau du micro en dBFS, livré sur le main actor avec la durée du tampon.
final class MicrophoneMonitor {
    enum Failure: Error { case noInput }

    private let audioEngine = AVAudioEngine()
    private(set) var isRunning = false
    var onLevel: ((_ decibels: Float, _ dt: Float) -> Void)?

    static func requestPermission() async -> Bool {
        await AVAudioApplication.requestRecordPermission()
    }

    static var permissionDenied: Bool {
        AVAudioApplication.shared.recordPermission == .denied
    }

    func start() throws {
        guard !isRunning else { return }
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .measurement, options: [.mixWithOthers, .defaultToSpeaker])
        try session.setActive(true)
        let input = audioEngine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw Failure.noInput }
        let deliver: @Sendable (Float, Float) -> Void = { [weak self] db, dt in
            Task { @MainActor in self?.onLevel?(db, dt) }
        }
        input.installTap(onBus: 0, bufferSize: 1024, format: format, block: Self.makeTap(sampleRate: format.sampleRate, deliver: deliver))
        do {
            try audioEngine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw error
        }
        isRunning = true
    }

    func stop() {
        guard isRunning else { return }
        audioEngine.inputNode.removeTap(onBus: 0)
        audioEngine.stop()
        isRunning = false
    }

    /// Le tap tourne sur le thread audio : il ne doit pas hériter de l'isolation main actor.
    nonisolated private static func makeTap(sampleRate: Double, deliver: @escaping @Sendable (Float, Float) -> Void) -> AVAudioNodeTapBlock {
        { buffer, _ in
            guard let channel = buffer.floatChannelData?[0] else { return }
            let frames = Int(buffer.frameLength)
            let rms = BlowAnalyzer.rms(UnsafeBufferPointer(start: channel, count: frames))
            deliver(BlowAnalyzer.decibels(rms: rms), Float(Double(frames) / sampleRate))
        }
    }
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
    static let deviceDidShake = Notification.Name("RevelioNoel.deviceDidShake")
}

extension UIWindow {
    open override func motionEnded(_ motion: UIEvent.EventSubtype, with event: UIEvent?) {
        if motion == .motionShake {
            NotificationCenter.default.post(name: .deviceDidShake, object: nil)
        }
        super.motionEnded(motion, with: event)
    }
}
