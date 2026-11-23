// Sources/AsyncImageCache/ImageStore.swift
//
// The public entry point: an async image loader + two-tier cache. EVERYTHING heavy - byte fetch, decode,
// downscale, corner-rounding, encoding - runs off the main thread on a concurrent work queue; the ONLY
// main-thread work is the final completion callback.
//
// Two tiers:
//   - in-memory: an NSCache of ready-to-draw variants (keyed by the full ImageRequest) + an NSCache of
//     originals (raw transport bytes + natural pixel size, keyed by URL). A local file: image's keys also
//     carry the file's modification time and size (fileVersion), so after the file is edited a lookup misses
//     and the next load reads the new picture; the old entries age out.
//   - on-disk: the ORIGINAL transport bytes (DiskCache), which survive relaunch and enable offline reads. Not
//     for local file: images, which are read from their file again; what the docs below say survives relaunch
//     (pixel size, placeholder, animated flag) is then known only while the image is in memory.
//
// Size-known-upfront: once an image has been loaded once, `cachedPixelSize(for:)` returns its natural size
// synchronously, so a consumer can reserve layout space before the pixels of a later variant arrive.
//
// This is a `final class`, not an actor, because the cached* lookups must be synchronous. Thread safety comes
// from NSCache (already thread-safe) plus an NSLock guarding the in-flight de-duplication table.

import Foundation
import CoreGraphics

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// The in-memory record of an original: the raw transport bytes (memory tier for the byte resolve), the
/// natural pixel size, and the placeholder grid. Immutable, so it is safely `Sendable` in NSCache.
private final class OriginalRecord: Sendable {
    let rawData: Data
    let pixelSize: CGSize
    let placeholder: ImagePlaceholder?
    let isAnimated: Bool
    init(rawData: Data, pixelSize: CGSize, placeholder: ImagePlaceholder?, isAnimated: Bool) {
        self.rawData = rawData
        self.pixelSize = pixelSize
        self.placeholder = placeholder
        self.isAnimated = isAnimated
    }
}

/// A boxed CGSize for the xattr-sourced pixel-size memo (NSCache values must be classes).
private final class SizeBox: Sendable {
    let size: CGSize
    init(_ size: CGSize) {
        self.size = size
    }
}

/// A boxed ImagePlaceholder for the xattr-sourced placeholder memo (NSCache values must be classes).
private final class PlaceholderBox: Sendable {
    let placeholder: ImagePlaceholder
    init(_ placeholder: ImagePlaceholder) {
        self.placeholder = placeholder
    }
}

public final class ImageStore: @unchecked Sendable {

    public static let shared = ImageStore()

    private let variantCache = NSCache<NSString, PlatformImage>()
    private let originalCache = NSCache<NSString, OriginalRecord>()
    private let pixelSizeMemo = NSCache<NSString, SizeBox>()   // sizes read from the disk xattr, memoized
    private let placeholderMemo = NSCache<NSString, PlaceholderBox>()   // placeholder grids from the xattr
    private let animatedMemo = NSCache<NSString, NSNumber>()   // animated flag read from the disk xattr
    private let diskCache: DiskCache
    private let workQueue: DispatchQueue

    // De-duplicate concurrent identical requests: the first inserts an entry, later ones append their
    // completion, and all fire together when the single fetch finishes. Guarded by `lock`.
    private let lock = NSLock()
    private var inFlight: [ImageRequest: [(PlatformImage?) -> Void]] = [:]
    private var currentDownloadByteLimit: Int   // guarded by `lock`

    /// The default `downloadByteLimit`: 32 MB, past any photo a web page shows. A raw camera file or a photo
    /// saved with little compression can be larger; a host that shows those raises the limit.
    public static let defaultDownloadByteLimit = 32 * 1024 * 1024

    /// The most bytes one http or https download may bring, so a server cannot fill memory with an endless or
    /// huge body. A response that declares a larger size is refused at once, and one that sends more is cut off
    /// when it passes the limit; the load then delivers nil, as for a failed download, and nothing is cached.
    /// Images read from a file or a data: URL, and bytes already in the cache, are not limited. Thread-safe; a
    /// new value applies to downloads that start after it is set, so a host sets it at launch, for example
    /// `ImageStore.shared.downloadByteLimit = 200 * 1024 * 1024` for raw camera files. A negative value counts
    /// as 0; `Int.max` removes the limit.
    public var downloadByteLimit: Int {
        get {
            lock.lock()
            defer {
                lock.unlock()
            }
            return currentDownloadByteLimit
        }
        set {
            lock.lock()
            currentDownloadByteLimit = max(0, newValue)
            lock.unlock()
        }
    }

