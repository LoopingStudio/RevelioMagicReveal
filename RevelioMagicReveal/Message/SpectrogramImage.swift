import CoreGraphics
import Foundation

/// Spectrogramme d'un message précalculé en image : une colonne par trame, une ligne par bande (aigus
/// en haut). Le dessiner en rectangles coûterait des dizaines de milliers de formes par image.
nonisolated enum SpectrogramImage {
    /// Nuit → baie → or → crème.
    private static let stops: [(position: Float, rgb: SIMD3<Float>)] = [
        (0, SIMD3(0.04, 0.07, 0.16)),
        (0.4, SIMD3(0.55, 0.08, 0.14)),
        (0.72, SIMD3(0.86, 0.66, 0.28)),
        (1, SIMD3(0.98, 0.95, 0.88)),
    ]

    static func make(_ analysis: AudioMessageAnalysis) -> CGImage? {
        let width = analysis.frameCount, height = AudioMessageAnalysis.bandCount
        guard width > 0 else { return nil }
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        for x in 0..<width {
            for band in 0..<height {
                let value = pow(analysis.bands[x * height + band], 1.2)
                let rgb = color(value)
                let offset = ((height - 1 - band) * width + x) * 4
                pixels[offset] = UInt8(rgb.x * 255)
                pixels[offset + 1] = UInt8(rgb.y * 255)
                pixels[offset + 2] = UInt8(rgb.z * 255)
            }
        }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    static func color(_ value: Float) -> SIMD3<Float> {
        let v = min(max(value, 0), 1)
        for i in 1..<stops.count where v <= stops[i].position {
            let a = stops[i - 1], b = stops[i]
            let f = (v - a.position) / (b.position - a.position)
            return a.rgb + (b.rgb - a.rgb) * f
        }
        return stops[stops.count - 1].rgb
    }
}
