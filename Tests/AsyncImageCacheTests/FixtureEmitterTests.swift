// Tests/AsyncImageCacheTests/FixtureEmitterTests.swift
//
// Stage F - cross-platform parity fixtures. This is the Swift half of a shared regression net: it emits a small
// set of canonical image files (Fixtures/images/) plus their expected decoded values (Fixtures/expected/*.json),
// and the Android instrumented suite (FixtureParityInstrumentedTest.kt) consumes THE SAME files and asserts the
// Kotlin ImageProcessing produces the same values. The JSON is the ground truth linking the two implementations:
// any future behavior change on either side must regenerate the fixtures, forcing a conscious cross-platform review.
//
// Two entry points:
//   - testEmitFixtures - GATED behind AIC_EMIT_FIXTURES=1. Regenerates images + JSON in the repo. Run it only when
//     intentionally (re)producing the fixture set: `AIC_EMIT_FIXTURES=1 swift test --filter testEmitFixtures`.
//   - testFixturesMatchSwiftReference - runs in every `swift test`. Reads the committed fixtures and asserts the
//     CURRENT Swift ImageProcessing still matches them, so the fixtures double as the Swift regression net.
//
// Field-by-field parity contract (each fixture's JSON carries only the fields that apply to it):
//   animated        - exact. ImageProcessing.isAnimated(data:) vs the sniffer on Android.
//   headerPixelSize - exact. Decode-free size AS DISPLAYED (EXIF 5-8 axes swapped), the relaunch-without-decode path.
//   variant         - exact. The downscale geometry at a clean-halving targetWidth (integer, no rounding ambiguity).
//   dominantColor   - within colorTolerance. Different scalers (CoreGraphics vs createScaledBitmap) differ slightly.
//   grid            - within colorTolerance, per cell. Only for fixtures whose decode orientation is unambiguous.

import XCTest
import Foundation
import CoreGraphics
import ImageIO
@testable import AsyncImageCache

final class FixtureEmitterTests: XCTestCase {

    // MARK: - Fixture set

    // A canonical fixture. `checkColors` is false for images whose DECODED orientation differs across platforms
    // (EXIF-rotated) or whose palette quantization makes per-cell color comparison unstable - those still assert
    // size / animated / variant, which are exact.
    private struct Fixture {
        let name: String
        let file: String
        let data: Data
        let animated: Bool
        let displayWidth: Int
        let displayHeight: Int
        let variantTargetWidth: Int
        let checkColors: Bool
        let colorTolerance: Int
    }

