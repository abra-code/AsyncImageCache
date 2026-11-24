// Tests/AsyncImageCacheTests/Windows/WindowsImageProcessingTests.swift
//
// The Windows image pipeline (ImageProcessing+Windows.swift over WIC) and the portable readers it shares with Linux
// (ImageOrientation.swift, AnimatedImageDetector.swift). The shared fixtures (Fixtures/, emitted by the Swift tests
// on Apple platforms and read by the Linux and Android suites too) pin the animated flag, the header size, the
// variant geometry and the placeholder colors to the same values on every platform.

#if os(Windows)

import XCTest
import Foundation
@testable import AsyncImageCache

final class WindowsImageProcessingTests: XCTestCase {

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

            // The decode turns the pixels upright, so its size is the header size as displayed.
            let decoded = try XCTUnwrap(ImageProcessing.decode(bytes), "\(label): decode")
            XCTAssertEqual(ImageProcessing.pixelSize(of: decoded), header, "\(label): decoded size")

            let target = ImageLength(expected.variant.targetWidth)
            let variant = try XCTUnwrap(ImageProcessing.variant(from: decoded, targetWidth: target, cornerRadius: 0),
                                        "\(label): variant")
            XCTAssertEqual(variant.pixelWidth, expected.variant.width, "\(label): variant width")
            XCTAssertEqual(variant.pixelHeight, expected.variant.height, "\(label): variant height")
            XCTAssertEqual(variant.pixelBytes?.count, variant.pixelWidth * 4 * variant.pixelHeight, "\(label): variant pixels")

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
        let image = makeImage(width: 12, height: 12) { x, y in
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
        let image = makeImage(width: 1, height: 1) { _, _ in (10, 200, 30, 255) }
        let placeholder = try XCTUnwrap(ImageProcessing.placeholder(of: image))
        XCTAssertEqual(placeholder.cells.count, 36)
        XCTAssertEqual(placeholder.dominantColor, ImageColor(red: 10, green: 200, blue: 30, alpha: 255))
    }

    func testGridImageIsTheGridSizeAndPremultiplied() throws {
        let grid = ImagePlaceholder(dimension: 6, cells: Array(repeating: ImageColor(red: 200, green: 100, blue: 50, alpha: 128),
                                                               count: 36))
        let image = try XCTUnwrap(ImageProcessing.gridImage(from: grid))
        XCTAssertEqual(image.pixelWidth, 6)
        XCTAssertEqual(image.pixelHeight, 6)
        XCTAssertEqual(image.pixelBytes.map { Array($0[0..<4]) }, [25, 50, 100, 128], "BGRA, each color times the alpha")
        XCTAssertNil(ImageProcessing.gridImage(from: ImagePlaceholder(dimension: 6, cells: [])))
    }

    // MARK: - Variant

    func testVariantDownscalesButNeverUpscales() throws {
        let image = makeImage(width: 100, height: 50) { _, _ in (0, 0, 255, 255) }
        let smaller = try XCTUnwrap(ImageProcessing.variant(from: image, targetWidth: 40, cornerRadius: 0))
        XCTAssertEqual([smaller.pixelWidth, smaller.pixelHeight], [40, 20])
        XCTAssertEqual(smaller.pixelBytes.map { Array($0[0..<4]) }, [255, 0, 0, 255], "blue stays blue through the scaler")
        let same = try XCTUnwrap(ImageProcessing.variant(from: image, targetWidth: 200, cornerRadius: 0))
        XCTAssertEqual([same.pixelWidth, same.pixelHeight], [100, 50])
        let natural = try XCTUnwrap(ImageProcessing.variant(from: image, targetWidth: nil, cornerRadius: 0))
        XCTAssertEqual([natural.pixelWidth, natural.pixelHeight], [100, 50])
        XCTAssertEqual(ImageProcessing.memoryCost(of: natural), 100 * 50 * 4)
        // A height that rounds to 0 keeps the natural size, as Apple platforms and Android do.
        let strip = makeImage(width: 1000, height: 1) { _, _ in (0, 0, 255, 255) }
        let thin = try XCTUnwrap(ImageProcessing.variant(from: strip, targetWidth: 300, cornerRadius: 4))
        XCTAssertEqual([thin.pixelWidth, thin.pixelHeight], [1000, 1])
    }

