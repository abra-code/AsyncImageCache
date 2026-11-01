// Tests/AsyncImageCacheTests/Linux/LinuxImageProcessingTests.swift
//
// The Linux image pipeline (ImageProcessing+Linux.swift, AnimatedImageDetector.swift). The shared fixtures
// (Fixtures/, emitted by the Swift tests on Apple platforms and read by the Android suite too) pin the animated
// flag, the header size, the variant geometry and the placeholder colors to the same values on every platform.

import XCTest
import Foundation
import CAsyncImageCacheGtk
@testable import AsyncImageCache

final class LinuxImageProcessingTests: XCTestCase {

    // MARK: - Shared fixtures

    private struct Expected: Decodable {
        struct Size: Decodable {
            let width: Int
            let height: Int
        }
        struct Variant: Decodable {
            let targetWidth: Int
            let width: Int
            let height: Int
        }
        struct Grid: Decodable {
            let dimension: Int
            let cells: [[Int]]
        }
        let name: String
        let file: String
        let animated: Bool
        let headerPixelSize: Size
        let variant: Variant
        let colorTolerance: Int?
        let dominantColor: [Int]?
        let grid: Grid?
    }

    func testFixturesMatchSharedExpectations() throws {
        let expectedDir = fixturesDir().appendingPathComponent("expected", isDirectory: true)
        let imagesDir = fixturesDir().appendingPathComponent("images", isDirectory: true)
        let names = try FileManager.default.contentsOfDirectory(atPath: expectedDir.path)
            .filter { $0.hasSuffix(".json") }.sorted()
        XCTAssertEqual(names.count, 7, "the fixture set")
        for name in names {
            let json = try Data(contentsOf: expectedDir.appendingPathComponent(name))
            let expected = try JSONDecoder().decode(Expected.self, from: json)
            let path = imagesDir.appendingPathComponent(expected.file).path
            let bytes = try Data(contentsOf: URL(fileURLWithPath: path))
            let label = expected.name

            XCTAssertEqual(ImageProcessing.isAnimated(data: bytes), expected.animated, "\(label): animated")

            let header = try XCTUnwrap(ImageProcessing.headerPixelSize(atPath: path), "\(label): header size")
            XCTAssertEqual(header, size(expected.headerPixelSize), "\(label): header size")

            // The decode bakes in the orientation, so its size is the header size as displayed.
            let decoded = try XCTUnwrap(ImageProcessing.decode(bytes), "\(label): decode")
            XCTAssertEqual(ImageProcessing.pixelSize(of: decoded), header, "\(label): decoded size")

            let target = ImageLength(expected.variant.targetWidth)
            let variant = try XCTUnwrap(ImageProcessing.variant(from: decoded, targetWidth: target, cornerRadius: 0),
                                        "\(label): variant")
            XCTAssertEqual(variant.pixelWidth, expected.variant.width, "\(label): variant width")
            XCTAssertEqual(variant.pixelHeight, expected.variant.height, "\(label): variant height")

            guard let grid = expected.grid, let tolerance = expected.colorTolerance,
                  let dominant = expected.dominantColor else {
                continue
            }
            let placeholder = try XCTUnwrap(ImageProcessing.placeholder(of: decoded), "\(label): placeholder")
            XCTAssertEqual(placeholder.dimension, grid.dimension, "\(label): grid dimension")
            XCTAssertEqual(placeholder.cells.count, grid.cells.count, "\(label): cell count")
            for (i, cell) in zip(placeholder.cells, grid.cells).enumerated() {
                assertColorClose(cell.0, cell.1, tolerance: tolerance, label: "\(label) cell \(i)")
            }
            assertColorClose(placeholder.dominantColor, dominant, tolerance: tolerance, label: "\(label) dominant")
        }
    }

    // MARK: - Placeholder

    // Transparent pixels must not darken the tint: a checkerboard of opaque red and transparent black averages to
    // a half-transparent RED, as the premultiplied CoreGraphics context gives on Apple platforms.
    func testPlaceholderWeightsColorByAlpha() throws {
        let image = try makeImage(width: 12, height: 12) { x, y in
            (x + y) % 2 == 0 ? (255, 0, 0, 255) : (0, 0, 0, 0)
        }
        let placeholder = try XCTUnwrap(ImageProcessing.placeholder(of: image))
        for (i, cell) in placeholder.cells.enumerated() {
            XCTAssertGreaterThanOrEqual(cell.red, 240, "cell \(i) red")
            XCTAssertLessThanOrEqual(cell.green, 8, "cell \(i) green")
            XCTAssert((110...145).contains(Int(cell.alpha)), "cell \(i) alpha \(cell.alpha)")
        }
    }

