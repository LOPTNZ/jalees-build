// Turns a simulator recording into contact sheets, one per moment the UI test marked (a book opening, closing, a
// tab change…): 36 frames over 2.1 seconds in a 6×6 grid, the size of one screenshot, so a transition can be looked
// at frame by frame. Usage: swift tools/sim/frames.swift <video.mp4> <record-start-seconds-file> <marks.txt> <out dir>
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

let cols = 6, rows = 6, tileW = 195, tileH = 422
for (k, m) in marks.enumerated() {
    let rel = m.1 - start
    guard rel > -1, rel < duration else { print("skip", m.0, rel); continue }
    let ctx = CGContext(data: nil, width: cols * tileW, height: rows * tileH, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(CGColor(red: 1, green: 0, blue: 1, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: cols * tileW, height: rows * tileH))
    for i in 0..<(cols * rows) {
        let t = max(0, min(duration - 0.05, rel - 0.1 + Double(i) * (2.1 / Double(cols * rows))))
        guard let img = try? gen.copyCGImage(at: CMTime(seconds: t, preferredTimescale: 600), actualTime: nil) else { continue }
        let c = i % cols, r = i / cols
        // CoreGraphics draws from the bottom: the first frame goes top left
        ctx.draw(img, in: CGRect(x: c * tileW, y: (rows - 1 - r) * tileH, width: tileW - 2, height: tileH - 2))
    }
    guard let sheet = ctx.makeImage() else { continue }
    let name = String(format: "%02d-%@.png", k + 1, m.0)
    let dest = CGImageDestinationCreateWithURL(out.appendingPathComponent(name) as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, sheet, nil)
    CGImageDestinationFinalize(dest)
    print("sheet", name, "at", String(format: "%.2f", rel))
}