    func testVariantRoundsCornersWithoutTouchingTheOriginal() throws {
        let image = makeImage(width: 40, height: 40) { _, _ in (255, 255, 255, 255) }
        let rounded = try XCTUnwrap(ImageProcessing.variant(from: image, targetWidth: nil, cornerRadius: 10))
        let pixels = try XCTUnwrap(rounded.pixelBytes)
        let alpha = { (x: Int, y: Int) in pixels[(y * 40 + x) * 4 + 3] }
        XCTAssertEqual(alpha(0, 0), 0, "outside the top-left corner")
        XCTAssertEqual(alpha(39, 39), 0, "outside the bottom-right corner")
        XCTAssertEqual(alpha(3, 3), 255, "inside the curve")
        XCTAssertEqual(alpha(20, 0), 255, "the straight top edge")
        XCTAssertEqual(alpha(20, 20), 255, "the middle")
        let edge = alpha(2, 3)
        XCTAssert(edge > 0 && edge < 255, "the curve is antialiased (\(edge))")
        // Premultiplied: a color never exceeds its alpha.
        XCTAssertLessThanOrEqual(pixels[(3 * 40 + 2) * 4], edge)
        // The decoded image is shared by every variant of the URL: the mask must not reach it.
        XCTAssertEqual(image.pixels[3], 255)
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

    func testDecodeRejectsBytesNoCodecReads() {
        XCTAssertNil(ImageProcessing.decode(Data()))
        XCTAssertNil(ImageProcessing.decode(Data("not an image".utf8)))
    }

    // A PNG the test writes itself: WIC reads it, colors and alpha come out premultiplied BGRA.
    func testDecodeGivesPremultipliedBGRA() throws {
        let png = WindowsTestImages.png(width: 2, height: 1) { x, _ in x == 0 ? (255, 0, 0, 255) : (0, 0, 255, 128) }
        let decoded = try XCTUnwrap(ImageProcessing.decode(png))
        XCTAssertEqual([decoded.width, decoded.height], [2, 1])
        XCTAssertEqual(Array(decoded.pixels[0..<4]), [0, 0, 255, 255], "opaque red")
        XCTAssertEqual(Array(decoded.pixels[4..<8]), [128, 0, 0, 128], "half-transparent blue, premultiplied")
    }

    // The fixture is stored landscape with orientation 6 (a quarter turn clockwise): the decode is portrait, as the
    // header size says (the pixel turns are checked by testEachOrientationTurnsThePixels).
    func testDecodeTurnsAnExifRotatedJPEGUpright() throws {
        let images = fixturesDir().appendingPathComponent("images", isDirectory: true)
        let rotated = try Data(contentsOf: images.appendingPathComponent("exif-rotated.jpg"))
        XCTAssertEqual(rotated.withUnsafeBytes { ImageProcessing.imageOrientation($0) }, 6)
        let decoded = try XCTUnwrap(ImageProcessing.decode(rotated))
        let header = try XCTUnwrap(ImageProcessing.headerPixelSize(atPath: images.appendingPathComponent("exif-rotated.jpg").path))
        XCTAssertEqual(ImageProcessing.pixelSize(of: decoded), header)
    }

    // Each EXIF orientation turns a stored 3 x 2 image (a b c / d e f) as the tag says it is to be shown.
    func testEachOrientationTurnsThePixels() {
        let stored: [UInt8] = (0..<6).flatMap { index -> [UInt8] in [UInt8(index), 0, 0, 255] }
        func shown(_ orientation: Int) -> (Int, Int, String) {
            let image = ImageProcessing.oriented(stored, width: 3, height: 2, orientation: orientation)
            let letters = stride(from: 0, to: image.pixels.count, by: 4).map { String(UnicodeScalar(97 + image.pixels[$0])) }
            return (image.width, image.height, letters.joined())
        }
        XCTAssertTrue(shown(1) == (3, 2, "abcdef"), "upright")
        XCTAssertTrue(shown(2) == (3, 2, "cbafed"), "mirrored left to right")
        XCTAssertTrue(shown(3) == (3, 2, "fedcba"), "half a turn")
        XCTAssertTrue(shown(4) == (3, 2, "defabc"), "mirrored top to bottom")
        XCTAssertTrue(shown(5) == (2, 3, "adbecf"), "mirrored, then a quarter turn counterclockwise")
        XCTAssertTrue(shown(6) == (2, 3, "daebfc"), "a quarter turn clockwise")
        XCTAssertTrue(shown(7) == (2, 3, "fcebda"), "mirrored, then a quarter turn clockwise")
        XCTAssertTrue(shown(8) == (2, 3, "cfbead"), "a quarter turn counterclockwise")
        XCTAssertTrue(shown(9) == (3, 2, "abcdef"), "an orientation out of range is upright")
    }

    func testTiffOrientation() {
        let little: [UInt8] = [0x49, 0x49, 42, 0, 8, 0, 0, 0, 1, 0, 0x12, 0x01, 3, 0, 1, 0, 0, 0, 6, 0, 0, 0, 0, 0, 0, 0]
        let big: [UInt8] = [0x4D, 0x4D, 0, 42, 0, 0, 0, 8, 0, 1, 0x01, 0x12, 0, 3, 0, 0, 0, 1, 0, 8, 0, 0, 0, 0, 0, 0]
        XCTAssertEqual(Data(little).withUnsafeBytes { ImageProcessing.imageOrientation($0) }, 6)
        XCTAssertEqual(Data(big).withUnsafeBytes { ImageProcessing.imageOrientation($0) }, 8)
    }

    // MARK: - Helpers

    private func size(_ s: Expected.Size) -> ImageSize {
        ImageSize(width: ImageLength(s.width), height: ImageLength(s.height))
    }

    // A decoded image from unpremultiplied RGBA colors, stored premultiplied BGRA as decode makes them.
    private func makeImage(width: Int, height: Int,
                           pixel: (Int, Int) -> (UInt8, UInt8, UInt8, UInt8)) -> DecodedImage {
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let c = pixel(x, y)
                let p = (y * width + x) * 4
                let a = Int(c.3)
                pixels[p] = UInt8((Int(c.2) * a + 127) / 255)
                pixels[p + 1] = UInt8((Int(c.1) * a + 127) / 255)
                pixels[p + 2] = UInt8((Int(c.0) * a + 127) / 255)
                pixels[p + 3] = c.3
            }
        }
        return DecodedImage(width: width, height: height, pixels: pixels)
    }

    private func assertColorClose(_ actual: ImageColor, _ expected: [Int], tolerance: Int, label: String) {
        let got = [Int(actual.red), Int(actual.green), Int(actual.blue), Int(actual.alpha)]
        for channel in 0..<4 {
            XCTAssertLessThanOrEqual(abs(got[channel] - expected[channel]), tolerance,
                                     "\(label) channel \(channel): \(got) vs \(expected)")
        }
    }

    private func fixturesDir() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Windows
            .deletingLastPathComponent()   // AsyncImageCacheTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // package root
            .appendingPathComponent("Fixtures", isDirectory: true)
    }
}

