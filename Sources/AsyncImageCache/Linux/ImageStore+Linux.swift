// Sources/AsyncImageCache/Linux/ImageStore+Linux.swift
//
// The public entry point on Linux, the counterpart of ImageStore.swift with the same API (ImageSize in place of
// CGSize): an async image loader + two-tier cache. EVERYTHING heavy - byte fetch, decode, downscale,
// corner-rounding - runs off the main thread on a concurrent work queue; the ONLY main-thread work is the final
// completion callback and the network calls' own dispatch.
//
// Two tiers:
//   - in-memory: MemoryCache maps of ready-to-draw variants (keyed by the full ImageRequest) and of originals
//     (raw transport bytes + natural pixel size, keyed by URL).
//   - on-disk: the ORIGINAL transport bytes (DiskCache), which survive relaunch and enable offline reads.
//
// Loading: data: and file: URLs are read on the work queue; http and https go through libsoup on the main
// context (MainContext), asynchronously, so no thread waits on the network. libsoup's session must stay on one
// thread, and the main context's is the one every GTK program runs.

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
import Dispatch
import Glibc
import Synchronization
import CAsyncImageCacheGtk
import CAsyncImageCacheSoup

/// The in-memory record of an original: the raw transport bytes, the natural pixel size, the placeholder grid
/// and the animated flag. Immutable.
private final class OriginalRecord: Sendable {
    let rawData: Data
    let pixelSize: ImageSize
    let placeholder: ImagePlaceholder?
    let isAnimated: Bool
    init(rawData: Data, pixelSize: ImageSize, placeholder: ImagePlaceholder?, isAnimated: Bool) {
        self.rawData = rawData
        self.pixelSize = pixelSize
        self.placeholder = placeholder
        self.isAnimated = isAnimated
    }
}

public final class ImageStore: @unchecked Sendable {

    public static let shared = ImageStore()

    private let variantCache: MemoryCache<PlatformImage>
    private let originalCache: MemoryCache<OriginalRecord>
    private let pixelSizeMemo = MemoryCache<ImageSize>(countLimit: 1000)   // sizes read from the sidecar
    private let placeholderMemo = MemoryCache<ImagePlaceholder>(countLimit: 1000)   // grids from the sidecar
    private let animatedMemo = MemoryCache<Bool>(countLimit: 1000)   // animated flags from the sidecar
    private let diskCache: DiskCache
    private let workQueue: DispatchQueue

    // De-duplicate concurrent identical requests: the first inserts an entry, later ones append their
    // completion, and all fire together when the single fetch finishes.
    private let inFlight = Mutex<[ImageRequest: [UncheckedSendableBox<(PlatformImage?) -> Void>]]>([:])

    /// - Parameters:
    ///   - name: names the on-disk subfolder and work queue; distinct names are fully independent caches.
    ///   - memoryCountLimit: max number of entries in EACH in-memory tier (variants, originals).
    ///   - memoryByteLimit: ceiling on the RAM held by EACH in-memory tier, by cost: decoded bitmap bytes for
    ///     variants, transport bytes for originals. Least recently used entries go first. Linux has no memory
    ///     pressure signal for the process (NSCache purges on one), so this is the whole bound. Defaults to
    ///     `recommendedMemoryByteLimit()`. Set it above the largest single decoded image you expect, or that
    ///     image cannot stay resident.
    ///   - diskByteLimit: soft byte budget for the on-disk original bytes.
    public init(name: String = "default",
                memoryCountLimit: Int = 150,
                memoryByteLimit: Int = ImageStore.recommendedMemoryByteLimit(),
                diskByteLimit: Int = 200 * 1024 * 1024) {
        let costLimit = max(0, memoryByteLimit)
        variantCache = MemoryCache(countLimit: memoryCountLimit, costLimit: costLimit)
        originalCache = MemoryCache(countLimit: memoryCountLimit, costLimit: costLimit)
        diskCache = DiskCache(name: name, byteLimit: diskByteLimit)
        workQueue = DispatchQueue(label: "com.richtextview.AsyncImageCache.\(name)", attributes: .concurrent)
    }

