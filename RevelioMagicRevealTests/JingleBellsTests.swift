import Foundation
import Testing
@testable import RevelioMagicReveal

struct JingleBellsTests {
    @Test func melodyFillsEightBarsWithoutOverlap() {
        let notes = JingleBells.melody
        // 8 mesures de 4 temps, jusqu'au « hey ! ».
        #expect(notes.last.map { $0.beat + $0.beats } == 32)
        for (current, next) in zip(notes, notes.dropFirst()) {
            #expect(current.beat + current.beats <= next.beat + 1e-9, "chevauchement au temps \(current.beat)")
        }
        #expect(abs(JingleBells.duration - 32 * JingleBells.beatDuration) < 1e-9)
    }

    @Test func everyNoteGetsAnAttackAtItsTime() {
        let events = HapticScripts.melody()
        let attacks = events.filter { $0.kind == .transient }
        #expect(attacks.count == JingleBells.melody.count)
        for (attack, note) in zip(attacks, JingleBells.melody) {
            #expect(abs(attack.time - JingleBells.time(of: note)) < 1e-9)
        }
        #expect(events.map(\.time) == events.map(\.time).sorted())
    }

    @Test func higherNotesFeelSharperAndDownbeatsStronger() {
        let attacks = HapticScripts.melody().filter { $0.kind == .transient }
        let notes = JingleBells.melody
        let low = notes.firstIndex { $0.frequency == notes.map(\.frequency).min() }!
        let high = notes.firstIndex { $0.frequency == notes.map(\.frequency).max() }!
        #expect(attacks[high].sharpness > attacks[low].sharpness)
        // Premier temps de la mesure 1 (accent) contre deuxième temps.
        #expect(attacks[0].intensity > attacks[1].intensity)
    }

    @Test func longNotesRingAndFadeOut() {
        let events = HapticScripts.melody()
        let whole = JingleBells.melody.first { $0.beats == 4 }!
        let start = JingleBells.time(of: whole)
        let ring = events.filter {
            if case .continuous = $0.kind { return $0.time > start && $0.time < start + 4 * JingleBells.beatDuration }
            return false
        }
        #expect(ring.count >= 3)
        #expect(ring.map(\.intensity) == ring.map(\.intensity).sorted(by: >))
    }

    @Test func glockenspielRenditionCoversTheWholeMelody() {
        let duration = JingleBells.duration + 2
        let samples = ChimeSynth.render(score: JingleBells.audioScore, duration: duration)
        #expect(samples.frameCount == Int(duration * ChimeSynth.sampleRate))
        // Le « hey » final sonne bien : de l'énergie juste après sa frappe.
        let hey = Int(JingleBells.time(of: JingleBells.melody.last!) * ChimeSynth.sampleRate)
        let window = samples.left[hey..<(hey + 4800)]
        #expect(window.map(abs).max() ?? 0 > 0.05)
    }
}
