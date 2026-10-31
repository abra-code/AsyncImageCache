// Tests/AsyncImageCacheTests/Linux/LinuxImageStoreTests.swift
//
// The Linux store, disk cache, memory cache and sidecar codec. Completions run on the GLib main context, so the
// tests iterate it while they wait, as a GTK program's main loop would; http runs against a local libsoup server.

import XCTest
import Foundation
import CAsyncImageCacheGtk
import CAsyncImageCacheSoup
@testable import AsyncImageCache

final class LinuxImageStoreTests: XCTestCase {

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
        let request = ImageRequest(url: dataURL(png: try pngData(width: 24, height: 24)))
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
        let request = ImageRequest(url: dataURL(png: try pngData(width: 8, height: 8)))
        XCTAssertNotNil(load(store, request))
        var called = false
        store.load(request) { _ in called = true }
        XCTAssertFalse(called, "a memory hit completes after load returns, as on Apple's main queue")
        XCTAssertTrue(pump { called })
    }

    func testDownscaleToTargetWidth() throws {
        let store = makeStore()
        let image = try XCTUnwrap(load(store, ImageRequest(url: dataURL(png: try pngData(width: 100, height: 50)),
                                                         targetWidth: 40)))
        XCTAssertEqual([image.pixelWidth, image.pixelHeight], [40, 20])
    }

    func testConcurrentIdenticalRequestsShareOneResult() throws {
        let store = makeStore()
        let request = ImageRequest(url: dataURL(png: try pngData(width: 16, height: 16)))
        var results: [PlatformImage?] = []
        store.load(request) { results.append($0) }
        store.load(request) { results.append($0) }
        XCTAssertTrue(pump { results.count == 2 })
        XCTAssertNotNil(results[0])
        XCTAssertTrue(results[0] === results[1], "one production serves both")
    }

    func testFileURLPersistsAcrossStoresAndRelaunch() throws {
        let name = uniqueName()
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("\(name).png")
        try pngData(width: 30, height: 20).write(to: file)
        defer {
            try? FileManager.default.removeItem(at: file)
        }
        let first = makeStore(name: name)
        XCTAssertNotNil(load(first, ImageRequest(url: file)))

        // A new store of the same name (a relaunch): the size, grid and flag come from the sidecar, no decode.
        let second = ImageStore(name: name)
        XCTAssertEqual(second.cachedPixelSize(for: file), ImageSize(width: 30, height: 20))
        XCTAssertNotNil(second.placeholder(for: file))
        XCTAssertFalse(second.isAnimated(for: file))
        // ...and the bytes come from disk even when the source is gone.
        try FileManager.default.removeItem(at: file)
        let image = try XCTUnwrap(load(second, ImageRequest(url: file, targetWidth: 15)))
        XCTAssertEqual([image.pixelWidth, image.pixelHeight], [15, 10])
    }

    func testUnknownSchemeAndUndecodableBytesDeliverNil() {
        let store = makeStore()
        XCTAssertNil(load(store, ImageRequest(url: URL(string: "ftp://example.test/i.png")!)))
        XCTAssertNil(load(store, ImageRequest(url: URL(string: "data:text/plain;base64,aGVsbG8=")!)))
    }

    func testHTTPKeepsSuccessAndRejectsErrorStatus() throws {
        let server = try LocalServer(png: try pngData(width: 12, height: 6))
        defer {
            server.stop()
        }
        let store = makeStore()
        let ok = try XCTUnwrap(URL(string: "http://127.0.0.1:\(server.port)/ok.png"))
        let image = try XCTUnwrap(load(store, ImageRequest(url: ok)), "a 200 response decodes")
        XCTAssertEqual([image.pixelWidth, image.pixelHeight], [12, 6])
        XCTAssertTrue(store.diskFileExists(for: ok))
        XCTAssertEqual(server.userAgent?.hasPrefix("AsyncImageCache "), true, "a User-Agent is sent: \(server.userAgent ?? "none")")

        // A 404 whose body IS an image must still not become a cached image.
        let missing = try XCTUnwrap(URL(string: "http://127.0.0.1:\(server.port)/missing.png"))
        XCTAssertNil(load(store, ImageRequest(url: missing)))
        XCTAssertFalse(store.diskFileExists(for: missing), "an error page is never persisted")
    }

    // MARK: - Disk cache

    // The same file names as the Apple cache (CryptoKit's SHA-256 there, GChecksum here).
    func testDiskFileNameIsTheURLsSHA256() {
        let disk = DiskCache(name: uniqueName(), byteLimit: 1 << 20)
        defer {
            try? FileManager.default.removeItem(at: disk.directoryURL)
        }
        let file = disk.fileURL(for: URL(string: "https://example.test/i.png")!)
        XCTAssertEqual(file.lastPathComponent, "ed0321a5ad41ee2261789123c6f483f6f5c6e194ddddf38ddefa583b4e4e8dbb")
    }

    func testLostSidecarIsRepairedFromTheHeader() throws {
        let disk = DiskCache(name: uniqueName(), byteLimit: 10 << 20)
        defer {
            try? FileManager.default.removeItem(at: disk.directoryURL)
        }
        let url = URL(string: "https://example.test/no-meta.png")!
        disk.store(try pngData(width: 50, height: 40), pixelSize: ImageSize(width: 50, height: 40),
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
        disk.store(try pngData(width: 8, height: 8), pixelSize: ImageSize(width: 8, height: 8), placeholder: grid, for: url)
        XCTAssertNotNil(disk.placeholder(for: url))
        try FileManager.default.removeItem(at: disk.fileURL(for: url))
        XCTAssertNil(disk.pixelSize(for: url))
        XCTAssertNil(disk.placeholder(for: url))
        XCTAssertNil(disk.isAnimated(for: url))
    }

    func testTrimEvictsOldestWithItsSidecar() throws {
        let png = try pngData(width: 64, height: 64)
        let disk = DiskCache(name: uniqueName(), byteLimit: png.count * 2 + 200)
        defer {
            try? FileManager.default.removeItem(at: disk.directoryURL)
        }
        let urls = (0..<3).map { URL(string: "https://example.test/\($0).png")! }
        for url in urls {
            disk.store(png, pixelSize: ImageSize(width: 64, height: 64), placeholder: nil, for: url)
            usleep(20_000)   // distinct modification times
        }
        XCTAssertFalse(disk.fileExists(for: urls[0]), "the oldest goes")
        XCTAssertFalse(FileManager.default.fileExists(atPath: disk.fileURL(for: urls[0]).path + ".meta"))
        XCTAssertTrue(disk.fileExists(for: urls[1]))
        XCTAssertTrue(disk.fileExists(for: urls[2]))
    }

    // MARK: - Sidecar codec (the Android port's format)

    func testMetaCodecMatchesTheAndroidLayout() {
        let grid = ImagePlaceholder(dimension: 1, cells: [ImageColor(red: 1, green: 2, blue: 3, alpha: 4)])
        let meta = ImageMeta(pixelSize: (258, 3), animated: true, placeholder: grid)
        let bytes = ImageMetaCodec.encode(meta)
        XCTAssertEqual(bytes, [0xAC, 0x01, 0x0F, 2, 1, 0, 0, 3, 0, 0, 0, 1, 1, 2, 3, 4])
        XCTAssertEqual(ImageMetaCodec.decode(bytes), meta)

        // Known not animated differs from unknown.
        XCTAssertEqual(ImageMetaCodec.decode(ImageMetaCodec.encode(ImageMeta(animated: false)))?.animated, false)
        XCTAssertNil(ImageMetaCodec.decode(ImageMetaCodec.encode(ImageMeta()))?.animated)
        // A declared size cut short is corrupt; a corrupt grid is dropped and the rest kept.
        XCTAssertNil(ImageMetaCodec.decode([0xAC, 0x01, 0x01, 1, 0, 0]))
        let badGrid = ImageMetaCodec.decode([0xAC, 0x01, 0x0B, 5, 0, 0, 0, 6, 0, 0, 0, 2, 9])
        XCTAssertEqual(badGrid?.pixelSize?.height, 6)
        XCTAssertNil(badGrid?.placeholder)
        XCTAssertNil(ImageMetaCodec.decode([0xAB, 0x01, 0x00]), "wrong magic")
    }

    // MARK: - Memory cache

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

    func testMemoryCacheCostLimit() {
        let cache = MemoryCache<Int>(costLimit: 100)
        cache.setObject(1, forKey: "a", cost: 60)
        cache.setObject(2, forKey: "b", cost: 30)
        cache.setObject(3, forKey: "c", cost: 30)   // 120 > 100: "a" goes
        XCTAssertNil(cache.object(forKey: "a"))
        XCTAssertEqual(cache.count, 2)
        cache.setObject(4, forKey: "d", cost: 101)   // over the limit by itself: not kept
        XCTAssertNil(cache.object(forKey: "d"))
        XCTAssertEqual(cache.count, 2)
        cache.setObject(5, forKey: "b", cost: 10)   // replacing updates the cost
        cache.setObject(6, forKey: "e", cost: 60)
        XCTAssertEqual(cache.object(forKey: "b"), 5)
        XCTAssertEqual(cache.object(forKey: "e"), 6)
        cache.removeAllObjects()
        XCTAssertEqual(cache.count, 0)
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

    private func makeStore(name: String? = nil) -> ImageStore {
        let store = ImageStore(name: name ?? uniqueName())
        stores.append(store)
        return store
    }

    // Loads and waits on the main context; `check` runs inside the completion.
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

    // Iterates the GLib main context until `done` or the timeout.
    private func pump(timeout: TimeInterval = 10, until done: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !done(), Date() < deadline {
            if g_main_context_iteration(nil, 0) == 0 {
                usleep(1000)
            }
        }
        return done()
    }

    private func pngData(width: Int, height: Int) throws -> Data {
        let pixbuf = try XCTUnwrap(gdk_pixbuf_new(GDK_COLORSPACE_RGB, 1, 8, Int32(width), Int32(height)))
        defer {
            g_object_unref(UnsafeMutableRawPointer(pixbuf))
        }
        gdk_pixbuf_fill(pixbuf, 0x3366CCFF)
        var buffer: UnsafeMutablePointer<gchar>?
        var size: gsize = 0
        var error: UnsafeMutablePointer<GError>?
        let saved = gdk_pixbuf_save_to_bufferv(pixbuf, &buffer, &size, "png", nil, nil, &error)
        if let error {
            g_error_free(error)
        }
        let start = try XCTUnwrap(buffer)
        defer {
            g_free(start)
        }
        XCTAssertNotEqual(saved, 0)
        return Data(bytes: start, count: Int(size))
    }

    private func dataURL(png: Data) -> URL {
        URL(string: "data:image/png;base64," + png.base64EncodedString())!
    }
}

// A libsoup server on 127.0.0.1 serving `png` at /ok.png with status 200 and at /missing.png with 404.
private final class LocalServer {
    private final class Body {
        let png: Data
        var userAgent: String?
        init(_ png: Data) {
            self.png = png
        }
    }

    private let server: UnsafeMutablePointer<SoupServer>
    private let body: Unmanaged<Body>
    let port: Int

    init(png: Data) throws {
        let made = try XCTUnwrap(g_object_new_with_properties(soup_server_get_type(), 0, nil, nil))
        server = UnsafeMutableRawPointer(made).assumingMemoryBound(to: SoupServer.self)
        body = Unmanaged.passRetained(Body(png))
        soup_server_add_handler(server, nil, { _, message, path, _, data in
            guard let message, let path, let data else {
                return
            }
            let body = Unmanaged<Body>.fromOpaque(data).takeUnretainedValue()
            let png = body.png
            if let agent = soup_message_headers_get_one(soup_server_message_get_request_headers(message), "User-Agent") {
                body.userAgent = String(cString: agent)
            }
            let status: guint = String(cString: path) == "/ok.png" ? 200 : 404
            soup_server_message_set_status(message, status, nil)
            png.withUnsafeBytes { raw in
                soup_server_message_set_response(message, "image/png", SOUP_MEMORY_COPY,
                                                 raw.baseAddress?.assumingMemoryBound(to: CChar.self), gsize(raw.count))
            }
        }, body.toOpaque(), nil)
        var error: UnsafeMutablePointer<GError>?
        let listening = soup_server_listen_local(server, 0, SOUP_SERVER_LISTEN_IPV4_ONLY, &error)
        if let error {
            g_error_free(error)
        }
        guard listening != 0, let uris = soup_server_get_uris(server), let first = uris.pointee.data else {
            soup_server_disconnect(server)
            g_object_unref(UnsafeMutableRawPointer(server))
            body.release()
            throw XCTSkip("no local server")
        }
        port = Int(g_uri_get_port(OpaquePointer(first)))
        g_slist_free_full(uris, { g_uri_unref(OpaquePointer($0)) })
    }

    /// The User-Agent of the last request.
    var userAgent: String? {
        body.takeUnretainedValue().userAgent
    }

    func stop() {
        soup_server_disconnect(server)
        g_object_unref(UnsafeMutableRawPointer(server))
        body.release()
    }
}