    /// A per-tier memory budget scaled to the machine's physical RAM: a sixteenth of it, between 256 MB and
    /// 1 GB, as for macOS (Linux desktops, no per-app memory limit).
    public static func recommendedMemoryByteLimit() -> Int {
        let fraction = Int(ProcessInfo.processInfo.physicalMemory / 16)
        return min(max(fraction, 256 * 1024 * 1024), 1024 * 1024 * 1024)
    }

    // MARK: - Synchronous lookups

    /// The ready-to-draw variant for the exact request, if in memory. nil on a miss. Thread-safe.
    public func cachedImage(for request: ImageRequest) -> PlatformImage? {
        variantCache.object(forKey: request.variantKey)
    }

    /// The natural PIXEL size of a URL's image, if known WITHOUT decoding. Thread-safe. Survives relaunch: the
    /// size rode along with the on-disk bytes in their sidecar, so this reads it and memoizes it.
    public func cachedPixelSize(for url: URL) -> ImageSize? {
        let key = url.absoluteString
        if let record = originalCache.object(forKey: key) {
            return record.pixelSize
        }
        if let memo = pixelSizeMemo.object(forKey: key) {
            return memo
        }
        if let size = diskCache.pixelSize(for: url) {
            pixelSizeMemo.setObject(size, forKey: key)
            return size
        }
        return nil
    }

    /// The placeholder grid for a URL's image, if known WITHOUT decoding; nil when none was stored. Thread-safe
    /// and, like the size, survives relaunch.
    public func placeholder(for url: URL) -> ImagePlaceholder? {
        let key = url.absoluteString
        if let record = originalCache.object(forKey: key) {
            return record.placeholder
        }
        if let memo = placeholderMemo.object(forKey: key) {
            return memo
        }
        if let placeholder = diskCache.placeholder(for: url) {
            placeholderMemo.setObject(placeholder, forKey: key)
            return placeholder
        }
        return nil
    }

    /// The placeholder grid as a small texture (GTK interpolates it into a soft gradient when it is drawn
    /// larger), or nil if no placeholder is known for the URL.
    public func placeholderImage(for url: URL) -> PlatformImage? {
        guard let grid = placeholder(for: url) else {
            return nil
        }
        return ImageProcessing.gridImage(from: grid)
    }

    /// Whether the URL's image is a multi-frame (animated) source. Thread-safe and decode-free; false when
    /// unknown (the flag is known only AFTER the image has passed through the cache once).
    public func isAnimated(for url: URL) -> Bool {
        let key = url.absoluteString
        if let record = originalCache.object(forKey: key) {
            return record.isAnimated
        }
        if let memo = animatedMemo.object(forKey: key) {
            return memo
        }
        if let animated = diskCache.isAnimated(for: url) {
            animatedMemo.setObject(animated, forKey: key)
            return animated
        }
        return false
    }

    /// The ORIGINAL transport bytes + natural pixel size for a loaded URL, or nil if not in memory.
    public func cachedOriginalBytes(for url: URL) -> (data: Data, pixelSize: ImageSize)? {
        guard let record = originalCache.object(forKey: url.absoluteString) else {
            return nil
        }
        return (record.rawData, record.pixelSize)
    }

    // MARK: - Loading

    /// Resolve the ready-to-draw variant for `request`, calling `completion` on the MAIN thread (the GLib main
    /// context's), always after this call returns. The byte fetch / decode / downscale / rounding happen off-main.
    public func load(_ request: ImageRequest, completion: @escaping (PlatformImage?) -> Void) {
        if let cached = variantCache.object(forKey: request.variantKey) {
            deliver(cached, to: [UncheckedSendableBox(completion)])
            return
        }
        let first = inFlight.withLock { table -> Bool in
            if table[request] != nil {
                table[request]?.append(UncheckedSendableBox(completion))
                return false
            }
            table[request] = [UncheckedSendableBox(completion)]
            return true
        }
        guard first else {
            return
        }
        workQueue.async { [self] in
            startProduction(request)
        }
    }

    public func clearMemory() {
        variantCache.removeAllObjects()
        originalCache.removeAllObjects()
        pixelSizeMemo.removeAllObjects()
        placeholderMemo.removeAllObjects()
        animatedMemo.removeAllObjects()
    }

    public func removeAll() {
        clearMemory()
        diskCache.removeAll()
    }

    // MARK: - Test hooks (internal)

    var diskDirectoryURL: URL {
        diskCache.directoryURL
    }

    func diskFileExists(for url: URL) -> Bool {
        diskCache.fileExists(for: url)
    }

