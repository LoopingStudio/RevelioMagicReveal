import Foundation

/// Refrain de Jingle Bells (8 premières mesures, jusqu'au « hey ! »), en sol majeur, dans le registre du
/// glockenspiel. Une seule partition pour le son et l'haptique, pour qu'ils tombent ensemble.
nonisolated enum JingleBells {
    struct Note: Equatable, Sendable {
        /// Position en temps (noires) depuis le début.
        var beat: Double
        /// Durée en temps.
        var beats: Double
        var frequency: Double
    }

    /// Durée d'une noire (≈ 176 à la noire : entraînant sans être précipité).
    static let beatDuration: Double = 0.34

    private static let g5 = 783.99, a5 = 880.0, b5 = 987.77, c6 = 1046.50, d6 = 1174.66

    static let melody: [Note] = [
        // Jin-gle bells, jin-gle bells,
        Note(beat: 0, beats: 1, frequency: b5), Note(beat: 1, beats: 1, frequency: b5), Note(beat: 2, beats: 2, frequency: b5),
        Note(beat: 4, beats: 1, frequency: b5), Note(beat: 5, beats: 1, frequency: b5), Note(beat: 6, beats: 2, frequency: b5),
        // jin-gle all the way,
        Note(beat: 8, beats: 1, frequency: b5), Note(beat: 9, beats: 1, frequency: d6),
        Note(beat: 10, beats: 1.5, frequency: g5), Note(beat: 11.5, beats: 0.5, frequency: a5),
        Note(beat: 12, beats: 4, frequency: b5),
        // oh what fun it is to ride in a
        Note(beat: 16, beats: 1, frequency: c6), Note(beat: 17, beats: 1, frequency: c6),
        Note(beat: 18, beats: 1.5, frequency: c6), Note(beat: 19.5, beats: 0.5, frequency: c6),
        Note(beat: 20, beats: 1, frequency: c6), Note(beat: 21, beats: 1, frequency: b5),
        Note(beat: 22, beats: 1, frequency: b5), Note(beat: 23, beats: 0.5, frequency: b5), Note(beat: 23.5, beats: 0.5, frequency: b5),
        // one-horse o-pen sleigh, hey !
        Note(beat: 24, beats: 1, frequency: b5), Note(beat: 25, beats: 1, frequency: a5),
        Note(beat: 26, beats: 1, frequency: a5), Note(beat: 27, beats: 1, frequency: b5),
        Note(beat: 28, beats: 2, frequency: a5), Note(beat: 30, beats: 2, frequency: d6),
    ]

    /// Durée totale de la mélodie, en secondes.
    static var duration: Double {
        melody.map { ($0.beat + $0.beats) * beatDuration }.max() ?? 0
    }

    static func time(of note: Note) -> Double { note.beat * beatDuration }

    /// Temps fort : premier temps de chaque mesure (4 temps), et le « hey » final.
    static func isAccent(_ note: Note) -> Bool {
        note.beat.truncatingRemainder(dividingBy: 4) == 0 || note == melody.last
    }

    /// Hauteur de la note ramenée à 0…1 sur l'étendue de la mélodie (échelle logarithmique, comme l'oreille).
    static func pitchPosition(_ note: Note) -> Double {
        let frequencies = melody.map(\.frequency)
        guard let low = frequencies.min(), let high = frequencies.max(), high > low else { return 0.5 }
        return log2(note.frequency / low) / log2(high / low)
    }

    /// Partition pour le glockenspiel (`ChimeSynth`), avec un léger balancement gauche/droite.
    static var audioScore: [CelebrationNote] {
        melody.enumerated().map { index, note in
            CelebrationNote(time: time(of: note), frequency: note.frequency,
                            velocity: isAccent(note) ? 0.8 : 0.6, pan: index.isMultiple(of: 2) ? -0.15 : 0.15)
        }
    }
}

extension HapticScripts {
    /// La mélodie en vibrations. Le moteur haptique ne joue pas de notes : la hauteur passe par la
    /// netteté (sourde dans le grave, sèche dans l'aigu), le rythme par les attaques, les temps forts
    /// par l'intensité, et les notes longues par une résonance qui s'éteint.
    static func melody(_ notes: [JingleBells.Note] = JingleBells.melody,
                       beatDuration: Double = JingleBells.beatDuration) -> [HapticEventSpec] {
        var events: [HapticEventSpec] = []
        for note in notes {
            let time = note.beat * beatDuration
            let length = note.beats * beatDuration
            let accent = JingleBells.isAccent(note)
            let sharpness = Float(0.25 + 0.7 * JingleBells.pitchPosition(note))
            events.append(HapticEventSpec(kind: .transient, time: time,
                                          intensity: accent ? 1 : 0.72, sharpness: sharpness))
            if note.beats >= 2 {
                // Note tenue : résonance en paliers décroissants sur 70 % de sa durée.
                let levels: [Float] = accent ? [0.5, 0.36, 0.24, 0.12] : [0.4, 0.28, 0.18, 0.09]
                let step = length * 0.7 / Double(levels.count)
                for (index, level) in levels.enumerated() {
                    events.append(HapticEventSpec(kind: .continuous(duration: step), time: time + 0.02 + Double(index) * step,
                                                  intensity: level, sharpness: sharpness * 0.7))
                }
            } else {
                // Note courte : un petit corps vibrant qui donne la « couleur » de la note.
                events.append(HapticEventSpec(kind: .continuous(duration: min(length * 0.6, 0.14)), time: time + 0.01,
                                              intensity: accent ? 0.45 : 0.32, sharpness: sharpness))
            }
        }
        return events.sorted { $0.time < $1.time }
    }
}
