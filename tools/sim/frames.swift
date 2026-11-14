// Turns a simulator recording into contact sheets, one per moment the UI test marked (a book opening, closing, a
// tab change…). A UI test's tap lands a second or more after its mark, so the sheet starts where the screen first
// changes after the mark: 36 frames at 30 a second (1.2 s) in a 6×6 grid, the size of one screenshot.
// Usage: swift tools/sim/frames.swift <video.mp4> <record-start-seconds-file> <marks.txt> <out dir>
import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let args = CommandLine.arguments
guard args.count >= 5 else { print("usage: frames.swift video start marks outdir"); exit(1) }
let video = URL(fileURLWithPath: args[1])
let start = Double((try? String(contentsOfFile: args[2], encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "") ?? 0
let marks = ((try? String(contentsOfFile: args[3], encoding: .utf8)) ?? "").split(separator: "\n").compactMap { line -> (String, Double)? in
    let p = line.split(separator: " ")
    guard p.count == 2, let t = Double(p[1]) else { return nil }
    return (String(p[0]), t)
}
let out = URL(fileURLWithPath: args[4], isDirectory: true)
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

let asset = AVURLAsset(url: video)
let gen = AVAssetImageGenerator(asset: asset)
gen.appliesPreferredTrackTransform = true
gen.requestedTimeToleranceBefore = .zero
gen.requestedTimeToleranceAfter = .zero
gen.maximumSize = CGSize(width: 390, height: 844)
let duration = CMTimeGetSeconds(asset.duration)
print("video", duration, "s, start", start, ",", marks.count, "marks")

func frame(_ t: Double) -> CGImage? {
    try? gen.copyCGImage(at: CMTime(seconds: max(0, min(duration - 0.02, t)), preferredTimescale: 600), actualTime: nil)
}

/// A tiny grey copy of a frame (40 × 86), to compare frames.
func thumb(_ img: CGImage) -> [UInt8] {
    let w = 40, h = 86
    var px = [UInt8](repeating: 0, count: w * h)
    let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w, space: CGColorSpaceCreateDeviceGray(),
                        bitmapInfo: CGImageAlphaInfo.none.rawValue)!
    ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
    return px
}

func diff(_ a: [UInt8], _ b: [UInt8]) -> Double {
    var s = 0
    for i in 0..<min(a.count, b.count) { s += abs(Int(a[i]) - Int(b[i])) }
    return Double(s) / Double(a.count)
}

let cols = 6, rows = 6, tileW = 195, tileH = 422
for (k, m) in marks.enumerated() {
    let rel = m.1 - start
    guard rel > -1, rel < duration, let first = frame(rel) else { print("skip", m.0, rel); continue }
    // where the screen starts to change: up to 6 seconds after the mark, every 1/15 s
    let base = thumb(first)
    var at = rel
    var t = rel
    while t < rel + 6 {
        t += 1.0 / 15
        guard let f = frame(t) else { break }
        if diff(base, thumb(f)) > 2.5 { at = t - 1.0 / 15; break }
    }
    let ctx = CGContext(data: nil, width: cols * tileW, height: rows * tileH, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(CGColor(red: 1, green: 0, blue: 1, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: cols * tileW, height: rows * tileH))
    for i in 0..<(cols * rows) {
        guard let img = frame(at + Double(i) / 30) else { continue }
        let c = i % cols, r = i / cols
        // CoreGraphics draws from the bottom: the first frame goes top left
        ctx.draw(img, in: CGRect(x: c * tileW, y: (rows - 1 - r) * tileH, width: tileW - 2, height: tileH - 2))
    }
    guard let sheet = ctx.makeImage() else { continue }
    let name = String(format: "%02d-%@.png", k + 1, m.0)
    let dest = CGImageDestinationCreateWithURL(out.appendingPathComponent(name) as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, sheet, nil)
    CGImageDestinationFinalize(dest)
    print("sheet", name, String(format: "mark %.2f, change at +%.2f s", rel, at - rel))
}
