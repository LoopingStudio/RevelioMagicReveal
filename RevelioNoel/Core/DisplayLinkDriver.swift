import QuartzCore
import UIKit

/// Avance le moteur à chaque rafraîchissement d'écran (jusqu'à 120 Hz).
final class DisplayLinkDriver: NSObject {
    private var link: CADisplayLink?
    private var lastTimestamp: CFTimeInterval?
    private let onTick: (Float) -> Void

    init(onTick: @escaping (Float) -> Void) {
        self.onTick = onTick
    }

    func start() {
        guard link == nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(step(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    func stop() {
        link?.invalidate()
        link = nil
        lastTimestamp = nil
    }

    @objc private func step(_ link: CADisplayLink) {
        let dt = lastTimestamp.map { link.timestamp - $0 } ?? 1.0 / 60
        lastTimestamp = link.timestamp
        onTick(Float(dt))
    }
}
