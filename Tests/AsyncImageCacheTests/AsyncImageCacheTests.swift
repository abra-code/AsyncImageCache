// Tests/AsyncImageCacheTests/AsyncImageCacheTests.swift
//
// Exercises the async loader + two-tier cache end to end, using ONLY data: and file: URLs (no network is
// assumed available). Covers: data: load + sync cache hit + main-thread completion; downscale to a target
// width; disk persistence across a fresh ImageStore(name:); the transcode/format decisions; and removeAll.

import XCTest
import CoreGraphics
import ImageIO
@testable import AsyncImageCache

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

final class AsyncImageCacheTests: XCTestCase {

    // MARK: - Fixtures

    // A solid-color image at an exact pixel size, built via CoreGraphics.
    private func makeImage(width: Int, height: Int, opaque: Bool) -> PlatformImage {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let alpha: CGImageAlphaInfo = opaque ? .noneSkipLast : .premultipliedLast
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: space, bitmapInfo: alpha.rawValue)!
        ctx.setFillColor(red: 0.2, green: 0.4, blue: 0.8, alpha: opaque ? 1.0 : 0.5)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let cg = ctx.makeImage()!
        #if canImport(UIKit)
        return UIImage(cgImage: cg)
        #else
        return NSImage(cgImage: cg, size: CGSize(width: width, height: height))
        #endif
    }

    private func pngData(width: Int, height: Int, opaque: Bool = true) -> Data {
        let image = makeImage(width: width, height: height, opaque: opaque)
        #if canImport(UIKit)
        return image.pngData()!
        #else
        return NSBitmapImageRep(data: image.tiffRepresentation!)!.representation(using: .png, properties: [:])!
        #endif
    }

    private func dataURL(png: Data) -> URL {
        URL(string: "data:image/png;base64,\(png.base64EncodedString())")!
    }

    private func uniqueName() -> String { "test-\(UUID().uuidString)" }

    // MARK: - Load via data: URL

    func testLoadDataURLSucceedsOnMainAndCachesSynchronously() throws {
        let store = ImageStore(name: uniqueName())
        defer { store.removeAll() }
        let request = ImageRequest(url: dataURL(png: pngData(width: 24, height: 24)))

        let expectation = expectation(description: "completion")
        store.load(request) { image in
            XCTAssertTrue(Thread.isMainThread, "completion must fire on the main thread")
            XCTAssertNotNil(image, "a valid PNG data: URL should load")
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 5)

        XCTAssertNotNil(store.cachedImage(for: request), "the variant should be cached synchronously after load")
        XCTAssertNotNil(store.cachedPixelSize(for: request.url), "natural pixel size should be recorded")
        XCTAssertEqual(store.cachedPixelSize(for: request.url), CGSize(width: 24, height: 24))
    }

    // MARK: - Downscale

    func testDownscaleToTargetWidth() throws {
        let store = ImageStore(name: uniqueName())
        defer { store.removeAll() }
        let request = ImageRequest(url: dataURL(png: pngData(width: 100, height: 100)), targetWidth: 40)

        let expectation = expectation(description: "completion")
        var loaded: PlatformImage?
        store.load(request) { image in
            loaded = image
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 5)

        let image = try XCTUnwrap(loaded)
        XCTAssertEqual(image.size.width, 40, "downscaled width should equal targetWidth")
        // The original natural size is still available for layout reservation.
        XCTAssertEqual(store.cachedPixelSize(for: request.url), CGSize(width: 100, height: 100))
    }

    // MARK: - Disk persistence across instances

    func testDiskPersistenceAcrossFreshInstance() throws {
        let name = uniqueName()
        let tempFile = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("aic-\(UUID().uuidString).png")
        try pngData(width: 30, height: 20).write(to: tempFile)
        let request = ImageRequest(url: tempFile)

        // First instance loads from the file: URL and persists the original bytes to disk.
        let first = ImageStore(name: name)
        let e1 = expectation(description: "first load")
        first.load(request) { image in
            XCTAssertNotNil(image)
            e1.fulfill()
        }
        wait(for: [e1], timeout: 5)

        let diskFile = first.diskDirectoryURL.appendingPathComponent("", isDirectory: true)
        XCTAssertTrue(diskFile.path.contains("AsyncImageCache/\(name)"), "disk dir should live under Caches/AsyncImageCache/<name>")
        XCTAssertTrue(first.diskFileExists(for: tempFile), "original bytes should be on disk under Caches")

        // Delete the source file so any later success MUST come from the disk cache, not the file: path.
        try FileManager.default.removeItem(at: tempFile)
        XCTAssertFalse(FileManager.default.fileExists(atPath: tempFile.path))

        // A FRESH instance with the same name: memory is empty, so it serves from disk.
        let second = ImageStore(name: name)
        defer { second.removeAll() }
        XCTAssertNil(second.cachedImage(for: request), "fresh instance starts with an empty memory cache")

        let e2 = expectation(description: "second load from disk")
        second.load(request) { image in
            XCTAssertNotNil(image, "fresh instance should serve the deleted file from disk")
            e2.fulfill()
        }
        wait(for: [e2], timeout: 5)

        // The raw original bytes (+ natural size) are reconstructed from disk - the cache is format-agnostic;
        // the transcode-for-copy logic now lives in RichText (tested in RichTextImageTranscodeTests).
        XCTAssertNotNil(second.cachedOriginalBytes(for: tempFile), "original bytes should be reconstructed from disk")
    }

    // The whole point of the design: after "relaunch" (fresh store, empty memory) the natural size is known
    // synchronously WITHOUT decoding - it rode along with the on-disk bytes as an extended attribute.
    func testPixelSizeSurvivesRelaunchViaXattrWithoutDecoding() throws {
        let name = uniqueName()
        let store = ImageStore(name: name)
        defer { store.removeAll() }

        let temp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("\(uniqueName()).png")
        try pngData(width: 123, height: 45).write(to: temp)
        defer { try? FileManager.default.removeItem(at: temp) }
        let request = ImageRequest(url: temp)

        let loaded = expectation(description: "load")
        store.load(request) { _ in loaded.fulfill() }
        wait(for: [loaded], timeout: 5)
        XCTAssertEqual(store.cachedPixelSize(for: temp), CGSize(width: 123, height: 45))

        // Delete the source, and use a FRESH instance (empty memory). It never loads/decodes the image, yet
        // knows its size from the xattr on the cached bytes.
        try FileManager.default.removeItem(at: temp)
        let second = ImageStore(name: name)
        defer { second.removeAll() }
        XCTAssertNil(second.cachedImage(for: request), "fresh instance has no decoded variant in memory")
        XCTAssertEqual(second.cachedPixelSize(for: temp), CGSize(width: 123, height: 45),
                       "the size must be read from the disk xattr, with no decode")
    }

    // MARK: - removeAll

    func testRemoveAllClearsMemoryAndDisk() throws {
        let store = ImageStore(name: uniqueName())
        let request = ImageRequest(url: dataURL(png: pngData(width: 20, height: 20)))

        let expectation = expectation(description: "load")
        store.load(request) { _ in expectation.fulfill() }
        wait(for: [expectation], timeout: 5)

        XCTAssertNotNil(store.cachedImage(for: request))

        store.removeAll()
        XCTAssertNil(store.cachedImage(for: request), "memory variant cache should be cleared")
        XCTAssertNil(store.cachedOriginalBytes(for: request.url)?.data, "memory original cache should be cleared")
        XCTAssertFalse(store.diskFileExists(for: request.url), "disk bytes should be cleared")
    }

    func testConcurrentIdenticalRequestsDeduplicate() throws {
        let store = ImageStore(name: uniqueName())
        defer { store.removeAll() }
        let request = ImageRequest(url: dataURL(png: pngData(width: 32, height: 32)))

        let expectations = (0..<8).map { expectation(description: "completion \($0)") }
        for expectation in expectations {
            store.load(request) { image in
                XCTAssertNotNil(image)
                expectation.fulfill()
            }
        }
        wait(for: expectations, timeout: 5)
        XCTAssertNotNil(store.cachedImage(for: request))
    }

    // The variant key quantizes transforms to whole pixels, so sub-pixel-apart requests share one cached
    // variant (no wasted decodes) and the key carries no fractional tail.
    func testVariantKeyQuantizesToWholePixels() {
        let url = URL(string: "https://example.test/i.png")!
        let a = ImageRequest(url: url, targetWidth: 342.4, cornerRadius: 9.6)
        let b = ImageRequest(url: url, targetWidth: 342.2, cornerRadius: 10.1)
        XCTAssertEqual(a.variantKey, b.variantKey, "sub-pixel widths/radii should collapse to one variant")
        // The width/radius carry no fractional tail (342.4 would have produced "|w=342.4|").
        XCTAssertTrue(a.variantKey.contains("|w=342|"), a.variantKey)
        XCTAssertTrue(a.variantKey.hasSuffix("|r=10"), a.variantKey)
        XCTAssertEqual(ImageRequest(url: url).variantKey, "\(url.absoluteString)|w=nil|r=0")
    }

    // Resilience: if the size xattr is missing (lost, or bytes cached by an older build) but the image bytes
    // are on disk, the size is still recovered from the image HEADER (no decode) and the xattr is repaired.
    func testPixelSizeFallsBackToImageHeaderWhenXattrMissing() throws {
        let disk = DiskCache(name: uniqueName(), byteLimit: 200 * 1024 * 1024)
        defer { disk.removeAll() }
        let url = URL(string: "https://example.test/no-xattr.jpg")!

        // Store real JPEG bytes but with a .zero size, so NO xattr is written (writePixelSize guards size > 0).
        disk.store(gradientJPEG(width: 200, height: 150), pixelSize: .zero, for: url)

        XCTAssertEqual(disk.pixelSize(for: url), CGSize(width: 200, height: 150),
                       "size must fall back to the image header when the xattr is absent")

        // ...and the fallback should have repaired the attribute, so the next read takes the fast path.
        let length = getxattr(disk.fileURL(for: url).path, "public.asyncimagecache.pixelsize", nil, 0, 0, 0)
        XCTAssertGreaterThan(length, 0, "the header fallback should write the xattr back (repair)")
    }

    // MARK: - Performance: reading dimensions

    // A realistic-ish cached image: a diagonal-gradient JPEG (tens of KB), so read/decode costs represent a
    // real photo rather than a trivially-compressed solid PNG.
    private func gradientJPEG(width: Int, height: Int, quality: CGFloat = 0.8) -> Data {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        let colors = [CGColor(srgbRed: 0.10, green: 0.20, blue: 0.55, alpha: 1),
                      CGColor(srgbRed: 0.95, green: 0.65, blue: 0.20, alpha: 1)] as CFArray
        let gradient = CGGradient(colorsSpace: space, colors: colors, locations: [0, 1])!
        ctx.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: width, y: height), options: [])
        let cg = ctx.makeImage()!
        #if canImport(UIKit)
        return UIImage(cgImage: cg).jpegData(compressionQuality: quality)!
        #else
        return NSBitmapImageRep(cgImage: cg).representation(using: .jpeg, properties: [.compressionFactor: quality])!
        #endif
    }

    private func store100(_ disk: DiskCache, bytes: Data, withXattr: Bool) -> [URL] {
        let urls = (0..<100).map { URL(string: "https://example.test/img-\($0).jpg")! }
        for (i, url) in urls.enumerated() {
            disk.store(bytes, pixelSize: withXattr ? CGSize(width: 1024, height: 768 + i) : .zero, for: url)
        }
        return urls
    }

    // Reading the natural size of 100 cached ~1024x768 gradient JPEGs from their xattrs. A getxattr of an
    // 8-byte attribute, INDEPENDENT of image size - contrast with decoding the same files below.
    func testXattrSizeReadPerformanceFor100Files() {
        let disk = DiskCache(name: uniqueName(), byteLimit: 512 * 1024 * 1024)
        defer { disk.removeAll() }
        let urls = store100(disk, bytes: gradientJPEG(width: 1024, height: 768), withXattr: true)

        measure {
            for url in urls {
                _ = disk.pixelSize(for: url)
            }
        }

        XCTAssertEqual(disk.pixelSize(for: urls[99]), CGSize(width: 1024, height: 867))
    }

    // Contrast: the same 100 files, but obtaining the size by reading the whole JPEG off disk and decoding it
    // - the "no xattr" path the design avoids (which reads + parses the full image instead of 8 bytes).
    func testDecodeSizeReadPerformanceFor100Files() {
        let disk = DiskCache(name: uniqueName(), byteLimit: 512 * 1024 * 1024)
        defer { disk.removeAll() }
        let urls = store100(disk, bytes: gradientJPEG(width: 1024, height: 768), withXattr: false)

        measure {
            for url in urls {
                if let data = disk.data(for: url), let image = PlatformImage(data: data) {
                    _ = ImageProcessing.pixelSize(of: image)
                }
            }
        }
    }

    // Honest middle ground: CGImageSource reads only the JPEG HEADER off disk (kCGImagePropertyPixelWidth/
    // Height), not the whole image - cheaper than a full decode, but still opens + parses each file, whereas
    // the xattr read touches 8 bytes with no image parse at all.
    func testImageSourceHeaderSizeReadPerformanceFor100Files() {
        let disk = DiskCache(name: uniqueName(), byteLimit: 512 * 1024 * 1024)
        defer { disk.removeAll() }
        let files = store100(disk, bytes: gradientJPEG(width: 1024, height: 768), withXattr: false)
            .map { disk.fileURL(for: $0) }

        measure {
            for file in files {
                if let src = CGImageSourceCreateWithURL(file as CFURL, nil),
                   let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
                   let w = props[kCGImagePropertyPixelWidth] as? Int,
                   let h = props[kCGImagePropertyPixelHeight] as? Int {
                    _ = CGSize(width: w, height: h)
                }
            }
        }
    }
}