    private func fixtures() -> [Fixture] {
        // Solid sRGB (0.2, 0.4, 0.8) ~ (51, 102, 204), opaque PNG. The canonical dominant-color / grid case.
        let solid = encodePNG(rgbImage(width: 48, height: 48, r: 0.2, g: 0.4, b: 0.8, a: 1, p3: false))
        // Top red / bottom blue, from a raw top-down buffer: pins grid row 0 == TOP on both platforms.
        let topBottom = encodePNG(topBottomImage(size: 24, top: (220, 20, 20), bottom: (20, 20, 220)))
        // A diagonal-gradient JPEG - a realistic lossy photo; dominant/grid compared with a wider tolerance.
        let gradient = encodeJPEG(gradientImage(width: 200, height: 150), quality: 0.85, orientation: nil)
        // A 100x40 JPEG tagged EXIF orientation 6 (90 CW): DISPLAYED size is 40x100. Colors skipped (decode
        // orientation is platform-specific on the emitter host); the header-swap + variant geometry are exact.
        let exif6 = encodeJPEG(gradientImage(width: 100, height: 40), quality: 0.85, orientation: 6)
        // A 4-frame GIF (shifting color): must sniff as animated on both sides.
        let animatedGif = encodeGIF(frames: (0..<4).map { f in
            rgbImage(width: 24, height: 24, r: Double(f) / 4.0, g: 0.4, b: 0.6, a: 1, p3: false)
        })
        // A single-frame GIF: must sniff as NOT animated.
        let staticGif = encodeGIF(frames: [rgbImage(width: 24, height: 24, r: 0.16, g: 0.70, b: 0.35, a: 1, p3: false)])
        // A Display P3 image: exercises wide-gamut decode. In-gamut color so sRGB and P3 sampling agree closely;
        // colors compared with a generous tolerance (gamut mapping still differs by a few units).
        let p3 = encodePNG(rgbImage(width: 60, height: 60, r: 0.85, g: 0.35, b: 0.30, a: 1, p3: true))

        return [
            Fixture(name: "solid-blue", file: "solid-blue.png", data: solid,
                    animated: false, displayWidth: 48, displayHeight: 48, variantTargetWidth: 24,
                    checkColors: true, colorTolerance: 8),
            Fixture(name: "top-bottom", file: "top-bottom.png", data: topBottom,
                    animated: false, displayWidth: 24, displayHeight: 24, variantTargetWidth: 12,
                    checkColors: true, colorTolerance: 12),
            Fixture(name: "gradient", file: "gradient.jpg", data: gradient,
                    animated: false, displayWidth: 200, displayHeight: 150, variantTargetWidth: 100,
                    checkColors: true, colorTolerance: 16),
            Fixture(name: "exif-rotated", file: "exif-rotated.jpg", data: exif6,
                    animated: false, displayWidth: 40, displayHeight: 100, variantTargetWidth: 20,
                    checkColors: false, colorTolerance: 0),
            Fixture(name: "animated", file: "animated.gif", data: animatedGif,
                    animated: true, displayWidth: 24, displayHeight: 24, variantTargetWidth: 12,
                    checkColors: false, colorTolerance: 0),
            Fixture(name: "static-gif", file: "static.gif", data: staticGif,
                    animated: false, displayWidth: 24, displayHeight: 24, variantTargetWidth: 12,
                    checkColors: true, colorTolerance: 24),
            Fixture(name: "wide-p3", file: "wide-p3.png", data: p3,
                    animated: false, displayWidth: 60, displayHeight: 60, variantTargetWidth: 30,
                    checkColors: true, colorTolerance: 32),
        ]
    }

    // MARK: - Emit (gated)