    /// - Parameters:
    ///   - name: names the on-disk subdirectory and work queue; distinct names are fully independent caches.
    ///   - memoryCountLimit: max number of entries in EACH in-memory tier (variants, originals).
    ///   - memoryByteLimit: soft ceiling on the RAM held by EACH in-memory tier, enforced by NSCache cost. The
    ///     dominant consumer is the variant cache, whose entries are DECODED bitmaps (a 12 MP image is ~48 MB
    ///     resident however well it compressed) - so this bounds wired memory in a way a bare count cannot.
    ///     Both a count and a cost limit are active; NSCache evicts (approximately, LRU-ish) when either is
    ///     exceeded, and ALSO purges automatically under system memory pressure - so this is an upper bound,
    ///     not a reservation. Defaults to `recommendedMemoryByteLimit()`, which scales with device RAM. Set it
    ///     comfortably above the largest single decoded image you expect, or that image cannot stay resident.
    ///   - diskByteLimit: soft byte budget for the on-disk original bytes.
    ///   - downloadByteLimit: the most bytes one http or https download may bring (see `downloadByteLimit`).
    public init(name: String = "default",
                memoryCountLimit: Int = 150,
                memoryByteLimit: Int = ImageStore.recommendedMemoryByteLimit(),
                diskByteLimit: Int = 200 * 1024 * 1024,
                downloadByteLimit: Int = ImageStore.defaultDownloadByteLimit) {
        currentDownloadByteLimit = max(0, downloadByteLimit)
        variantCache.countLimit = memoryCountLimit
        originalCache.countLimit = memoryCountLimit
        variantCache.totalCostLimit = max(0, memoryByteLimit)
        originalCache.totalCostLimit = max(0, memoryByteLimit)
        diskCache = DiskCache(name: name, byteLimit: diskByteLimit)
        workQueue = DispatchQueue(label: "com.richtextview.AsyncImageCache.\(name)", attributes: .concurrent)
    }

    /// A per-tier memory budget scaled to the device's physical RAM. A fixed default is wrong at both ends:
    /// too low starves a modern 8 GB iPhone or a 64 GB Mac; too high risks a jetsam kill on an older iOS
    /// device (which enforces a per-app limit far below total RAM) or in an app extension (a share/notification
    /// extension gets only tens of MB). So: a fraction of `physicalMemory`, clamped to a platform floor and
    /// ceiling. macOS gets a higher ceiling (no jetsam, and desktops routinely have 16-128 GB); iOS stays
    /// conservative because NSCache's automatic memory-pressure purge is the real safety net, not this number.
    /// This is `public` and cheap (one `ProcessInfo` read) so callers can reuse or scale it explicitly.
    public static func recommendedMemoryByteLimit() -> Int {
        let physical = ProcessInfo.processInfo.physicalMemory   // total device RAM, in bytes
        let fraction = Int(physical / 16)
        #if os(macOS)
        let floorBytes = 256 * 1024 * 1024
        let ceilingBytes = 1024 * 1024 * 1024
        #else
        let floorBytes = 64 * 1024 * 1024
        let ceilingBytes = 320 * 1024 * 1024
        #endif
        return min(max(fraction, floorBytes), ceilingBytes)
    }

    // MARK: - Synchronous lookups

    /// The ready-to-draw variant for the exact request, if in memory. nil on a miss. Thread-safe.
    public func cachedImage(for request: ImageRequest) -> PlatformImage? {
        variantCache.object(forKey: Self.variantKey(request, Self.fileVersion(of: request.url)) as NSString)
    }

    /// The natural PIXEL size of a URL's image, if known WITHOUT decoding. Thread-safe. Lets a consumer
    /// reserve layout space before the pixels arrive - including across relaunch: memory is empty then, but
    /// the size rode along with the on-disk bytes as an extended attribute, so this reads it (a cheap
    /// getxattr, no decode) and memoizes it so repeated layout queries stay memory-fast.
    public func cachedPixelSize(for url: URL) -> CGSize? {
        let key = url.absoluteString as NSString
        if let record = originalCache.object(forKey: Self.originalKey(url, Self.fileVersion(of: url)) as NSString) {
            return record.pixelSize
        }
        if let memo = pixelSizeMemo.object(forKey: key) {
            return memo.size
        }
        if let size = diskCache.pixelSize(for: url) {
            pixelSizeMemo.setObject(SizeBox(size), forKey: key)
            return size
        }
        return nil
    }

