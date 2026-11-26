// Sources/AsyncImageCache/Windows/ImageStore+Windows.swift
//
// The public entry point on Windows, the counterpart of ImageStore.swift with the same API as on Linux (ImageSize in
// place of CGSize): an async image loader + two-tier cache. EVERYTHING heavy - byte fetch, decode, downscale,
// corner-rounding - runs off the main thread, on a concurrent work queue and the network queue (and a variant
// without corners is decoded for display by WinUI, on its own threads); the ONLY main-thread work is handing WinUI
// the image and the final completion callback, on the main dispatch queue. A program that uses the store
// drains that queue (ActionUI's WinUI renderer does, from WinUI's message loop).
//
// Two tiers:
//   - in-memory: MemoryCache maps of ready-to-draw variants (keyed by the full ImageRequest) and of originals
//     (raw transport bytes + natural pixel size, keyed by URL). A local file: image's keys also carry the
//     file's modification time and size (fileVersion), so after the file is edited a lookup misses and the next
//     load reads the new picture; the old entries age out.
//   - on-disk: the ORIGINAL transport bytes (DiskCache), which survive relaunch and enable offline reads. Not
//     for local file: images, which are read from their file again; what the docs below say survives relaunch
//     (pixel size, placeholder, animated flag) is then known only while the image is in memory.
//
// Loading: data: and file: URLs are read on the work queue; http and https through WinHTTP on the network queue
// (HTTPLoader+Windows.swift).

