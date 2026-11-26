// Tests/AsyncImageCacheTests/Windows/WindowsImageStoreTests.swift
//
// The Windows store, disk cache and file and data: readers, and the portable memory cache and sidecar codec.
// Completions run on the main dispatch queue, so the tests run the main run loop while they wait, as a program's
// message loop would. http and https are checked by ActionUI's Windows CI against its local test server.

#if os(Windows)

import XCTest
import Foundation
@testable import AsyncImageCache

final class WindowsImageStoreTests: XCTestCase {

    private var stores: [ImageStore] = []

    override func tearDown() {
        for store in stores {
            store.removeAll()
            try? FileManager.default.removeItem(at: store.diskDirectoryURL)
        }
        stores = []
        super.tearDown()
    }

    // MARK: - Loading

    func testLoadDataURLDeliversOnMainAndCaches() throws {
        let store = makeStore()
        let request = ImageRequest(url: dataURL(png: WindowsTestImages.png(width: 24, height: 24)))
        var onMain = false
        let image = try XCTUnwrap(load(store, request) { onMain = Thread.isMainThread })
        XCTAssertTrue(onMain, "completions run on the main thread")
        XCTAssertEqual([image.pixelWidth, image.pixelHeight], [24, 24])
        XCTAssertTrue(store.cachedImage(for: request) === image, "the variant is kept in memory")
        XCTAssertEqual(store.cachedPixelSize(for: request.url), ImageSize(width: 24, height: 24))
        XCTAssertNotNil(store.placeholder(for: request.url))
        XCTAssertNotNil(store.placeholderImage(for: request.url))
        XCTAssertFalse(store.isAnimated(for: request.url))
        XCTAssertTrue(store.diskFileExists(for: request.url), "fresh bytes are written to disk")
    }

    func testMemoryHitStillCompletesLater() throws {
        let store = makeStore()
        let request = ImageRequest(url: dataURL(png: WindowsTestImages.png(width: 8, height: 8)))
        XCTAssertNotNil(load(store, request))
        var called = false
        store.load(request) { _ in called = true }
        XCTAssertFalse(called, "a memory hit completes after load returns, as on Apple's main queue")
        XCTAssertTrue(pump { called })
    }

    func testDownscaleToTargetWidth() throws {
        let store = makeStore()
        let image = try XCTUnwrap(load(store, ImageRequest(url: dataURL(png: WindowsTestImages.png(width: 100, height: 50)),
                                                         targetWidth: 40)))
        XCTAssertEqual([image.pixelWidth, image.pixelHeight], [40, 20])
    }

    func testConcurrentIdenticalRequestsShareOneResult() throws {
        let store = makeStore()
        let request = ImageRequest(url: dataURL(png: WindowsTestImages.png(width: 16, height: 16)))
        var results: [PlatformImage?] = []
        store.load(request) { results.append($0) }
        store.load(request) { results.append($0) }
        XCTAssertTrue(pump { results.count == 2 })
        XCTAssertNotNil(results[0])
        XCTAssertTrue(results[0] === results[1], "one production serves both")
    }

    func testImagePersistsAcrossStoresAndRelaunch() throws {
        let name = uniqueName()
        let source = dataURL(png: WindowsTestImages.png(width: 30, height: 20))
        let first = makeStore(name: name)
        XCTAssertNotNil(load(first, ImageRequest(url: source)))
        XCTAssertTrue(first.diskFileExists(for: source))

        // A new store of the same name (a relaunch): the size, grid and flag come from the sidecar, no decode.
        let second = ImageStore(name: name)
        XCTAssertEqual(second.cachedPixelSize(for: source), ImageSize(width: 30, height: 20))
        XCTAssertNotNil(second.placeholder(for: source))
        XCTAssertFalse(second.isAnimated(for: source))
        // ...and the bytes come from disk: the data: URL could decode itself, so the cached bytes are swapped for
        // a different picture that only a disk hit sees.
        try WindowsTestImages.png(width: 60, height: 20)
            .write(to: DiskCache(name: name, byteLimit: 1 << 20).fileURL(for: source))
        let image = try XCTUnwrap(load(second, ImageRequest(url: source, targetWidth: 15)))
        XCTAssertEqual([image.pixelWidth, image.pixelHeight], [15, 5])
    }