    /// The placeholder grid for a URL's image, if known WITHOUT decoding - a soft preview to fill the reserved
    /// box while the pixels load, instead of flat gray. Thread-safe, and (like the size) survives relaunch via
    /// the on-disk xattr. Returns nil when no placeholder was stored (the caller then uses a neutral fallback);
    /// there is no decode fallback, since the grid needs the actual pixels.
    public func placeholder(for url: URL) -> ImagePlaceholder? {
        let key = url.absoluteString as NSString
        if let record = originalCache.object(forKey: Self.originalKey(url, Self.fileVersion(of: url)) as NSString) {
            return record.placeholder
        }
        if let memo = placeholderMemo.object(forKey: key) {
            return memo.placeholder
        }
        if let placeholder = diskCache.placeholder(for: url) {
            placeholderMemo.setObject(PlaceholderBox(placeholder), forKey: key)
            return placeholder
        }
        return nil
    }

    /// The placeholder grid rendered as a ready-to-draw image (the soft-gradient preview), or nil if no
    /// placeholder is known for the URL. A convenience over `placeholder(for:)` for consumers that render
    /// outside SwiftUI (a UIView/NSView) - `CachedImage` shows this automatically while loading. Like the
    /// grid itself, it is available only AFTER the image has been loaded once (the preview is derived from the
    /// pixels), and it then survives relaunch via the on-disk xattr.
    public func placeholderImage(for url: URL) -> PlatformImage? {
        guard let grid = placeholder(for: url) else {
            return nil
        }
        return ImageProcessing.gridImage(from: grid)
    }

    /// Whether the URL's image is a multi-frame (animated) source - an animated GIF/APNG/WebP. Thread-safe and
    /// decode-free: resolves memory `originalCache` -> `animatedMemo` -> the on-disk xattr (with a header-count
    /// fallback), so it survives relaunch. Returns false when unknown - like the pixel size and placeholder,
    /// the flag is known only AFTER the image has passed through the cache once. The ready-to-draw variant is
    /// always a single flattened frame; a consumer that wants playback reads `cachedOriginalBytes(for:)` and
    /// drives its own animated renderer (see the design notes) - this is the signal to decide whether to.
    public func isAnimated(for url: URL) -> Bool {
        let key = url.absoluteString as NSString
        if let record = originalCache.object(forKey: Self.originalKey(url, Self.fileVersion(of: url)) as NSString) {
            return record.isAnimated
        }
        if let memo = animatedMemo.object(forKey: key) {
            return memo.boolValue
        }
        if let animated = diskCache.isAnimated(for: url) {
            animatedMemo.setObject(NSNumber(value: animated), forKey: key)
            return animated
        }
        return false
    }

    /// The ORIGINAL transport bytes + natural pixel size for a loaded URL, or nil if not loaded. For
    /// consumers that need the source bytes (e.g. producing embeddable copy data) - the cache stays generic
    /// and does no format transcoding itself; the consumer decides how to encode.
    public func cachedOriginalBytes(for url: URL) -> (data: Data, pixelSize: CGSize)? {
        guard let record = originalCache.object(forKey: Self.originalKey(url, Self.fileVersion(of: url)) as NSString) else {
            return nil
        }
        return (record.rawData, record.pixelSize)
    }

    // MARK: - Loading