    func testEmitFixtures() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["AIC_EMIT_FIXTURES"] == "1",
                          "Set AIC_EMIT_FIXTURES=1 to (re)generate Fixtures/. Skipped in normal runs.")

        let imagesDir = fixturesDir().appendingPathComponent("images", isDirectory: true)
        let expectedDir = fixturesDir().appendingPathComponent("expected", isDirectory: true)
        try FileManager.default.createDirectory(at: imagesDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: expectedDir, withIntermediateDirectories: true)

        for fixture in fixtures() {
            try fixture.data.write(to: imagesDir.appendingPathComponent(fixture.file))
            let json = try expectedJSON(for: fixture)
            let data = try JSONSerialization.data(withJSONObject: json,
                                                  options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            try data.write(to: expectedDir.appendingPathComponent("\(fixture.name).json"))
        }
        print("Emitted \(fixtures().count) fixtures to \(fixturesDir().path)")
    }

    // MARK: - Verify (always runs)

    // The committed fixtures must still describe what the current Swift ImageProcessing produces. This is both a
    // Swift regression guard and a check that the emitter and the reader agree on the same computation.
    func testFixturesMatchSwiftReference() throws {
        let expectedDir = fixturesDir().appendingPathComponent("expected", isDirectory: true)
        let imagesDir = fixturesDir().appendingPathComponent("images", isDirectory: true)
        guard FileManager.default.fileExists(atPath: expectedDir.path) else {
            throw XCTSkip("No Fixtures/expected yet - run testEmitFixtures with AIC_EMIT_FIXTURES=1 first.")
        }

        for fixture in fixtures() {
            let url = expectedDir.appendingPathComponent("\(fixture.name).json")
            let json = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
            let bytes = try Data(contentsOf: imagesDir.appendingPathComponent(fixture.file))

            // animated - exact.
            XCTAssertEqual(ImageProcessing.isAnimated(data: bytes), json["animated"] as! Bool,
                           "\(fixture.name): animated flag")

            // headerPixelSize - exact (decode-free, EXIF-swapped).
            let (hw, hh) = try XCTUnwrap(headerDisplaySize(bytes), "\(fixture.name): header size")
            let expectedHeader = json["headerPixelSize"] as! [String: Any]
            XCTAssertEqual(hw, expectedHeader["width"] as! Int, "\(fixture.name): header width")
            XCTAssertEqual(hh, expectedHeader["height"] as! Int, "\(fixture.name): header height")

            // variant geometry - exact.
            let expectedVariant = json["variant"] as! [String: Any]
            let target = expectedVariant["targetWidth"] as! Int
            let (vw, vh) = variantGeometry(width: hw, height: hh, targetWidth: target)
            XCTAssertEqual(vw, expectedVariant["width"] as! Int, "\(fixture.name): variant width")
            XCTAssertEqual(vh, expectedVariant["height"] as! Int, "\(fixture.name): variant height")

            // colors - within tolerance, only where the decode orientation is unambiguous.
            guard fixture.checkColors, let gridJSON = json["grid"] as? [String: Any] else { continue }
            let image = try XCTUnwrap(PlatformImage(data: bytes), "\(fixture.name): decode")
            let placeholder = try XCTUnwrap(ImageProcessing.placeholder(of: image), "\(fixture.name): placeholder")
            let tolerance = json["colorTolerance"] as! Int

            let cells = gridJSON["cells"] as! [[Int]]
            XCTAssertEqual(placeholder.cells.count, cells.count, "\(fixture.name): cell count")
            for (i, cell) in placeholder.cells.enumerated() {
                assertColorClose(cell, cells[i], tolerance: tolerance, label: "\(fixture.name) cell \(i)")
            }
            let dom = json["dominantColor"] as! [Int]
            assertColorClose(placeholder.dominantColor, dom, tolerance: tolerance, label: "\(fixture.name) dominant")
        }
    }

    // MARK: - Expected-value computation (source of truth)

    private func expectedJSON(for fixture: Fixture) throws -> [String: Any] {
        let (hw, hh) = try XCTUnwrap(headerDisplaySize(fixture.data), "\(fixture.name): header size")
        XCTAssertEqual(hw, fixture.displayWidth, "\(fixture.name): declared width vs header")
        XCTAssertEqual(hh, fixture.displayHeight, "\(fixture.name): declared height vs header")
        XCTAssertEqual(ImageProcessing.isAnimated(data: fixture.data), fixture.animated, "\(fixture.name): animated")

        let (vw, vh) = variantGeometry(width: hw, height: hh, targetWidth: fixture.variantTargetWidth)
        var json: [String: Any] = [
            "name": fixture.name,
            "file": fixture.file,
            "animated": fixture.animated,
            "headerPixelSize": ["width": hw, "height": hh],
            "variant": ["targetWidth": fixture.variantTargetWidth, "width": vw, "height": vh],
        ]

        if fixture.checkColors {
            let image = try XCTUnwrap(PlatformImage(data: fixture.data), "\(fixture.name): decode")
            let placeholder = try XCTUnwrap(ImageProcessing.placeholder(of: image), "\(fixture.name): placeholder")
            json["colorTolerance"] = fixture.colorTolerance
            json["dominantColor"] = colorArray(placeholder.dominantColor)
            json["grid"] = [
                "dimension": placeholder.dimension,
                "cells": placeholder.cells.map { colorArray($0) },
            ]
        }
        return json
    }

    // The Swift-side variant sizing rule, matched byte-for-byte to ImageProcessing.variant and the Kotlin port:
    // cap the width at targetWidth (never upscale); height scales proportionally with round-half-away rounding.
    private func variantGeometry(width: Int, height: Int, targetWidth: Int) -> (Int, Int) {
        guard targetWidth > 0, width > targetWidth else { return (width, height) }
        let scale = Double(targetWidth) / Double(width)
        return (Int((Double(width) * scale).rounded()), Int((Double(height) * scale).rounded()))
    }

    // MARK: - Header size (decode-free, EXIF-swapped) - mirrors Kotlin ImageProcessing.headerPixelSize

    private func headerDisplaySize(_ data: Data) -> (Int, Int)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = props[kCGImagePropertyPixelWidth] as? Int,
              let height = props[kCGImagePropertyPixelHeight] as? Int else {
            return nil
        }
        let orientation = (props[kCGImagePropertyOrientation] as? Int) ?? 1
        let swap = orientation >= 5 && orientation <= 8   // 5..8 rotate by +/-90 (axes swapped)
        return swap ? (height, width) : (width, height)
    }

    // MARK: - Color helpers

    private func colorArray(_ c: ImageColor) -> [Int] {
        [Int(c.red), Int(c.green), Int(c.blue), Int(c.alpha)]
    }

    private func assertColorClose(_ actual: ImageColor, _ expected: [Int], tolerance: Int, label: String) {
        let got = [Int(actual.red), Int(actual.green), Int(actual.blue), Int(actual.alpha)]
        for ch in 0..<4 {
            XCTAssertLessThanOrEqual(abs(got[ch] - expected[ch]), tolerance,
                                     "\(label) channel \(ch): got \(got[ch]) expected \(expected[ch])")
        }
    }

    // MARK: - Deterministic image generation (ImageIO only - no NSImage/UIImage scale artifacts)

    private func rgbImage(width: Int, height: Int, r: Double, g: Double, b: Double, a: Double, p3: Bool) -> CGImage {
        let space = (p3 ? CGColorSpace(name: CGColorSpace.displayP3) : CGColorSpace(name: CGColorSpace.sRGB))
            ?? CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(red: r, green: g, blue: b, alpha: a)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage()!
    }

    // Raw top-down RGBA buffer (row 0 == top): unambiguous orientation for the grid-is-top-down check.
    private func topBottomImage(size: Int, top: (UInt8, UInt8, UInt8), bottom: (UInt8, UInt8, UInt8)) -> CGImage {
        var buf = [UInt8](repeating: 0, count: size * size * 4)
        for row in 0..<size {
            for col in 0..<size {
                let i = (row * size + col) * 4
                let c = row < size / 2 ? top : bottom
                buf[i] = c.0; buf[i + 1] = c.1; buf[i + 2] = c.2; buf[i + 3] = 255
            }
        }
        let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let provider = CGDataProvider(data: Data(buf) as CFData)!
        return CGImage(width: size, height: size, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: size * 4,
                       space: space, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    }

    private func gradientImage(width: Int, height: Int) -> CGImage {
        let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        let colors = [CGColor(srgbRed: 0.10, green: 0.20, blue: 0.55, alpha: 1),
                      CGColor(srgbRed: 0.95, green: 0.65, blue: 0.20, alpha: 1)] as CFArray
        let gradient = CGGradient(colorsSpace: space, colors: colors, locations: [0, 1])!
        ctx.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: width, y: height), options: [])
        return ctx.makeImage()!
    }

    private func encodePNG(_ image: CGImage) -> Data {
        let out = NSMutableData()
        let dest = CGImageDestinationCreateWithData(out, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, image, nil)
        _ = CGImageDestinationFinalize(dest)
        return out as Data
    }

    private func encodeJPEG(_ image: CGImage, quality: Double, orientation: Int?) -> Data {
        let out = NSMutableData()
        let dest = CGImageDestinationCreateWithData(out, "public.jpeg" as CFString, 1, nil)!
        var props: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: quality]
        if let orientation { props[kCGImagePropertyOrientation] = orientation }
        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        _ = CGImageDestinationFinalize(dest)
        return out as Data
    }

    private func encodeGIF(frames: [CGImage]) -> Data {
        let out = NSMutableData()
        let dest = CGImageDestinationCreateWithData(out, "com.compuserve.gif" as CFString, frames.count, nil)!
        CGImageDestinationSetProperties(dest, [kCGImagePropertyGIFDictionary:
            [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        for frame in frames {
            CGImageDestinationAddImage(dest, frame, [kCGImagePropertyGIFDictionary:
                [kCGImagePropertyGIFUnclampedDelayTime: 0.1]] as CFDictionary)
        }
        _ = CGImageDestinationFinalize(dest)
        return out as Data
    }

    // MARK: - Repo location

    // Fixtures/ lives at the package root: this file is Tests/AsyncImageCacheTests/FixtureEmitterTests.swift,
    // so three parent hops up from #filePath reach the root regardless of the checkout location.
    private func fixturesDir() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // AsyncImageCacheTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // package root
            .appendingPathComponent("Fixtures", isDirectory: true)
    }
}
