import AVFoundation
import Foundation
import os

/// Enregistrements étiquetés pour régler la détection du souffle sur un vrai iPhone : le son brut (WAV)
/// et les mesures de chaque bloc (CSV), rangés dans Documents/Enregistrements souffle (visible dans
/// l'app Fichiers et partageable par AirDrop depuis le mode debug).
nonisolated final class BlowRecorder: @unchecked Sendable {
    enum Label: String, CaseIterable, Sendable {
        case souffle, voix, autre

        var title: String {
            switch self {
            case .souffle: "Souffle"
            case .voix: "Voix"
            case .autre: "Autre"
            }
        }
    }

    /// Ce qu'on sait au début de la prise, pour l'en-tête du CSV.
    struct Context: Sendable {
        var label: Label
        var seconds: Double
        var micSource: String
        var thresholdDB: Float
        var classifier: BlowClassifier
    }

    private struct Take {
        var context: Context
        var start = Date()
        var sampleRate: Double
        var samples: [Float]
        var rows: [String]
        var elapsed: Double = 0
        var gate: BlowGate
    }

    static var directory: URL {
        URL.documentsDirectory.appending(path: "Enregistrements souffle", directoryHint: .isDirectory)
    }

    private let state = OSAllocatedUnfairLock<Take?>(initialState: nil)
    private let writeQueue = DispatchQueue(label: "RevelioMagicReveal.blow-recorder", qos: .utility)
    private let onFinished: @Sendable (URL?) -> Void

    /// `onFinished` est appelé (hors fil principal) avec le WAV écrit, ou nil en cas d'échec.
    init(onFinished: @escaping @Sendable (URL?) -> Void) {
        self.onFinished = onFinished
    }

    var isRecording: Bool { state.withLock { $0 != nil } }

    func start(_ context: Context, sampleRate: Double) {
        var gate = BlowGate()
        gate.classifier = context.classifier
        let take = Take(context: context, sampleRate: sampleRate,
                        samples: [], rows: [], gate: gate)
        state.withLock { current in
            var fresh = take
            fresh.samples.reserveCapacity(Int(sampleRate * context.seconds) + 4096)
            current = fresh
        }
    }

    func cancel() {
        state.withLock { $0 = nil }
    }

    /// Appelé par le tap du micro pour chaque bloc analysé.
    func append(_ samples: UnsafeBufferPointer<Float>, features: BlowFeatures) {
        let finished: Take? = state.withLockUnchecked { current in
            guard var take = current else { return nil }
            let dt = Double(samples.count) / take.sampleRate
            let open = take.gate.process(features, thresholdDB: take.context.thresholdDB, dt: Float(dt))
            take.samples.append(contentsOf: samples)
            take.rows.append(String(format: "%.3f,", take.elapsed) + features.csvRow
                             + ",\(take.gate.lastBlowLike ? 1 : 0),\(open ? 1 : 0)")
            take.elapsed += dt
            if take.elapsed >= take.context.seconds {
                current = nil
                return take
            }
            current = take
            return nil
        }
        guard let finished else { return }
        writeQueue.async { [onFinished] in
            onFinished(Self.write(finished))
        }
    }

    private static func write(_ take: Take) -> URL? {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyy-MM-dd_HH'h'mm'm'ss"
            let stamp = formatter.string(from: take.start)
            let base = "\(take.context.label.rawValue)_\(stamp)_micro-\(take.context.micSource)"
            let wavURL = directory.appending(path: base + ".wav")
            let csvURL = directory.appending(path: base + ".csv")

            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: take.sampleRate,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
            ]
            let file = try AVAudioFile(forWriting: wavURL, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(take.samples.count)) else {
                return nil
            }
            buffer.frameLength = AVAudioFrameCount(take.samples.count)
            take.samples.withUnsafeBufferPointer { source in
                buffer.floatChannelData![0].update(from: source.baseAddress!, count: source.count)
            }
            try file.write(from: buffer)

            let c = take.context.classifier
            var csv = """
            # étiquette=\(take.context.label.rawValue) micro=\(take.context.micSource) fréquence=\(Int(take.sampleRate)) Hz
            # seuilDB=\(take.context.thresholdDB) maxHarmonicity=\(c.maxHarmonicity) minLowRatio=\(c.minLowRatio) maxHighRatio=\(c.maxHighRatio) minDuration=\(c.minDuration) releaseDuration=\(c.releaseDuration)
            t,\(BlowFeatures.csvHeader),blowLike,gateOpen

            """
            csv += take.rows.joined(separator: "\n")
            try csv.write(to: csvURL, atomically: true, encoding: .utf8)
            return wavURL
        } catch {
            return nil
        }
    }

    /// Tous les fichiers enregistrés, du plus récent au plus ancien.
    static func recordings() -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return files
            .filter { ["wav", "csv"].contains($0.pathExtension) }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    static func deleteAll() {
        try? FileManager.default.removeItem(at: directory)
    }
}
