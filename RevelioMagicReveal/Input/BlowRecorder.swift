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
        /// État de la session audio (voir `MicrophoneMonitor.diagnostic`).
        var audioDiagnostic: String = ""
    }

    private struct Take {
        var context: Context
        var start = Date()
        var sampleRate: Double
        /// Un tableau d'échantillons par canal.
        var samples: [[Float]]
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
            current = take
        }
    }

    func cancel() {
        state.withLock { $0 = nil }
    }

    /// Appelé par le tap du micro pour chaque bloc analysé (un bloc et ses mesures par canal).
    /// Les colonnes principales du CSV portent le canal suivi (celui qui ressemble le plus à un souffle) ;
    /// les colonnes `_c0`, `_c1` détaillent chaque canal.
    func append(_ blocks: [[Float]], features: [BlowFeatures]) {
        guard !blocks.isEmpty, blocks.count == features.count else { return }
        let finished: Take? = state.withLockUnchecked { current in
            guard var take = current else { return nil }
            if take.samples.count != blocks.count {
                take.samples = blocks.map { _ in
                    var channel: [Float] = []
                    channel.reserveCapacity(Int(take.sampleRate * take.context.seconds) + 4096)
                    return channel
                }
            }
            let dt = Double(blocks[0].count) / take.sampleRate
            let chosen = BlowChannelChooser.choose(features, classifier: take.context.classifier,
                                                   thresholdDB: take.context.thresholdDB)
            let open = take.gate.process(features[chosen], thresholdDB: take.context.thresholdDB, dt: Float(dt))
            for c in blocks.indices { take.samples[c].append(contentsOf: blocks[c]) }
            var row = String(format: "%.3f,", take.elapsed) + features[chosen].csvRow
                + ",\(take.gate.lastBlowLike ? 1 : 0),\(open ? 1 : 0),\(chosen)"
            for f in features {
                row += String(format: ",%.2f,%.4f,%.4f,%.4f,%.1f", f.levelDB, f.harmonicity, f.lowRatio, f.highRatio, f.centroidHz)
            }
            take.rows.append(row)
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

    /// Mono : un seul canal.
    func append(_ block: UnsafeBufferPointer<Float>, features: BlowFeatures) {
        append([Array(block)], features: [features])
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

            let channels = max(1, take.samples.count)
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: take.sampleRate,
                AVNumberOfChannelsKey: channels,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
            ]
            let file = try AVAudioFile(forWriting: wavURL, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
            let frames = take.samples.first?.count ?? 0
            guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(frames)) else {
                return nil
            }
            buffer.frameLength = AVAudioFrameCount(frames)
            for c in take.samples.indices {
                take.samples[c].withUnsafeBufferPointer { source in
                    buffer.floatChannelData![c].update(from: source.baseAddress!, count: source.count)
                }
            }
            try file.write(from: buffer)

            let c = take.context.classifier
            var csv = """
            # étiquette=\(take.context.label.rawValue) micro=\(take.context.micSource) fréquence=\(Int(take.sampleRate)) Hz
            # seuilDB=\(take.context.thresholdDB) maxHarmonicity=\(c.maxHarmonicity) minLowRatio=\(c.minLowRatio) maxHighRatio=\(c.maxHighRatio) maxCentroidHz=\(c.maxCentroidHz) directMinLevelDB=\(c.directMinLevelDB) minDuration=\(c.minDuration) releaseDuration=\(c.releaseDuration)
            # session : \(take.context.audioDiagnostic)
            # canaux=\(channels) (colonnes principales = canal suivi « canal » ; détail par canal en _c0, _c1)
            t,\(BlowFeatures.csvHeader),blowLike,gateOpen,canal\(perChannelHeader(channels))

            """
            csv += take.rows.joined(separator: "\n")
            try csv.write(to: csvURL, atomically: true, encoding: .utf8)
            return wavURL
        } catch {
            return nil
        }
    }

    private static func perChannelHeader(_ channels: Int) -> String {
        (0..<channels).map { c in ",levelDB_c\(c),harmonicity_c\(c),lowRatio_c\(c),highRatio_c\(c),centroidHz_c\(c)" }.joined()
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