/// PNGs for the Windows tests, written here (no encoder is needed from the system): RGBA, 8 bits a channel, the
/// image data in stored (uncompressed) deflate blocks.
enum WindowsTestImages {
    static func png(width: Int, height: Int, pixel: (Int, Int) -> (UInt8, UInt8, UInt8, UInt8)) -> Data {
        var raw: [UInt8] = []
        for y in 0..<height {
            raw.append(0)   // no filter
            for x in 0..<width {
                let c = pixel(x, y)
                raw += [c.0, c.1, c.2, c.3]
            }
        }
        var zlib: [UInt8] = [0x78, 0x01]
        var offset = 0
        repeat {
            let count = min(65535, raw.count - offset)
            let last: UInt8 = offset + count == raw.count ? 1 : 0
            zlib += [last, UInt8(count & 0xFF), UInt8(count >> 8), UInt8(~count & 0xFF), UInt8((~count >> 8) & 0xFF)]
            zlib += raw[offset..<(offset + count)]
            offset += count
        } while offset < raw.count
        zlib += bigEndian(adler32(raw))
        let header = bigEndian(UInt32(width)) + bigEndian(UInt32(height)) + [8, 6, 0, 0, 0]
        let signature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        return Data(signature + chunk("IHDR", header) + chunk("IDAT", zlib) + chunk("IEND", []))
    }

    /// A solid PNG of one color, for the store's tests.
    static func png(width: Int, height: Int) -> Data {
        png(width: width, height: height) { _, _ in (0x33, 0x66, 0xCC, 0xFF) }
    }

    private static func chunk(_ type: String, _ data: [UInt8]) -> [UInt8] {
        let typed = Array(type.utf8) + data
        return bigEndian(UInt32(data.count)) + typed + bigEndian(crc32(typed))
    }

    private static func bigEndian(_ value: UInt32) -> [UInt8] {
        [UInt8(value >> 24), UInt8(value >> 16 & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)]
    }

    private static func crc32(_ bytes: [UInt8]) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in bytes {
            crc ^= UInt32(byte)
            for _ in 0..<8 {
                crc = crc & 1 == 1 ? (crc >> 1) ^ 0xEDB8_8320 : crc >> 1
            }
        }
        return ~crc
    }

    private static func adler32(_ bytes: [UInt8]) -> UInt32 {
        var a: UInt32 = 1
        var b: UInt32 = 0
        for byte in bytes {
            a = (a + UInt32(byte)) % 65521
            b = (b + a) % 65521
        }
        return b << 16 | a
    }
}

#endif
