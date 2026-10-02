#!/bin/zsh
# Génère la vidéo d'exemple (RevelioMagicReveal/Resources/noel-exemple.mp4) à partir du dessin de
# la photo d'exemple : guirlandes qui scintillent, neige qui tombe, léger zoom, « Joyeux Noël ».
# Usage : scripts/make-sample-video.sh
set -euo pipefail
ROOT="${0:A:h}/.."
WORK=$(mktemp -d)
{
  cat <<'EOF'
import AVFoundation
import CoreGraphics
import CoreText
import Foundation

struct SeededRandom: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt32) { state = UInt64(seed) &+ 0x9E37_79B9_7F4A_7C15 }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    mutating func float(_ range: ClosedRange<Float>) -> Float { Float.random(in: range, using: &self) }
}
EOF
  # Le dessin de la photo d'exemple, sans UIKit ni la fonction de rendu iOS.
  sed -e '/^import UIKit/d' -e 's/private static func/static func/' "$ROOT/RevelioMagicReveal/App/SamplePhoto.swift" \
    | awk '/static func render\(\) -> UIImage \{/{skip=1} skip&&/^    \}$/{skip=0; next} !skip'
  cat <<'EOF'

let width = 1080, height = 1440, fps: Int32 = 30, seconds = 6.0
let frameCount = Int(seconds * Double(fps))
let space = CGColorSpace(name: CGColorSpace.sRGB)!
func ctx(_ w: Int, _ h: Int) -> CGContext {
    let c = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
    c.translateBy(x: 0, y: CGFloat(h)); c.scaleBy(x: 1, y: -1)   // origine en haut à gauche, comme UIKit
    return c
}

// Décor fixe, dessiné une fois au format de la photo (1200 × 1600).
let base: CGImage = {
    let c = ctx(1200, 1600)
    var rng = SeededRandom(seed: 2026)
    SamplePhoto.drawBackground(c)
    SamplePhoto.drawBokeh(c, rng: &rng)
    SamplePhoto.drawFloorGlow(c)
    SamplePhoto.drawTree(c, rng: &rng)
    SamplePhoto.drawGifts(c)
    return c.makeImage()!
}()

// Positions des ampoules des guirlandes (même formule que drawTree).
var lights: [(CGPoint, Double)] = []
var phaseRng = SeededRandom(seed: 77)
for row in 0..<7 {
    let y0 = 470 + CGFloat(row) * 125, halfWidth = 120 + CGFloat(row) * 55
    for i in 0...18 {
        let t = CGFloat(i) / 18
        let p = CGPoint(x: 600 - halfWidth + t * halfWidth * 2, y: y0 + sin(t * .pi) * 60 + CGFloat(row % 2 == 0 ? 0 : -20))
        lights.append((p, Double(phaseRng.float(0...6.28))))
    }
}
struct Flake { var x: Double, phase: Double, speed: Double, size: Double, drift: Double, alpha: Double }
var flakeRng = SeededRandom(seed: 5)
let flakes = (0..<140).map { _ in
    Flake(x: Double(flakeRng.float(0...1200)), phase: Double(flakeRng.float(0...1)), speed: Double(flakeRng.float(0.10...0.22)),
          size: Double(flakeRng.float(3...9)), drift: Double(flakeRng.float(10...40)), alpha: Double(flakeRng.float(0.35...0.9)))
}

func smooth(_ x: Double) -> Double { let t = min(max(x, 0), 1); return t * t * (3 - 2 * t) }

