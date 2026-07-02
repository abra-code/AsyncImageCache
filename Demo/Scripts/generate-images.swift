// Demo/Scripts/generate-images.swift
//
// Generates the demo's "local" images at BUILD time so no large binary blobs are committed to git. Run from
// the app target's pre-build phase (see project.yml) as:
//
//     xcrun --sdk macosx swift generate-images.swift <output-dir>
//
// It writes a handful of large-ish gradient JPEGs named "<name>-<w>x<h>.jpg" into <output-dir>. The width and
// height are encoded in the filename so the demo can pass CachedImage an intrinsicSize (proving zero-reflow
// layout for local images too). The step is IDEMPOTENT: an already-present file is skipped, so it costs
// nothing after the first build. Uses only Foundation + CoreGraphics + ImageIO, so it runs against the macOS
// host SDK regardless of whether the target being built is iOS or macOS.

import Foundation
import CoreGraphics
import ImageIO

let outDir = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : FileManager.default.currentDirectoryPath
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

struct Spec {
    let name: String
    let width: Int
    let height: Int
    let start: (CGFloat, CGFloat, CGFloat)
    let end: (CGFloat, CGFloat, CGFloat)
}

// A spread of aspect ratios and sizes: a couple of multi-megapixel sources (to show off-main decode/downscale)
// plus smaller ones. Colors vary so the placeholder previews are visibly distinct.
let specs: [Spec] = [
    Spec(name: "sunrise",  width: 2400, height: 1600, start: (0.98, 0.55, 0.15), end: (0.35, 0.10, 0.45)),
    Spec(name: "ocean",    width: 2000, height: 2000, start: (0.05, 0.35, 0.60), end: (0.02, 0.10, 0.25)),
    Spec(name: "forest",   width: 1600, height: 2400, start: (0.15, 0.55, 0.30), end: (0.03, 0.20, 0.12)),
    Spec(name: "dusk",     width: 3000, height: 1200, start: (0.25, 0.15, 0.45), end: (0.90, 0.45, 0.35)),
    Spec(name: "sand",     width: 1400, height: 1050, start: (0.95, 0.85, 0.60), end: (0.75, 0.55, 0.30)),
    Spec(name: "berry",    width: 1200, height: 1600, start: (0.70, 0.10, 0.35), end: (0.25, 0.05, 0.30)),
]

let space = CGColorSpaceCreateDeviceRGB()

for spec in specs {
    let file = (outDir as NSString).appendingPathComponent("\(spec.name)-\(spec.width)x\(spec.height).jpg")
    if FileManager.default.fileExists(atPath: file) {
        continue
    }
    guard let ctx = CGContext(data: nil, width: spec.width, height: spec.height, bitsPerComponent: 8,
                              bytesPerRow: 0, space: space,
                              bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
        continue
    }
    let colors = [CGColor(colorSpace: space, components: [spec.start.0, spec.start.1, spec.start.2, 1])!,
                  CGColor(colorSpace: space, components: [spec.end.0, spec.end.1, spec.end.2, 1])!] as CFArray
    if let gradient = CGGradient(colorsSpace: space, colors: colors, locations: [0, 1]) {
        ctx.drawLinearGradient(gradient, start: .zero,
                               end: CGPoint(x: spec.width, y: spec.height), options: [])
    }
    // A few translucent circles so the images are not flat gradients (and the placeholder grid has structure).
    let count = 9
    for i in 0..<count {
        let t = CGFloat(i) / CGFloat(count)
        let radius = CGFloat(min(spec.width, spec.height)) * (0.08 + 0.10 * t)
        let cx = CGFloat(spec.width) * (0.12 + 0.76 * t)
        let cy = CGFloat(spec.height) * (0.5 + 0.35 * sin(t * .pi * 3))
        ctx.setFillColor(CGColor(colorSpace: space, components: [1, 1, 1, 0.10])!)
        ctx.fillEllipse(in: CGRect(x: cx - radius, y: cy - radius, width: radius * 2, height: radius * 2))
    }
    guard let cg = ctx.makeImage() else {
        continue
    }
    let url = URL(fileURLWithPath: file)
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.jpeg" as CFString, 1, nil) else {
        continue
    }
    CGImageDestinationAddImage(dest, cg, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
    if CGImageDestinationFinalize(dest) {
        FileHandle.standardError.write(Data("generated \(file)\n".utf8))
    }
}

// One animated GIF, so the demo can show the isAnimated flag and the "render first frame" behavior. A hue
// sweep with a moving highlight - clearly animated, small (a few frames at a modest size).
func hueToRGB(_ hue: CGFloat) -> (CGFloat, CGFloat, CGFloat) {
    let h = (hue - floor(hue)) * 6
    let i = Int(h) % 6
    let f = h - floor(h)
    let s: CGFloat = 0.55, v: CGFloat = 0.90
    let p = v * (1 - s), q = v * (1 - s * f), t = v * (1 - s * (1 - f))
    switch i {
    case 0: return (v, t, p)
    case 1: return (q, v, p)
    case 2: return (p, v, t)
    case 3: return (p, q, v)
    case 4: return (t, p, v)
    default: return (v, p, q)
    }
}

let gifSide = 360
let gifFrames = 16
let gifFile = (outDir as NSString).appendingPathComponent("motion-\(gifSide)x\(gifSide).gif")
if !FileManager.default.fileExists(atPath: gifFile) {
    let gifURL = URL(fileURLWithPath: gifFile)
    if let dest = CGImageDestinationCreateWithURL(gifURL as CFURL, "com.compuserve.gif" as CFString,
                                                  gifFrames, nil) {
        CGImageDestinationSetProperties(dest, [kCGImagePropertyGIFDictionary:
            [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        let frameProps = [kCGImagePropertyGIFDictionary:
            [kCGImagePropertyGIFUnclampedDelayTime: 0.08]] as CFDictionary
        for f in 0..<gifFrames {
            let phase = CGFloat(f) / CGFloat(gifFrames)
            guard let ctx = CGContext(data: nil, width: gifSide, height: gifSide, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
                continue
            }
            let bg = hueToRGB(phase)
            ctx.setFillColor(CGColor(colorSpace: space, components: [bg.0, bg.1, bg.2, 1])!)
            ctx.fill(CGRect(x: 0, y: 0, width: gifSide, height: gifSide))
            let radius = CGFloat(gifSide) * 0.18
            let cx = CGFloat(gifSide) * (0.5 + 0.3 * cos(phase * 2 * .pi))
            let cy = CGFloat(gifSide) * (0.5 + 0.3 * sin(phase * 2 * .pi))
            ctx.setFillColor(CGColor(colorSpace: space, components: [1, 1, 1, 0.85])!)
            ctx.fillEllipse(in: CGRect(x: cx - radius, y: cy - radius, width: radius * 2, height: radius * 2))
            if let frame = ctx.makeImage() {
                CGImageDestinationAddImage(dest, frame, frameProps)
            }
        }
        if CGImageDestinationFinalize(dest) {
            FileHandle.standardError.write(Data("generated \(gifFile)\n".utf8))
        }
    }
}