    var variantByteLimit: Int { variantCache.costLimit }
    var originalByteLimit: Int { originalCache.costLimit }

    // MARK: - Off-main pipeline

    // Resolve original bytes (memory -> disk -> source) and hand them to finishProduction. Runs on the work queue.
    private func startProduction(_ request: ImageRequest) {
        let url = request.url
        if let record = originalCache.object(forKey: url.absoluteString) {
            finishProduction(request, bytes: record.rawData, writeDisk: false)
            return
        }
        if let disk = diskCache.data(for: url) {
            finishProduction(request, bytes: disk, writeDisk: false)
            return
        }
        switch url.scheme?.lowercased() {
        case "file":
            finishProduction(request, bytes: url.isFileURL ? try? Data(contentsOf: url) : nil, writeDisk: true)
        case "data":
            finishProduction(request, bytes: Self.decodeDataURL(url.absoluteString), writeDisk: true)
        case "http", "https":
            HTTPLoader.fetch(url.absoluteString) { [self] bytes in
                workQueue.async { [self] in
                    finishProduction(request, bytes: bytes, writeDisk: true)
                }
            }
        default:
            finishProduction(request, bytes: nil, writeDisk: false)
        }
    }

    // Decode, record the original (+ disk write for fresh bytes), build + cache the ready-to-draw variant,
    // then fire the pending completions. Runs on the work queue; nil bytes (fetch failed) delivers nil.
    private func finishProduction(_ request: ImageRequest, bytes: Data?, writeDisk: Bool) {
        var variant: PlatformImage?
        if let bytes, let decoded = ImageProcessing.decode(bytes) {
            recordOriginal(url: request.url, data: bytes, decoded: decoded, writeDisk: writeDisk)
            if let built = ImageProcessing.variant(from: decoded,
                                                   targetWidth: request.quantizedTargetWidth.map { ImageLength($0) },
                                                   cornerRadius: ImageLength(request.quantizedCornerRadius)) {
                variantCache.setObject(built, forKey: request.variantKey, cost: ImageProcessing.memoryCost(of: built))
                variant = built
            }
        }
        let pending = inFlight.withLock { $0.removeValue(forKey: request) } ?? []
        deliver(variant, to: pending)
    }

    // Record the raw bytes + natural pixel size in memory and (for freshly fetched bytes) persist the ORIGINAL
    // transport bytes to disk.
    private func recordOriginal(url: URL, data: Data, decoded: DecodedImage, writeDisk: Bool) {
        let pixelSize = ImageProcessing.pixelSize(of: decoded)
        let placeholder = ImageProcessing.placeholder(of: decoded)
        let isAnimated = ImageProcessing.isAnimated(data: data)
        originalCache.setObject(OriginalRecord(rawData: data, pixelSize: pixelSize,
                                               placeholder: placeholder, isAnimated: isAnimated),
                                forKey: url.absoluteString, cost: max(1, data.count))
        if writeDisk {
            diskCache.store(data, pixelSize: pixelSize, placeholder: placeholder, isAnimated: isAnimated, for: url)
        } else if let placeholder {
            // Bytes came from the cache: a file whose sidecar lost its grid never passes through store() again,
            // so repair it here.
            diskCache.storePlaceholderIfMissing(placeholder, for: url)
        }
    }

    // A data: URL's bytes (base64 or percent-encoded), by libsoup's decoder, which is safe on any thread.
    static func decodeDataURL(_ string: String) -> Data? {
        guard let bytes = soup_uri_decode_data_uri(string, nil) else {
            return nil
        }
        defer {
            g_bytes_unref(bytes)
        }
        var size: gsize = 0
        guard let start = g_bytes_get_data(bytes, &size), size > 0 else {
            return nil
        }
        return Data(bytes: start, count: Int(size))
    }

    // The ONLY main-thread work besides the network's: fire the pending completions.
    private func deliver(_ image: PlatformImage?, to completions: [UncheckedSendableBox<(PlatformImage?) -> Void>]) {
        guard !completions.isEmpty else {
            return
        }
        let payload = UncheckedSendableBox(completions)
        MainContext.async {
            for completion in payload.value {
                completion.value(image)
            }
        }
    }
}

// http and https through one libsoup session, used only on the main context's thread.
private enum HTTPLoader {