    /// Resolve the ready-to-draw variant for `request`, calling `completion` on the MAIN thread. A memory hit
    /// delivers immediately; otherwise the byte fetch / decode / downscale / rounding all happen off-main.
    public func load(_ request: ImageRequest, completion: @escaping (PlatformImage?) -> Void) {
        if let cached = variantCache.object(forKey: Self.variantKey(request, Self.fileVersion(of: request.url)) as NSString) {
            deliver(cached, to: [completion])
            return
        }

        lock.lock()
        if inFlight[request] != nil {
            inFlight[request]?.append(completion)
            lock.unlock()
            return
        }
        inFlight[request] = [completion]
        lock.unlock()

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

    var variantByteLimit: Int { variantCache.totalCostLimit }
    var originalByteLimit: Int { originalCache.totalCostLimit }

    // MARK: - Off-main pipeline

    // Resolve original bytes (memory -> disk -> source) and hand them to finishProduction. Local schemes
    // (data:/file:) resolve inline on the work queue; http(s) hands off to URLSession and continues on the
    // work queue from its callback, so no work-queue thread ever blocks waiting on the network - blocking one
    // GCD thread per in-flight download (a semaphore wait) can exhaust the GCD thread pool during image-heavy
    // scrolling and starve the rest of the app's queues.
    private func startProduction(_ request: ImageRequest) {
        let url = request.url
        // Read before the bytes: if the file changes while it loads, the entries carry the older version and
        // the next lookup misses, rather than the new version labeling the old bytes.
        let version = Self.fileVersion(of: url)
        if let record = originalCache.object(forKey: Self.originalKey(url, version) as NSString) {
            finishProduction(request, bytes: record.rawData, writeDisk: false, version: version)
        } else if let disk = diskCache.data(for: url) {
            finishProduction(request, bytes: disk, writeDisk: false, version: version)
        } else if let scheme = url.scheme?.lowercased(), scheme == "data" || scheme == "file" {
            finishProduction(request, bytes: try? Data(contentsOf: url), writeDisk: true, version: version)
        } else {
            let task = Self.urlSession.dataTask(with: url)
            task.delegate = CappedDownload(limit: downloadByteLimit) { [self] bytes in
                workQueue.async { [self] in
                    finishProduction(request, bytes: bytes, writeDisk: true, version: version)
                }
            }
            task.resume()
        }
    }

    // Decode, record the original (+ disk write for fresh bytes), build + cache the ready-to-draw variant,
    // then fire the pending completions. Runs on the work queue; nil bytes (fetch failed) delivers nil.
    private func finishProduction(_ request: ImageRequest, bytes: Data?, writeDisk: Bool, version: String) {
        var variant: PlatformImage?
        // PlatformImage(data:) rasterizes nothing, so the size a file declares is checked before anything does.
        if let bytes, let raw = PlatformImage(data: bytes), ImageProcessing.isWithinLimits(raw) {
            let decoded = ImageProcessing.orientedUp(raw)
            recordOriginal(url: request.url, data: bytes, decoded: decoded, writeDisk: writeDisk, version: version)
            let built = ImageProcessing.variant(from: decoded,
                                                targetWidth: request.quantizedTargetWidth.map { CGFloat($0) },
                                                cornerRadius: CGFloat(request.quantizedCornerRadius))
            variantCache.setObject(built, forKey: Self.variantKey(request, version) as NSString,
                                   cost: ImageProcessing.memoryCost(of: built))
            variant = built
        }
        lock.lock()
        let pending = inFlight.removeValue(forKey: request) ?? []
        lock.unlock()
        deliver(variant, to: pending)
    }

    // Record the raw bytes + natural pixel size in memory and (for freshly fetched bytes) persist the
    // ORIGINAL transport bytes to disk. No transcoding here - that is a consumer concern.
    private func recordOriginal(url: URL, data: Data, decoded: PlatformImage, writeDisk: Bool, version: String) {
        let pixelSize = ImageProcessing.pixelSize(of: decoded)
        let placeholder = ImageProcessing.placeholder(of: decoded)
        let isAnimated = ImageProcessing.isAnimated(data: data)
        // Cost = the transport bytes held resident (the compressed original); the size + grid are negligible.
        originalCache.setObject(OriginalRecord(rawData: data, pixelSize: pixelSize,
                                               placeholder: placeholder, isAnimated: isAnimated),
                                forKey: Self.originalKey(url, version) as NSString, cost: max(1, data.count))
        if writeDisk {
            diskCache.store(data, pixelSize: pixelSize, placeholder: placeholder, isAnimated: isAnimated, for: url)
        } else if let placeholder {
            // Bytes came from the cache: files written by a build that predates the placeholder (or whose
            // attribute was stripped) never pass through store() again, so repair the xattr here.
            diskCache.storePlaceholderIfMissing(placeholder, for: url)
        }
    }

    // MARK: - Memory keys

    // A local file's modification time, size and inode, appended to its memory keys so an edited file misses the
    // old entries (the inode catches editors that save by writing a new file and renaming it); "" for every other
    // scheme, and for a file that is gone, whose load fails anyway. One stat per lookup. A same-size rewrite in
    // place within the file system's timestamp resolution is missed. A space cannot occur in an absolute URL
    // string, so the suffix never collides with a real URL.
    static func fileVersion(of url: URL) -> String {
        guard url.isFileURL else {
            return ""
        }
        var info = stat()
        guard stat(url.path, &info) == 0 else {
            return ""
        }
        return " \(info.st_mtimespec.tv_sec).\(info.st_mtimespec.tv_nsec) \(info.st_size) \(info.st_ino)"
    }

    static func originalKey(_ url: URL, _ version: String) -> String {
        url.absoluteString + version
    }

    static func variantKey(_ request: ImageRequest, _ version: String) -> String {
        request.variantKey + version
    }

    // The response body worth caching, or nil to reject it. A non-2xx HTTP status is rejected so an error
    // page - some CDNs serve a placeholder image or an HTML error with a 404/500 - is never decoded into a
    // "successful" variant or persisted to disk (which would then be served forever). A non-HTTP response
    // (uncommon on this branch, which only handles remote schemes) is accepted as-is.
    static func acceptableBody(_ data: Data?, _ response: URLResponse?) -> Data? {
        isAcceptable(response) ? data : nil
    }

    static func isAcceptable(_ response: URLResponse?) -> Bool {
        guard let http = response as? HTTPURLResponse else {
            return true
        }
        return (200...299).contains(http.statusCode)
    }

    // Whether a response declaring `expectedLength` bytes (-1 when it declares none) is past `limit`. With gzip
    // or another content encoding the declared length is the encoded one; the bytes counted as they arrive are
    // the decoded ones, so a small body that decodes to a huge one is still cut off.
    static func declaresMore(_ expectedLength: Int64, than limit: Int) -> Bool {
        expectedLength > Int64(limit)
    }

    // Downloads bypass the shared URLCache: DiskCache already persists the fetched bytes, and the default
    // shared cache would store a second copy of every image on disk. They carry none of the app's cookies
    // or stored credentials, and answer no sign-in challenge of the image host (the system's single
    // sign-on included): an image address can come from anywhere, and fetching it must not act as the
    // app's signed-in user. The Linux session has no cookie jar either.
    static let urlSession: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        return URLSession(configuration: configuration, delegate: NoSignIn(), delegateQueue: nil)
    }()

