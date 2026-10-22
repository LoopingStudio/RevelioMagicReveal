import Foundation

extension HapticScripts {
    /// Intensité maximale des petits coups de syllabe et de la nappe : discrets, l'écoute reste au son.
    nonisolated static let voiceTapMax: Float = 0.45
    nonisolated static let voiceLayerMax: Float = 0.3

    /// Vibrations d'une voix : une nappe légère qui suit le niveau (plus nette quand la voix est aiguë) et
    /// un petit coup sur chaque attaque de syllabe, au moins 80 ms d'écart.
    nonisolated static func voice(_ analysis: AudioMessageAnalysis) -> [HapticEventSpec] {
        var events: [HapticEventSpec] = []
        var lastTap = -Double.infinity
        for onset in analysis.onsets where onset.time - lastTap >= 0.08 {
            events.append(HapticEventSpec(kind: .transient, time: onset.time,
                                          intensity: 0.2 + (voiceTapMax - 0.2) * onset.strength,
                                          sharpness: 0.2 + 0.3 * analysis.centroid(at: onset.time)))
            lastTap = onset.time
        }
        let step = 0.03
        var time = 0.0
        while time < analysis.duration {
            let level = analysis.level(at: time)
            if level >= 0.08 {
                events.append(HapticEventSpec(kind: .continuous(duration: step), time: time,
                                              intensity: min(voiceLayerMax, 0.35 * pow(level, 1.2)),
                                              sharpness: 0.05 + 0.3 * analysis.centroid(at: time)))
            }
            time += step
        }
        return events.sorted { $0.time < $1.time }
    }

    /// Le script vu depuis `offset` (reprise, scrub) : temps décalés, nappes à cheval raccourcies, le
    /// reste déjà passé retiré.
    nonisolated static func slice(_ events: [HapticEventSpec], from offset: Double) -> [HapticEventSpec] {
        guard offset > 0 else { return events }
        return events.compactMap { event in
            if event.time >= offset {
                var shifted = event
                shifted.time -= offset
                return shifted
            }
            guard case .continuous = event.kind, event.end > offset + 0.005 else { return nil }
            return HapticEventSpec(kind: .continuous(duration: event.end - offset), time: 0,
                                   intensity: event.intensity, sharpness: event.sharpness)
        }
    }
}