    // How long one step of a request (connecting, a read, a write) may wait, in seconds, as URLSession's
    // default request timeout does on Apple platforms.
    private static let timeout: guint = 60

    // Touched only on the main context's thread (inside MainContext.async and libsoup's callbacks).
    nonisolated(unsafe) private static var session: UnsafeMutablePointer<SoupSession>?

    private final class Pending {
        let message: OpaquePointer
        let done: @Sendable (Data?) -> Void
        init(message: OpaquePointer, done: @escaping @Sendable (Data?) -> Void) {
            self.message = message
            self.done = done
        }
    }

    // The response body worth caching, or nil: a status outside 200-299 is rejected, so an error page (some
    // CDNs serve a placeholder image or an HTML error with a 404/500) is never decoded or persisted.
    private static let ready: @convention(c) (UnsafeMutablePointer<GObject>?, OpaquePointer?, gpointer?) -> Void = {
        source, result, data in
        guard let data else {
            return
        }
        let pending = Unmanaged<Pending>.fromOpaque(data).takeRetainedValue()
        var error: UnsafeMutablePointer<GError>?
        let bytes = soup_session_send_and_read_finish(UnsafeMutableRawPointer(source)?.assumingMemoryBound(to: SoupSession.self),
                                                      result, &error)
        if let error {
            g_error_free(error)
        }
        let status = soup_message_get_status(pending.message).rawValue
        g_object_unref(UnsafeMutableRawPointer(pending.message))
        var body: Data?
        if let bytes {
            var size: gsize = 0
            if (200...299).contains(status), let start = g_bytes_get_data(bytes, &size), size > 0 {
                body = Data(bytes: start, count: Int(size))
            }
            g_bytes_unref(bytes)
        }
        pending.done(body)
    }

    /// Fetches `url` and passes the body (or nil) to `done`, which runs on the main context's thread.
    static func fetch(_ url: String, _ done: @escaping @Sendable (Data?) -> Void) {
        MainContext.async {
            guard let message = soup_message_new("GET", url) else {
                done(nil)
                return
            }
            let session = sharedSession()
            let pending = Unmanaged.passRetained(Pending(message: message, done: done)).toOpaque()
            soup_session_send_and_read_async(session, message, G_PRIORITY_DEFAULT, nil, ready, pending)
        }
    }

    // A session without a cache of its own (DiskCache already keeps the fetched bytes), sending a User-Agent
    // (libsoup sends none by default, and some image hosts refuse such requests; the trailing space makes
    // libsoup add its own name and version) and allowing six connections per host, as URLSession does
    // (libsoup's default is two). Both are construct-time properties, set through GValues because the C
    // property setters are variadic.
    private static func sharedSession() -> UnsafeMutablePointer<SoupSession> {
        if let session {
            return session
        }
        var values = [GValue(), GValue(), GValue()]
        g_value_init(&values[0], GType(16 << G_TYPE_FUNDAMENTAL_SHIFT))   // G_TYPE_STRING
        g_value_set_string(&values[0], "AsyncImageCache ")
        g_value_init(&values[1], GType(6 << G_TYPE_FUNDAMENTAL_SHIFT))    // G_TYPE_INT
        g_value_set_int(&values[1], 6)
        g_value_init(&values[2], GType(7 << G_TYPE_FUNDAMENTAL_SHIFT))    // G_TYPE_UINT
        g_value_set_uint(&values[2], timeout)
        let made = withArrayOfCStrings(["user-agent", "max-conns-per-host", "timeout"]) { names in
            g_object_new_with_properties(soup_session_get_type(), 3, names, values)
        }
        for index in values.indices {
            g_value_unset(&values[index])
        }
        let typed = UnsafeMutableRawPointer(made!).assumingMemoryBound(to: SoupSession.self)
        session = typed
        return typed
    }

    // Calls `body` with the strings as a C array of C strings, valid during the call.
    private static func withArrayOfCStrings<R>(_ strings: [String],
                                               _ body: (UnsafeMutablePointer<UnsafePointer<CChar>?>) -> R) -> R {
        let copies = strings.map { strdup($0) }
        defer {
            copies.forEach { free($0) }
        }
        var pointers = copies.map { UnsafePointer($0) }
        return pointers.withUnsafeMutableBufferPointer { body($0.baseAddress!) }
    }
}