    // The answer to an authentication challenge. The check of the server's own certificate and a proxy's
    // sign-in (the network's, not the image host's) are left to the system; any other is declined, so the
    // fetch goes on without credentials: a server that only asks for a client certificate still answers,
    // and one that needs a sign-in answers 401, which acceptableBody refuses.
    static func answer(to challenge: URLAuthenticationChallenge) -> URLSession.AuthChallengeDisposition {
        let space = challenge.protectionSpace
        if space.authenticationMethod == NSURLAuthenticationMethodServerTrust || space.isProxy() {
            return .performDefaultHandling
        }
        return .rejectProtectionSpace
    }

    // The download session's delegate: it answers authentication challenges only.
    final class NoSignIn: NSObject, URLSessionTaskDelegate, Sendable {
        func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge)
            async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
            (ImageStore.answer(to: challenge), nil)
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge)
            async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
            (ImageStore.answer(to: challenge), nil)
        }
    }

    // One download's own delegate: it keeps the body up to `limit` bytes and passes it, or nil, to `done` once
    // the task ends. The session's delegate still answers the session-level challenges; the task-level one is
    // answered here the same way. URLSession calls a task's delegate on the session's delegate queue, which is
    // serial (the session was made with none of its own), so the mutable state is never touched by two threads.
    final class CappedDownload: NSObject, URLSessionDataDelegate, @unchecked Sendable {
        private let limit: Int
        private let done: @Sendable (Data?) -> Void
        private var body = Data()
        private var refused = false

        init(limit: Int, done: @escaping @Sendable (Data?) -> Void) {
            self.limit = limit
            self.done = done
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                        completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
            // An error status or a declared size past the limit ends the task before its body is read.
            guard ImageStore.isAcceptable(response),
                  !ImageStore.declaresMore(response.expectedContentLength, than: limit) else {
                refused = true
                completionHandler(.cancel)
                return
            }
            completionHandler(.allow)
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            guard !refused else {
                return
            }
            guard data.count <= limit - body.count else {
                refused = true
                body = Data()
                dataTask.cancel()
                return
            }
            body.append(data)
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge)
            async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
            (ImageStore.answer(to: challenge), nil)
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            done(error == nil && !refused ? ImageStore.acceptableBody(body, task.response) : nil)
        }
    }

    // The ONLY main-thread work: fire the pending completions. The image + completions are non-Sendable
    // (NSImage, caller closures), so they cross the hop inside an UncheckedSendableBox.
    private func deliver(_ image: PlatformImage?, to completions: [(PlatformImage?) -> Void]) {
        guard !completions.isEmpty else {
            return
        }
        let payload = UncheckedSendableBox((image, completions))
        DispatchQueue.main.async {
            let (image, completions) = payload.value
            for completion in completions {
                completion(image)
            }
        }
    }
}