func drawFrame(_ c: CGContext, time t: Double) {
    // Toutes les coordonnées en espace photo 1200 × 1600, ramenées à 1080 × 1440.
    c.saveGState()
    c.scaleBy(x: 0.9, y: 0.9)
    // Léger zoom vers l'étoile, qui ne démarre qu'après la première image.
    let zoom = 1 + 0.06 * smooth(t / seconds)
    c.translateBy(x: 600, y: 700); c.scaleBy(x: zoom, y: zoom); c.translateBy(x: -600, y: -700)
    c.saveGState(); c.translateBy(x: 0, y: 1600); c.scaleBy(x: 1, y: -1)
    c.draw(base, in: CGRect(x: 0, y: 0, width: 1200, height: 1600))
    c.restoreGState()

    // Guirlandes : chaque ampoule pulse à son rythme.
    for (p, phase) in lights {
        let a = 0.45 * max(0, sin(t * 3.1 + phase))
        guard a > 0.02 else { continue }
        let g = CGGradient(colorsSpace: space, colors: [CGColor(red: 1, green: 0.93, blue: 0.7, alpha: a), CGColor(red: 1, green: 0.8, blue: 0.5, alpha: 0)] as CFArray, locations: [0, 1])!
        c.drawRadialGradient(g, startCenter: p, startRadius: 0, endCenter: p, endRadius: 30, options: [])
    }
    // L'étoile respire.
    let star = CGPoint(x: 600, y: 285)
    let pulse = 0.35 + 0.25 * sin(t * 2.2)
    let sg = CGGradient(colorsSpace: space, colors: [CGColor(red: 1, green: 0.9, blue: 0.55, alpha: pulse), CGColor(red: 1, green: 0.8, blue: 0.4, alpha: 0)] as CFArray, locations: [0, 1])!
    c.drawRadialGradient(sg, startCenter: star, startRadius: 0, endCenter: star, endRadius: 220, options: [])
    c.restoreGState()

    c.saveGState(); c.scaleBy(x: 0.9, y: 0.9)
    // Neige.
    for f in flakes {
        let y = ((f.phase + t * f.speed).truncatingRemainder(dividingBy: 1)) * 1700 - 50
        let x = f.x + sin(t * 0.9 + f.phase * 12) * f.drift
        c.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: f.alpha))
        c.fillEllipse(in: CGRect(x: x - f.size / 2, y: y - f.size / 2, width: f.size, height: f.size))
    }
    SamplePhoto.drawVignette(c)
    // « Joyeux Noël » apparaît en haut.
    let reveal = smooth((t - 1.4) / 1.1)
    if reveal > 0 {
        let font = CTFontCreateWithName("Georgia-Bold" as CFString, 104, nil)
        let attrs: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(red: 1, green: 0.95, blue: 0.85, alpha: reveal),
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: "Joyeux Noël", attributes: attrs))
        let bounds = CTLineGetBoundsWithOptions(line, .useOpticalBounds)
        c.saveGState()
        c.setShadow(offset: .zero, blur: 28, color: CGColor(red: 1, green: 0.8, blue: 0.4, alpha: 0.8 * reveal))
        c.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        c.textPosition = CGPoint(x: 600 - bounds.width / 2, y: 150 + 20 * (1 - reveal))
        CTLineDraw(line, c)
        c.restoreGState()
    }
    c.restoreGState()
}

let out = URL(fileURLWithPath: CommandLine.arguments[1])
try? FileManager.default.removeItem(at: out)
let writer = try AVAssetWriter(outputURL: out, fileType: .mp4)
let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
    AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height,
    AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 4_000_000, AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel],
])
let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
])
writer.add(input)
writer.startWriting(); writer.startSession(atSourceTime: .zero)
for i in 0..<frameCount {
    while !input.isReadyForMoreMediaData { usleep(1000) }
    var buffer: CVPixelBuffer?
    CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &buffer)
    let pb = buffer!
    CVPixelBufferLockBaseAddress(pb, [])
    let c = CGContext(data: CVPixelBufferGetBaseAddress(pb), width: width, height: height, bitsPerComponent: 8,
                      bytesPerRow: CVPixelBufferGetBytesPerRow(pb), space: space,
                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
    c.translateBy(x: 0, y: CGFloat(height)); c.scaleBy(x: 1, y: -1)
    drawFrame(c, time: Double(i) / Double(fps))
    CVPixelBufferUnlockBaseAddress(pb, [])
    adaptor.append(pb, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: fps))
}
input.markAsFinished()
let done = DispatchSemaphore(value: 0)
writer.finishWriting { done.signal() }
done.wait()
print(writer.status == .completed ? "vidéo écrite : \(out.path)" : "échec : \(String(describing: writer.error))")
EOF
} > "$WORK/main.swift"
swiftc -O "$WORK/main.swift" -o "$WORK/make-video" 2>&1 | grep "error:" || true
"$WORK/make-video" "$ROOT/RevelioMagicReveal/Resources/noel-exemple.mp4"
rm -rf "$WORK"
