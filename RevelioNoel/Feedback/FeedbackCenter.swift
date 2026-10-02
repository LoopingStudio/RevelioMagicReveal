import Foundation

/// Retours haptiques et sonores. PROVISOIRE : ne fait rien, à remplacer par Core Haptics + sons procéduraux.
final class FeedbackCenter {
    var hapticsEnabled = true
    var soundEnabled = true

    func prepare() {}
    func reset() {}

    func scratchBegan(mask: MaskKind) {}
    /// `speed` : vitesse du doigt normalisée 0…1. `erodedAmount` : quantité effacée par cet échantillon.
    func scratchMoved(speed: Float, erodedAmount: Float, mask: MaskKind) {}
    func scratchEnded() {}

    /// Appelé à chaque tick quand le geste est « souffler » ; `strength` 0…1.
    func blow(strength: Float, mask: MaskKind) {}
    /// Une secousse détectée, `strength` 0…1.
    func shake(strength: Float, mask: MaskKind) {}
    /// Des morceaux viennent de tomber pendant une secousse (`amount` : cellules érodées cumulées).
    func chunk(amount: Float, mask: MaskKind) {}

    func revealCompleted(mask: MaskKind) {}
}
