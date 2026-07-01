// Sources/AsyncImageCache/ImageStore.swift
//
// The public entry point: an async image loader + two-tier cache. EVERYTHING heavy - byte fetch, decode,
// downscale, corner-rounding, encoding - runs off the main thread on a concurrent work queue; the ONLY
// main-thread work is the final completion callback.
//
// Two tiers:
//   - in-memory: an NSCache of ready-to-draw variants (keyed by the full ImageRequest) + an NSCache of
//     originals (raw transport bytes + natural pixel size, keyed by URL).
//   - on-disk: the ORIGINAL transport bytes (DiskCache), which survive relaunch and enable offline reads.
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

/// The in-memory record of an original: the raw transport bytes (memory tier for the byte resolve) and the
/// natural pixel size. Immutable, so it is safely `Sendable` inside an NSCache.
private final class OriginalRecord: Sendable {
    let rawData: Data
    let pixelSize: CGSize
    init(rawData: Data, pixelSize: CGSize) {
        self.rawData = rawData
        self.pixelSize = pixelSize
    }
}

/// A boxed CGSize for the xattr-sourced pixel-size memo (NSCache values must be classes).
private final class SizeBox: Sendable {
    let size: CGSize
    init(_ size: CGSize) {
        self.size = size
    }
}

public final class ImageStore: @unchecked Sendable {

    public static let shared = ImageStore()

    private let variantCache = NSCache<NSString, PlatformImage>()
    private let originalCache = NSCache<NSString, OriginalRecord>()
    private let pixelSizeMemo = NSCache<NSString, SizeBox>()   // sizes read from the disk xattr, memoized
    private let diskCache: DiskCache
    private let workQueue: DispatchQueue

    // De-duplicate concurrent identical requests: the first inserts an entry, later ones append their
    // completion, and all fire together when the single fetch finishes. Guarded by `lock`.
    private let lock = NSLock()
    private var inFlight: [ImageRequest: [(PlatformImage?) -> Void]] = [:]

    public init(name: String = "default",
                memoryCountLimit: Int = 150,
                diskByteLimit: Int = 200 * 1024 * 1024) {
        variantCache.countLimit = memoryCountLimit
        originalCache.countLimit = memoryCountLimit
        diskCache = DiskCache(name: name, byteLimit: diskByteLimit)
        workQueue = DispatchQueue(label: "com.richtextview.AsyncImageCache.\(name)", attributes: .concurrent)
    }

    // MARK: - Synchronous lookups

    /// The ready-to-draw variant for the exact request, if in memory. nil on a miss. Thread-safe.
    public func cachedImage(for request: ImageRequest) -> PlatformImage? {
        variantCache.object(forKey: request.variantKey as NSString)
    }

    /// The natural PIXEL size of a URL's image, if known WITHOUT decoding. Thread-safe. Lets a consumer
    /// reserve layout space before the pixels arrive - including across relaunch: memory is empty then, but
    /// the size rode along with the on-disk bytes as an extended attribute, so this reads it (a cheap
    /// getxattr, no decode) and memoizes it so repeated layout queries stay memory-fast.
    public func cachedPixelSize(for url: URL) -> CGSize? {
        let key = url.absoluteString as NSString
        if let record = originalCache.object(forKey: key) {
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

    /// The ORIGINAL transport bytes + natural pixel size for a loaded URL, or nil if not loaded. For
    /// consumers that need the source bytes (e.g. producing embeddable copy data) - the cache stays generic
    /// and does no format transcoding itself; the consumer decides how to encode.
    public func cachedOriginalBytes(for url: URL) -> (data: Data, pixelSize: CGSize)? {
        guard let record = originalCache.object(forKey: url.absoluteString as NSString) else {
            return nil
        }
        return (record.rawData, record.pixelSize)
    }

    // MARK: - Loading

    /// Resolve the ready-to-draw variant for `request`, calling `completion` on the MAIN thread. A memory hit
    /// delivers immediately; otherwise the byte fetch / decode / downscale / rounding all happen off-main.
    public func load(_ request: ImageRequest, completion: @escaping (PlatformImage?) -> Void) {
        if let cached = variantCache.object(forKey: request.variantKey as NSString) {
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
            let image = produce(request)
            lock.lock()
            let pending = inFlight.removeValue(forKey: request) ?? []
            lock.unlock()
            deliver(image, to: pending)
        }
    }

    public func clearMemory() {
        variantCache.removeAllObjects()
        originalCache.removeAllObjects()
        pixelSizeMemo.removeAllObjects()
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

    // MARK: - Off-main pipeline

    // Resolve original bytes (memory -> disk -> source), decode, record the original + write disk, then build
    // and cache the ready-to-draw variant. Runs entirely on the work queue.
    private func produce(_ request: ImageRequest) -> PlatformImage? {
        let url = request.url
        let bytes: Data
        var writeDisk = false

        if let record = originalCache.object(forKey: url.absoluteString as NSString) {
            bytes = record.rawData
        } else if let disk = diskCache.data(for: url) {
            bytes = disk
        } else if let fresh = fetchFromSource(url) {
            bytes = fresh
            writeDisk = true
        } else {
            return nil
        }

        guard let decoded = PlatformImage(data: bytes) else {
            return nil
        }
        recordOriginal(url: url, data: bytes, decoded: decoded, writeDisk: writeDisk)

        let variant = ImageProcessing.variant(from: decoded,
                                               targetWidth: request.quantizedTargetWidth.map { CGFloat($0) },
                                               cornerRadius: CGFloat(request.quantizedCornerRadius))
        variantCache.setObject(variant, forKey: request.variantKey as NSString)
        return variant
    }

    // Record the raw bytes + natural pixel size in memory and (for freshly fetched bytes) persist the
    // ORIGINAL transport bytes to disk. No transcoding here - that is a consumer concern.
    private func recordOriginal(url: URL, data: Data, decoded: PlatformImage, writeDisk: Bool) {
        let pixelSize = ImageProcessing.pixelSize(of: decoded)
        originalCache.setObject(OriginalRecord(rawData: data, pixelSize: pixelSize), forKey: url.absoluteString as NSString)
        if writeDisk {
            diskCache.store(data, pixelSize: pixelSize, for: url)
        }
    }

    // Byte fetch from the source of last resort. data: / file: read without the network; http(s) go through
    // URLSession synchronously (this runs on the work queue, so blocking here is fine).
    private func fetchFromSource(_ url: URL) -> Data? {
        switch url.scheme {
        case "data", "file":
            return try? Data(contentsOf: url)
        default:
            return synchronousData(from: url)
        }
    }

    private func synchronousData(from url: URL) -> Data? {
        final class ResultBox: @unchecked Sendable {
            var data: Data?
        }
        let box = ResultBox()
        let semaphore = DispatchSemaphore(value: 0)
        let task = URLSession.shared.dataTask(with: url) { data, _, _ in
            box.data = data
            semaphore.signal()
        }
        task.resume()
        semaphore.wait()
        return box.data
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