    func testPlaceholderOfTinyImageFillsTheGrid() throws {
        let image = try makeImage(width: 1, height: 1) { _, _ in (10, 200, 30, 255) }
        let placeholder = try XCTUnwrap(ImageProcessing.placeholder(of: image))
        XCTAssertEqual(placeholder.cells.count, 36)
        XCTAssertEqual(placeholder.dominantColor, ImageColor(red: 10, green: 200, blue: 30, alpha: 255))
    }

    func testGridImageIsTheGridSize() throws {
        let grid = ImagePlaceholder(dimension: 6, cells: Array(repeating: ImageColor(red: 1, green: 2, blue: 3, alpha: 4),
                                                               count: 36))
        let image = try XCTUnwrap(ImageProcessing.gridImage(from: grid))
        XCTAssertEqual(image.pixelWidth, 6)
        XCTAssertEqual(image.pixelHeight, 6)
        XCTAssertNil(ImageProcessing.gridImage(from: ImagePlaceholder(dimension: 6, cells: [])))
    }

    // MARK: - Variant

    func testVariantDownscalesButNeverUpscales() throws {
        let image = try makeImage(width: 100, height: 50) { _, _ in (0, 0, 255, 255) }
        let smaller = try XCTUnwrap(ImageProcessing.variant(from: image, targetWidth: 40, cornerRadius: 0))
        XCTAssertEqual([smaller.pixelWidth, smaller.pixelHeight], [40, 20])
        let same = try XCTUnwrap(ImageProcessing.variant(from: image, targetWidth: 200, cornerRadius: 0))
        XCTAssertEqual([same.pixelWidth, same.pixelHeight], [100, 50])
        let natural = try XCTUnwrap(ImageProcessing.variant(from: image, targetWidth: nil, cornerRadius: 0))
        XCTAssertEqual([natural.pixelWidth, natural.pixelHeight], [100, 50])
        XCTAssertEqual(ImageProcessing.memoryCost(of: natural), 100 * 50 * 4)
        // A height that rounds to 0 keeps the natural size, as Apple platforms and Android do.
        let strip = try makeImage(width: 1000, height: 1) { _, _ in (0, 0, 255, 255) }
        let thin = try XCTUnwrap(ImageProcessing.variant(from: strip, targetWidth: 300, cornerRadius: 4))
        XCTAssertEqual([thin.pixelWidth, thin.pixelHeight], [1000, 1])
    }

    func testVariantRoundsCornersWithoutTouchingTheOriginal() throws {
        let image = try makeImage(width: 40, height: 40) { _, _ in (255, 255, 255, 255) }
        let rounded = try XCTUnwrap(ImageProcessing.variant(from: image, targetWidth: nil, cornerRadius: 10))
        let alpha = downloadAlpha(rounded)
        XCTAssertEqual(alpha(0, 0), 0, "outside the top-left corner")
        XCTAssertEqual(alpha(39, 39), 0, "outside the bottom-right corner")
        XCTAssertEqual(alpha(3, 3), 255, "inside the curve")
        XCTAssertEqual(alpha(20, 0), 255, "the straight top edge")
        XCTAssertEqual(alpha(20, 20), 255, "the middle")
        let edge = alpha(2, 3)
        XCTAssert(edge > 0 && edge < 255, "the curve is antialiased (\(edge))")
        // The decoded image is shared by every variant of the URL: the mask must not reach it.
        let plain = try XCTUnwrap(ImageProcessing.variant(from: image, targetWidth: nil, cornerRadius: 0))
        XCTAssertEqual(downloadAlpha(plain)(0, 0), 255)
    }

    // MARK: - Decode and headers

    // Whole PNGs, gray, one row, compressed to next to nothing: their size is what they declare.
    private let widestPNG = "iVBORw0KGgoAAAANSUhEUgABAAAAAAABCAAAAABOGbwEAAAAVUlEQVR42u3BAQEAAACCIP+vriFAAQAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAwA0AEAAB0iWUEQAAAABJRU5ErkJggg=="
    private let tooWidePNG = "iVBORw0KGgoAAAANSUhEUgABAAEAAAABCAAAAACh29c6AAAAVklEQVR42u3BAQ0AAADCoPdP7ewBFAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAANwAABEAAVjrzqEAAAAASUVORK5CYII="