#if os(Windows)

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
import Dispatch
import Synchronization
import ucrt

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
    private let currentDownloadByteLimit: Mutex<Int>

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
            currentDownloadByteLimit.withLock { $0 }
        }
        set {
            currentDownloadByteLimit.withLock { $0 = max(0, newValue) }
        }
    }

    /// - Parameters:
    ///   - name: names the on-disk subfolder and work queue; distinct names are fully independent caches.
    ///   - memoryCountLimit: max number of entries in EACH in-memory tier (variants, originals).
    ///   - memoryByteLimit: ceiling on the RAM held by EACH in-memory tier, by cost: decoded bitmap bytes for
    ///     variants, transport bytes for originals. Least recently used entries go first. The store follows no memory
    ///     pressure signal on Windows (NSCache purges on one on Apple platforms), so this is the whole bound. Defaults to
    ///     `recommendedMemoryByteLimit()`. Set it above the largest single decoded image you expect, or that
    ///     image cannot stay resident.
    ///   - diskByteLimit: soft byte budget for the on-disk original bytes.
    ///   - downloadByteLimit: the most bytes one http or https download may bring (see `downloadByteLimit`).
    public init(name: String = "default",
                memoryCountLimit: Int = 150,
                memoryByteLimit: Int = ImageStore.recommendedMemoryByteLimit(),
                diskByteLimit: Int = 200 * 1024 * 1024,
                downloadByteLimit: Int = ImageStore.defaultDownloadByteLimit) {
        currentDownloadByteLimit = Mutex(max(0, downloadByteLimit))
        let costLimit = max(0, memoryByteLimit)
        variantCache = MemoryCache(countLimit: memoryCountLimit, costLimit: costLimit)
        originalCache = MemoryCache(countLimit: memoryCountLimit, costLimit: costLimit)
        diskCache = DiskCache(name: name, byteLimit: diskByteLimit)
        workQueue = DispatchQueue(label: "com.richtextview.AsyncImageCache.\(name)", attributes: .concurrent)
    }

    /// A per-tier memory budget scaled to the machine's physical RAM: a sixteenth of it, between 256 MB and
    /// 1 GB, as for macOS and Linux (desktops, no per-app memory limit).
    public static func recommendedMemoryByteLimit() -> Int {
        let fraction = Int(ProcessInfo.processInfo.physicalMemory / 16)
        return min(max(fraction, 256 * 1024 * 1024), 1024 * 1024 * 1024)
    }

    // MARK: - Synchronous lookups

    /// The ready-to-draw variant for the exact request, if in memory. nil on a miss. Thread-safe.
    public func cachedImage(for request: ImageRequest) -> PlatformImage? {
        variantCache.object(forKey: Self.variantKey(request, Self.fileVersion(of: request.url)))
    }

    /// The natural PIXEL size of a URL's image, if known WITHOUT decoding. Thread-safe. Survives relaunch: the
    /// size rode along with the on-disk bytes in their sidecar, so this reads it and memoizes it.
    public func cachedPixelSize(for url: URL) -> ImageSize? {
        let key = url.absoluteString
        if let record = originalCache.object(forKey: Self.originalKey(url, Self.fileVersion(of: url))) {
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
        if let record = originalCache.object(forKey: Self.originalKey(url, Self.fileVersion(of: url))) {
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

    /// The placeholder grid as a small image (shown larger with interpolation, it is a soft gradient), or nil if
    /// no placeholder is known for the URL.
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
        if let record = originalCache.object(forKey: Self.originalKey(url, Self.fileVersion(of: url))) {
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
        guard let record = originalCache.object(forKey: Self.originalKey(url, Self.fileVersion(of: url))) else {
            return nil
        }
        return (record.rawData, record.pixelSize)
    }

    // MARK: - Loading

    /// Resolve the ready-to-draw variant for `request`, calling `completion` on the MAIN thread (the main
    /// dispatch queue), always after this call returns. The byte fetch / decode / downscale / rounding happen off-main.
    public func load(_ request: ImageRequest, completion: @escaping (PlatformImage?) -> Void) {
        if let cached = variantCache.object(forKey: Self.variantKey(request, Self.fileVersion(of: request.url))) {
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
        // Read before the bytes: if the file changes while it loads, the entries carry the older version and the
        // next lookup misses, rather than the new version labeling the old bytes.
        let version = Self.fileVersion(of: url)
        if let record = originalCache.object(forKey: Self.originalKey(url, version)) {
            finishProduction(request, bytes: record.rawData, writeDisk: false, version: version)
            return
        }
        if let disk = diskCache.data(for: url) {
            finishProduction(request, bytes: disk, writeDisk: false, version: version)
            return
        }
        switch url.scheme?.lowercased() {
        case "file":
            finishProduction(request, bytes: Self.fileBytes(url), writeDisk: true, version: version)
        case "data":
            finishProduction(request, bytes: Self.decodeDataURL(url.absoluteString), writeDisk: true, version: version)
        case "http", "https":
            HTTPLoader.fetch(url, limit: downloadByteLimit) { [self] bytes in
                workQueue.async { [self] in
                    finishProduction(request, bytes: bytes, writeDisk: true, version: version)
                }
            }
        default:
            finishProduction(request, bytes: nil, writeDisk: false, version: version)
        }
    }

    // Decode, record the original (+ disk write for fresh bytes), build + cache the ready-to-draw variant,
    // then fire the pending completions. Runs on the work queue; nil bytes (fetch failed) delivers nil.
    private func finishProduction(_ request: ImageRequest, bytes: Data?, writeDisk: Bool, version: String) {
        var variant: PlatformImage?
        if let bytes, let decoded = ImageProcessing.decode(bytes) {
            recordOriginal(url: request.url, data: bytes, decoded: decoded, writeDisk: writeDisk, version: version)
            let targetWidth = request.quantizedTargetWidth.map { ImageLength($0) }
            let built: PlatformImage?
            if request.quantizedCornerRadius > 0 {
                // Corners are baked into pixels, which go into a SoftwareBitmap here, off the main thread, before
                // anyone can see them.
                built = ImageProcessing.variant(from: decoded, targetWidth: targetWidth,
                                                cornerRadius: ImageLength(request.quantizedCornerRadius))
                built?.prepareForDisplay()
            } else {
                // WinUI decodes the bytes itself, keeping one copy of the pixels; the decode here gave the size and
                // the placeholder, and its pixels go with it.
                built = ImageProcessing.encodedVariant(bytes, of: decoded, targetWidth: targetWidth)
            }
            if let built {
                variantCache.setObject(built, forKey: Self.variantKey(request, version),
                                       cost: ImageProcessing.memoryCost(of: built))
                variant = built
            }
        }
        let pending = inFlight.withLock { $0.removeValue(forKey: request) } ?? []
        deliver(variant, to: pending)
    }

    // Record the raw bytes + natural pixel size in memory and (for freshly fetched bytes) persist the ORIGINAL
    // transport bytes to disk.
    private func recordOriginal(url: URL, data: Data, decoded: DecodedImage, writeDisk: Bool, version: String) {
        let pixelSize = ImageProcessing.pixelSize(of: decoded)
        let placeholder = ImageProcessing.placeholder(of: decoded)
        let isAnimated = ImageProcessing.isAnimated(data: data)
        originalCache.setObject(OriginalRecord(rawData: data, pixelSize: pixelSize,
                                               placeholder: placeholder, isAnimated: isAnimated),
                                forKey: Self.originalKey(url, version), cost: max(1, data.count))
        if writeDisk {
            diskCache.store(data, pixelSize: pixelSize, placeholder: placeholder, isAnimated: isAnimated, for: url)
        } else if let placeholder {
            // Bytes came from the cache: a file whose sidecar lost its grid never passes through store() again,
            // so repair it here.
            diskCache.storePlaceholderIfMissing(placeholder, for: url)
        }
    }

    // A data: URL's bytes: "data:[<media type>][;base64],<data>", the data base64 (escapes allowed in it) or
    // percent-encoded. nil when it is malformed or empty.
    static func decodeDataURL(_ string: String) -> Data? {
        let bytes = Array(string.utf8)
        guard bytes.count > 5, String(decoding: bytes[0..<5], as: UTF8.self).lowercased() == "data:",
              let comma = bytes.firstIndex(of: UInt8(ascii: ",")) else {
            return nil
        }
        let header = String(decoding: bytes[5..<comma], as: UTF8.self).lowercased()
        guard let payload = percentDecoded(bytes[(comma + 1)...]) else {
            return nil
        }
        let decoded: Data?
        if header.hasSuffix(";base64") {
            // Base64 allows no white space, but data: URLs in the wild carry line breaks.
            let text = String(decoding: payload.filter { ![0x20, 0x0A, 0x0D, 0x09].contains($0) }, as: UTF8.self)
            decoded = Data(base64Encoded: text)
        } else {
            decoded = Data(payload)
        }
        return decoded.flatMap { $0.isEmpty ? nil : $0 }
    }

    // The bytes with each "%XX" made the byte it names; nil for a "%" without two hex digits after it.
    private static func percentDecoded(_ bytes: ArraySlice<UInt8>) -> [UInt8]? {
        func hexValue(_ byte: UInt8) -> UInt8? {
            switch byte {
            case UInt8(ascii: "0")...UInt8(ascii: "9"): return byte - UInt8(ascii: "0")
            case UInt8(ascii: "a")...UInt8(ascii: "f"): return byte - UInt8(ascii: "a") + 10
            case UInt8(ascii: "A")...UInt8(ascii: "F"): return byte - UInt8(ascii: "A") + 10
            default: return nil
            }
        }
        var result: [UInt8] = []
        result.reserveCapacity(bytes.count)
        var index = bytes.startIndex
        while index < bytes.endIndex {
            let byte = bytes[index]
            guard byte == UInt8(ascii: "%") else {
                result.append(byte)
                index += 1
                continue
            }
            guard index + 2 < bytes.endIndex, let high = hexValue(bytes[index + 1]),
                  let low = hexValue(bytes[index + 2]) else {
                return nil
            }
            result.append(high << 4 | low)
            index += 3
        }
        return result
    }

    // The bytes of a local file: URL's file, or nil when it names no regular file (a folder, a device such as NUL
    // or CON, a pipe: one would never finish reading, or never start) or cannot be read.
    static func fileBytes(_ url: URL) -> Data? {
        guard let path = windowsPath(of: url), isRegularFile(path) else {
            return nil
        }
        return FileManager.default.contents(atPath: path)
    }

    // The path Windows opens for a file: URL, as ActionUI's renderer reads one (and asks its trust policy about):
    // with a host, a file on that server's share ("file://server/share/a.png" is "\\server\share\a.png");
    // "file:///C:/a.png" and "file://localhost/C:/a.png" are "C:\a.png". Only an ASCII letter makes a drive. nil
    // for a URL that is no file: URL.
    static func windowsPath(of url: URL) -> String? {
        guard url.isFileURL else {
            return nil
        }
        let path = url.path(percentEncoded: false)
        let characters = Array(path)
        let drive = characters.count >= 3 && characters[0] == "/" && characters[1].isASCII && characters[1].isLetter
            && characters[2] == ":"
        let host = url.host(percentEncoded: false) ?? ""
        let backslashed = String(path.map { $0 == "/" ? "\\" : $0 })
        if !host.isEmpty, !drive || host.lowercased() != "localhost" {
            return "\\\\" + host + backslashed
        }
        return drive ? String(backslashed.dropFirst()) : backslashed
    }

    // Whether `path` names a regular file, links followed: the C runtime's stat reports a device (NUL, CON) as a
    // character device and a pipe as a FIFO.
    private static func isRegularFile(_ path: String) -> Bool {
        var info = _stat64()
        let found = path.withCString(encodedAs: UTF16.self) { _wstat64($0, &info) } == 0
        return found && (Int32(info.st_mode) & _S_IFMT) == _S_IFREG
    }

    // The ONLY main-thread work: fire the pending completions.
    private func deliver(_ image: PlatformImage?, to completions: [UncheckedSendableBox<(PlatformImage?) -> Void>]) {
        guard !completions.isEmpty else {
            return
        }
        let payload = UncheckedSendableBox(completions)
        DispatchQueue.main.async {
            // The WinUI image, made once, before any completion: the cache then holds that one shared source.
            MainActor.assumeIsolated {
                _ = image?.imageSource
            }
            for completion in payload.value {
                completion.value(image)
            }
        }
    }

    // MARK: - Memory keys

    // A local file's modification time and size, appended to its memory keys so an edited file misses the old
    // entries; "" for every other scheme, and for a file that is gone, whose load fails anyway. One stat per
    // lookup. The C runtime's stat gives whole seconds and no file identity on Windows, so a same-size rewrite
    // within a second is missed. A space cannot occur in an absolute URL string, so the suffix never collides with
    // a real URL.
    static func fileVersion(of url: URL) -> String {
        guard let path = windowsPath(of: url) else {
            return ""
        }
        var info = _stat64()
        let found = path.withCString(encodedAs: UTF16.self) { _wstat64($0, &info) } == 0
        guard found else {
            return ""
        }
        return " \(info.st_mtime) \(info.st_size)"
    }

    static func originalKey(_ url: URL, _ version: String) -> String {
        url.absoluteString + version
    }

    static func variantKey(_ request: ImageRequest, _ version: String) -> String {
        request.variantKey + version
    }
}

#endif