    // In the same run: a local file's memory entries are keyed on its modification time and size, so after an
    // edit the old picture is a miss and the next load reads the new one.
    func testAnEditedLocalFileShowsItsNewPictureInTheSameRun() throws {
        let store = makeStore()
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("\(uniqueName()).png")
        try WindowsTestImages.png(width: 30, height: 20).write(to: file)
        defer {
            try? FileManager.default.removeItem(at: file)
        }
        let request = ImageRequest(url: file)
        XCTAssertNotNil(load(store, request))
        XCTAssertNotNil(store.cachedImage(for: request))

        try WindowsTestImages.png(width: 40, height: 10).write(to: file)
        // A different modification time for sure (Windows' stat has whole seconds), not only a different size.
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(10)],
                                              ofItemAtPath: file.path)
        XCTAssertNil(store.cachedImage(for: request), "the old picture is not shown for the edited file")
        XCTAssertNil(store.cachedPixelSize(for: file))
        let image = try XCTUnwrap(load(store, request))
        XCTAssertEqual([image.pixelWidth, image.pixelHeight], [40, 10], "the edited file is shown")
    }

    // A local file is its own copy: it is never kept in the disk tier, so after it is edited a new store (a
    // relaunch) shows the new picture, not the old one.
    func testLocalFileImagesSkipTheDiskCache() throws {
        let name = uniqueName()
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("\(name).png")
        try WindowsTestImages.png(width: 30, height: 20).write(to: file)
        defer {
            try? FileManager.default.removeItem(at: file)
        }
        let first = makeStore(name: name)
        XCTAssertNotNil(load(first, ImageRequest(url: file)))
        XCTAssertFalse(first.diskFileExists(for: file), "a local file is not copied into the disk cache")

        try WindowsTestImages.png(width: 40, height: 10).write(to: file)
        let second = ImageStore(name: name)
        XCTAssertNil(second.cachedPixelSize(for: file), "nothing about the old file was kept")
        let image = try XCTUnwrap(load(second, ImageRequest(url: file)))
        XCTAssertEqual([image.pixelWidth, image.pixelHeight], [40, 10], "the edited file is shown")
    }

    func testUnknownSchemeUndecodableBytesAndDevicesDeliverNil() {
        let store = makeStore()
        XCTAssertNil(load(store, ImageRequest(url: URL(string: "ftp://example.test/i.png")!)))
        XCTAssertNil(load(store, ImageRequest(url: URL(string: "data:text/plain;base64,aGVsbG8=")!)))
        // A device reads forever (CON waits for typing): never read at all.
        XCTAssertNil(load(store, ImageRequest(url: URL(string: "file:///NUL")!)))
        XCTAssertNil(load(store, ImageRequest(url: URL(string: "file:///C:/Windows")!)), "a folder")
    }

    // MARK: - The image a WinUI program shows

    // Off the main thread, the variant's pixels move into a Windows SoftwareBitmap (a system type, there in a test
    // process too) and come back unchanged.
    func testPreparedImageKeepsItsPixelsInASoftwareBitmap() throws {
        let pixels = (0..<(3 * 2)).flatMap { index -> [UInt8] in [UInt8(index * 10), UInt8(index), 0, 255] }
        let image = PlatformImage(pixelWidth: 3, pixelHeight: 2, pixels: pixels)
        XCTAssertFalse(image.holdsBitmap)
        let prepared = expectation(description: "prepared off the main thread")
        DispatchQueue.global().async {
            image.prepareForDisplay()
            prepared.fulfill()
        }
        wait(for: [prepared], timeout: 10)
        XCTAssertTrue(image.holdsBitmap, "the pixels are in a SoftwareBitmap")
        XCTAssertEqual(image.pixelBytes, pixels, "read back unchanged")
    }

    // A variant without corners keeps the image's encoded bytes for WinUI to decode at its size (one copy of the
    // pixels in WinUI); with corners, its pixels go into a SoftwareBitmap. A test process has no WinUI, so the bytes
    // stay; decoded as WinUI would, they are the variant's size.
    func testVariantKindFollowsTheCorners() throws {
        let store = makeStore()
        let url = dataURL(png: WindowsTestImages.png(width: 100, height: 50))
        let plain = try XCTUnwrap(load(store, ImageRequest(url: url, targetWidth: 40)))
        XCTAssertTrue(plain.holdsEncodedBytes, "the bytes wait for WinUI")
        XCTAssertFalse(plain.holdsBitmap)
        XCTAssertEqual([plain.pixelWidth, plain.pixelHeight], [40, 20])
        XCTAssertEqual(plain.pixelBytes?.count, 40 * 20 * 4, "decoded at the variant's size")
        let rounded = try XCTUnwrap(load(store, ImageRequest(url: url, targetWidth: 40, cornerRadius: 6)))
        XCTAssertFalse(rounded.holdsEncodedBytes)
        XCTAssertTrue(rounded.holdsBitmap, "corners are baked into pixels, held in a SoftwareBitmap")
        XCTAssertEqual(rounded.pixelBytes.map { Array($0[0..<4]) }, [0, 0, 0, 0], "a cut corner is clear")
    }

    // An EXIF-rotated image on the encoded path has its displayed size (sides swapped), as WinUI shows it: the
    // fixture is stored 100 x 40 with orientation 6, shown 40 x 100; asked 20 wide, 20 x 50.
    func testRotatedImageKeepsItsDisplayedSize() throws {
        let file = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Fixtures/images/exif-rotated.jpg")
        let image = try XCTUnwrap(load(makeStore(), ImageRequest(url: file, targetWidth: 20)))
        XCTAssertTrue(image.holdsEncodedBytes)
        XCTAssertEqual([image.pixelWidth, image.pixelHeight], [20, 50])
        XCTAssertEqual(image.pixelBytes?.count, 20 * 50 * 4)
    }

    // A test process has not started the Windows App SDK, so it has no WinUI: no image source, and the image keeps
    // its bitmap. ActionUI's Windows CI shows the source in a WinUI program.
    @MainActor
    func testNoImageSourceWithoutWinUI() throws {
        let image = PlatformImage(pixelWidth: 2, pixelHeight: 2, pixels: [UInt8](repeating: 255, count: 16))
        image.prepareForDisplay()
        let source = image.imageSource
        if source == nil {
            XCTAssertTrue(image.holdsBitmap, "the bitmap is kept for a later try")
            XCTAssertEqual(image.pixelBytes, [UInt8](repeating: 255, count: 16))
        } else {
            XCTAssertNil(image.pixelBytes, "once WinUI holds the image, no other copy is kept")
        }
        // A loaded image reaches its completion either way.
        let store = makeStore()
        XCTAssertNotNil(load(store, ImageRequest(url: dataURL(png: WindowsTestImages.png(width: 4, height: 4)))))
    }

    func testDownloadByteLimitDefaultsSetsAndClamps() {
        let store = makeStore()
        XCTAssertEqual(store.downloadByteLimit, 32 * 1024 * 1024)
        XCTAssertEqual(ImageStore.defaultDownloadByteLimit, 32 * 1024 * 1024)
        store.downloadByteLimit = 500 * 1024 * 1024
        XCTAssertEqual(store.downloadByteLimit, 500 * 1024 * 1024)
        store.downloadByteLimit = -5
        XCTAssertEqual(store.downloadByteLimit, 0, "a negative limit counts as 0")
        XCTAssertEqual(makeStore(downloadByteLimit: -1).downloadByteLimit, 0)
    }

    // MARK: - File and data: URLs

    // The path Windows opens for a file: URL, as ActionUI's renderer reads it: a host names a share.
    func testWindowsPathOfFileURLs() {
        func path(_ text: String) -> String? {
            ImageStore.windowsPath(of: URL(string: text)!)
        }
        XCTAssertEqual(path("file:///C:/Pictures/a%20b.png"), "C:\\Pictures\\a b.png")
        XCTAssertEqual(path("file://localhost/C:/a.png"), "C:\\a.png")
        XCTAssertEqual(path("file://server/share/a.png"), "\\\\server\\share\\a.png")
        XCTAssertEqual(path("file://localhost/share/a.png"), "\\\\localhost\\share\\a.png", "no drive: a share")
        XCTAssertNil(path("https://example.test/a.png"))
    }

    func testDataURLs() {
        XCTAssertEqual(ImageStore.decodeDataURL("data:image/png;base64,AAEC"), Data([0, 1, 2]))
        XCTAssertEqual(ImageStore.decodeDataURL("DATA:;BASE64,AA%3D%3D"), Data([0]), "escapes in base64, any case")
        XCTAssertEqual(ImageStore.decodeDataURL("data:,a%20b"), Data("a b".utf8))
        XCTAssertEqual(ImageStore.decodeDataURL("data:image/png;base64,AA\nEC"), Data([0, 1, 2]), "a line break")
        XCTAssertNil(ImageStore.decodeDataURL("data:,%2"), "a cut escape")
        XCTAssertNil(ImageStore.decodeDataURL("data:,"), "nothing")
        XCTAssertNil(ImageStore.decodeDataURL("data:image/png;base64"), "no comma")
        XCTAssertNil(ImageStore.decodeDataURL("http://a/,b"))
    }

    // MARK: - Disk cache

    // The same file names as the Apple cache (CryptoKit's SHA-256 there, BCrypt here).
    func testDiskFileNameIsTheURLsSHA256() {
        let disk = DiskCache(name: uniqueName(), byteLimit: 1 << 20)
        defer {
            try? FileManager.default.removeItem(at: disk.directoryURL)
        }
        let file = disk.fileURL(for: URL(string: "https://example.test/i.png")!)
        XCTAssertEqual(file.lastPathComponent, "ed0321a5ad41ee2261789123c6f483f6f5c6e194ddddf38ddefa583b4e4e8dbb")
    }

    // In the local application data folder, not the temporary folder FileManager's .cachesDirectory gives on Windows.
    func testDiskCacheLivesInLocalAppData() throws {
        let localAppData = try XCTUnwrap(ProcessInfo.processInfo.environment["LOCALAPPDATA"])
        let name = uniqueName()
        let disk = DiskCache(name: name, byteLimit: 1 << 20)
        defer {
            try? FileManager.default.removeItem(at: disk.directoryURL)
        }
        let expected = URL(fileURLWithPath: localAppData, isDirectory: true)
            .appendingPathComponent("AsyncImageCache", isDirectory: true)
            .appendingPathComponent(name, isDirectory: true)
        XCTAssertEqual(disk.directoryURL.standardizedFileURL.path.lowercased(), expected.standardizedFileURL.path.lowercased())
        print("AsyncImageCache disk folder: \(disk.directoryURL.path)")
    }

    func testLostSidecarIsRepairedFromTheHeader() throws {
        let disk = DiskCache(name: uniqueName(), byteLimit: 10 << 20)
        defer {
            try? FileManager.default.removeItem(at: disk.directoryURL)
        }
        let url = URL(string: "https://example.test/no-meta.png")!
        disk.store(WindowsTestImages.png(width: 50, height: 40), pixelSize: ImageSize(width: 50, height: 40),
                   placeholder: nil, for: url)
        let meta = URL(fileURLWithPath: disk.fileURL(for: url).path + ".meta")
        try FileManager.default.removeItem(at: meta)

        XCTAssertEqual(disk.pixelSize(for: url), ImageSize(width: 50, height: 40), "from the image header")
        XCTAssertEqual(disk.isAnimated(for: url), false, "from the container header")
        XCTAssertTrue(FileManager.default.fileExists(atPath: meta.path), "the sidecar is written back")
        let repaired = try XCTUnwrap(ImageMetaCodec.decode([UInt8](Data(contentsOf: meta))))
        XCTAssertEqual(repaired.pixelSize?.width, 50)
        XCTAssertEqual(repaired.animated, false)
    }

    // A sidecar whose bytes are gone answers nothing, as an extended attribute goes with its file on Apple.
    func testSidecarWithoutItsFileIsIgnored() throws {
        let disk = DiskCache(name: uniqueName(), byteLimit: 10 << 20)
        defer {
            try? FileManager.default.removeItem(at: disk.directoryURL)
        }
        let url = URL(string: "https://example.test/gone.png")!
        let grid = ImagePlaceholder(dimension: 6, cells: Array(repeating: ImageColor(red: 1, green: 2, blue: 3, alpha: 4), count: 36))
        disk.store(WindowsTestImages.png(width: 8, height: 8), pixelSize: ImageSize(width: 8, height: 8),
                   placeholder: grid, for: url)
        XCTAssertNotNil(disk.placeholder(for: url))
        try FileManager.default.removeItem(at: disk.fileURL(for: url))
        XCTAssertNil(disk.pixelSize(for: url))
        XCTAssertNil(disk.placeholder(for: url))
        XCTAssertNil(disk.isAnimated(for: url))
    }

    func testTrimEvictsOldestWithItsSidecar() throws {
        let png = WindowsTestImages.png(width: 64, height: 64)
        let disk = DiskCache(name: uniqueName(), byteLimit: png.count * 2 + 200)
        defer {
            try? FileManager.default.removeItem(at: disk.directoryURL)
        }
        let urls = (0..<3).map { URL(string: "https://example.test/\($0).png")! }
        for (index, url) in urls.enumerated() {
            disk.store(png, pixelSize: ImageSize(width: 64, height: 64), placeholder: nil, for: url)
            // Distinct modification times, whole seconds apart (Windows' stat has no finer field).
            try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(Double(index - 10) * 10)],
                                                  ofItemAtPath: disk.fileURL(for: url).path)
        }
        XCTAssertFalse(disk.fileExists(for: urls[0]), "the oldest goes")
        XCTAssertFalse(FileManager.default.fileExists(atPath: disk.fileURL(for: urls[0]).path + ".meta"))
        XCTAssertTrue(disk.fileExists(for: urls[1]))
        XCTAssertTrue(disk.fileExists(for: urls[2]))
    }

    // MARK: - Sidecar codec (the Android port's format) and memory cache, portable

    func testMetaCodecMatchesTheAndroidLayout() {
        let grid = ImagePlaceholder(dimension: 1, cells: [ImageColor(red: 1, green: 2, blue: 3, alpha: 4)])
        let meta = ImageMeta(pixelSize: (258, 3), animated: true, placeholder: grid)
        let bytes = ImageMetaCodec.encode(meta)
        XCTAssertEqual(bytes, [0xAC, 0x01, 0x0F, 2, 1, 0, 0, 3, 0, 0, 0, 1, 1, 2, 3, 4])
        XCTAssertEqual(ImageMetaCodec.decode(bytes), meta)
    }

    func testMemoryCacheEvictsLeastRecentlyUsed() {
        let cache = MemoryCache<Int>(countLimit: 2)
        cache.setObject(1, forKey: "a")
        cache.setObject(2, forKey: "b")
        XCTAssertEqual(cache.object(forKey: "a"), 1)   // "a" is now the most recently used
        cache.setObject(3, forKey: "c")
        XCTAssertNil(cache.object(forKey: "b"))
        XCTAssertEqual(cache.object(forKey: "a"), 1)
        XCTAssertEqual(cache.object(forKey: "c"), 3)
    }

    func testMemoryLimitsReachTheTiers() {
        let store = ImageStore(name: uniqueName(), memoryByteLimit: 5 * 1024 * 1024)
        stores.append(store)
        XCTAssertEqual(store.variantByteLimit, 5 * 1024 * 1024)
        XCTAssertEqual(store.originalByteLimit, 5 * 1024 * 1024)
        let recommended = ImageStore.recommendedMemoryByteLimit()
        XCTAssert((256 * 1024 * 1024...1024 * 1024 * 1024).contains(recommended), "\(recommended)")
    }

    // MARK: - Helpers

    private func uniqueName() -> String {
        "test-\(UUID().uuidString)"
    }

    private func makeStore(name: String? = nil, downloadByteLimit: Int = ImageStore.defaultDownloadByteLimit) -> ImageStore {
        let store = ImageStore(name: name ?? uniqueName(), downloadByteLimit: downloadByteLimit)
        stores.append(store)
        return store
    }

    // Loads and waits on the main queue; `check` runs inside the completion.
    private func load(_ store: ImageStore, _ request: ImageRequest, check: @escaping () -> Void = {}) -> PlatformImage? {
        var done = false
        var result: PlatformImage?
        store.load(request) { image in
            check()
            result = image
            done = true
        }
        XCTAssertTrue(pump { done }, "the completion ran")
        return result
    }

    // Runs the main run loop (which drains the main dispatch queue) until `done` or the timeout.
    private func pump(timeout: TimeInterval = 10, until done: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !done(), Date() < deadline {
            _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
        return done()
    }

    private func dataURL(png: Data) -> URL {
        URL(string: "data:image/png;base64," + png.base64EncodedString())!
    }
}

#endif