    func testDecodeRefusesAnImageLargerThanTheLimit() throws {
        let accepted = try XCTUnwrap(Data(base64Encoded: widestPNG))
        XCTAssertEqual(ImageProcessing.decode(accepted)?.width, 65536, "at the limit it decodes")
        let refused = try XCTUnwrap(Data(base64Encoded: tooWidePNG))
        XCTAssertNil(ImageProcessing.decode(refused), "past it, before any pixels are allocated")
    }

    // gdk-pixbuf's ICNS loader decodes all of its PNG before it reports the size, and a loader told to give up then
    // still finishes with a pixbuf. What refuses this one is decode's own flag, which a PNG on its own never tests.
    func testDecodeRefusesAnImageItsLoaderHasAlreadyDecoded() throws {
        func icns(_ png: Data) -> Data {
            func length(_ count: Int) -> Data {
                Data([UInt8(count >> 24 & 0xFF), UInt8(count >> 16 & 0xFF), UInt8(count >> 8 & 0xFF), UInt8(count & 0xFF)])
            }
            return Data("icns".utf8) + length(16 + png.count) + Data("ic08".utf8) + length(8 + png.count) + png
        }
        let accepted = try XCTUnwrap(Data(base64Encoded: widestPNG))
        try XCTSkipIf(ImageProcessing.decode(icns(accepted)) == nil, "this system has no ICNS loader")
        let refused = try XCTUnwrap(Data(base64Encoded: tooWidePNG))
        XCTAssertNil(ImageProcessing.decode(icns(refused)))
    }

    func testDecodeRejectsBytesNoLoaderReads() {
        XCTAssertNil(ImageProcessing.decode(Data()))
        XCTAssertNil(ImageProcessing.decode(Data("not an image".utf8)))
    }

    func testJpegOrientation() throws {
        let images = fixturesDir().appendingPathComponent("images", isDirectory: true)
        let rotated = try Data(contentsOf: images.appendingPathComponent("exif-rotated.jpg"))
        let plain = try Data(contentsOf: images.appendingPathComponent("gradient.jpg"))
        XCTAssertEqual(rotated.withUnsafeBytes { ImageProcessing.jpegOrientation($0) }, 6)
        XCTAssertEqual(plain.withUnsafeBytes { ImageProcessing.jpegOrientation($0) }, 1)
        // Cut anywhere, the reader stops inside the bounds and reports no rotation or the real one.
        for length in stride(from: 0, to: min(rotated.count, 400), by: 7) {
            let value = rotated.prefix(length).withUnsafeBytes { ImageProcessing.jpegOrientation($0) }
            XCTAssert(value == 1 || value == 6, "prefix \(length): \(value)")
        }
        XCTAssertEqual(Data([0xFF, 0xD8, 0xFF, 0xE1, 0x00, 0x01]).withUnsafeBytes { ImageProcessing.jpegOrientation($0) }, 1)
    }

    // A TIFF carries its orientation in its own IFD0, which GdkPixbuf applies when decoding; the header size
    // must read it too. Both byte orders, and JPEG through the same entry point.
    func testTiffOrientation() throws {
        let little: [UInt8] = [0x49, 0x49, 42, 0, 8, 0, 0, 0, 1, 0, 0x12, 0x01, 3, 0, 1, 0, 0, 0, 6, 0, 0, 0, 0, 0, 0, 0]
        let big: [UInt8] = [0x4D, 0x4D, 0, 42, 0, 0, 0, 8, 0, 1, 0x01, 0x12, 0, 3, 0, 0, 0, 1, 0, 8, 0, 0, 0, 0, 0, 0]
        XCTAssertEqual(Data(little).withUnsafeBytes { ImageProcessing.imageOrientation($0) }, 6)
        XCTAssertEqual(Data(big).withUnsafeBytes { ImageProcessing.imageOrientation($0) }, 8)
        // Not 42 after the byte order: not TIFF.
        var wrong = little
        wrong[2] = 43
        XCTAssertEqual(Data(wrong).withUnsafeBytes { ImageProcessing.imageOrientation($0) }, 1)
        let images = fixturesDir().appendingPathComponent("images", isDirectory: true)
        let rotated = try Data(contentsOf: images.appendingPathComponent("exif-rotated.jpg"))
        XCTAssertEqual(rotated.withUnsafeBytes { ImageProcessing.imageOrientation($0) }, 6)
    }

    // MARK: - Animated containers beyond the fixtures (APNG, WebP)

    func testAnimatedPngNeedsAnimationControlBeforeImageData() {
        let signature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        let header = chunk("IHDR", Array(repeating: 0, count: 13))
        let animated = signature + header + chunk("acTL", Array(repeating: 0, count: 8)) + chunk("IDAT", [])
        let still = signature + header + chunk("IDAT", []) + chunk("acTL", Array(repeating: 0, count: 8))
        XCTAssertTrue(Data(animated).withUnsafeBytes { AnimatedImageDetector.isAnimated($0) })
        XCTAssertFalse(Data(still).withUnsafeBytes { AnimatedImageDetector.isAnimated($0) })
    }

    func testAnimatedWebpFromTheExtendedHeaderFlag() {
        func webp(flags: UInt8) -> Data {
            let vp8x: [UInt8] = Array("VP8X".utf8) + [10, 0, 0, 0, flags] + Array(repeating: 0, count: 9)
            return Data(Array("RIFF".utf8) + [UInt8(4 + vp8x.count), 0, 0, 0] + Array("WEBP".utf8) + vp8x)
        }
        XCTAssertTrue(webp(flags: 0x02).withUnsafeBytes { AnimatedImageDetector.isAnimated($0) })
        XCTAssertFalse(webp(flags: 0x10).withUnsafeBytes { AnimatedImageDetector.isAnimated($0) })
    }

    // MARK: - Helpers

    private func size(_ s: Expected.Size) -> ImageSize {
        ImageSize(width: ImageLength(s.width), height: ImageLength(s.height))
    }

    private func chunk(_ type: String, _ data: [UInt8]) -> [UInt8] {
        let n = data.count
        return [UInt8(n >> 24 & 0xFF), UInt8(n >> 16 & 0xFF), UInt8(n >> 8 & 0xFF), UInt8(n & 0xFF)]
            + Array(type.utf8) + data + [0, 0, 0, 0]
    }

    // An RGBA pixbuf with the colors `pixel` gives, row 0 = top.
    private func makeImage(width: Int, height: Int,
                           pixel: (Int, Int) -> (UInt8, UInt8, UInt8, UInt8)) throws -> DecodedImage {
        let pixbuf = try XCTUnwrap(gdk_pixbuf_new(GDK_COLORSPACE_RGB, 1, 8, Int32(width), Int32(height)))
        let pixels = try XCTUnwrap(gdk_pixbuf_get_pixels(pixbuf))
        let rowStride = Int(gdk_pixbuf_get_rowstride(pixbuf))
        for y in 0..<height {
            for x in 0..<width {
                let c = pixel(x, y)
                let p = pixels + y * rowStride + x * 4
                p[0] = c.0; p[1] = c.1; p[2] = c.2; p[3] = c.3
            }
        }
        return DecodedImage(adopting: pixbuf)
    }

    // The texture's alpha at (x, y), from GTK's default download format (premultiplied, alpha in byte 3).
    private func downloadAlpha(_ image: PlatformImage) -> (Int, Int) -> UInt8 {
        let stride = image.pixelWidth * 4
        var buffer = [UInt8](repeating: 0, count: stride * image.pixelHeight)
        buffer.withUnsafeMutableBufferPointer { gdk_texture_download(image.texture, $0.baseAddress, gsize(stride)) }
        return { x, y in buffer[y * stride + x * 4 + 3] }
    }

    private func assertColorClose(_ actual: ImageColor, _ expected: [Int], tolerance: Int, label: String) {
        let got = [Int(actual.red), Int(actual.green), Int(actual.blue), Int(actual.alpha)]
        for channel in 0..<4 {
            XCTAssertLessThanOrEqual(abs(got[channel] - expected[channel]), tolerance,
                                     "\(label) channel \(channel): got \(got[channel]) expected \(expected[channel])")
        }
    }

    // Fixtures/ is at the package root: four parent hops up from this file reach it from any checkout.
    private func fixturesDir() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Linux
            .deletingLastPathComponent()   // AsyncImageCacheTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // package root
            .appendingPathComponent("Fixtures", isDirectory: true)
    }
}
