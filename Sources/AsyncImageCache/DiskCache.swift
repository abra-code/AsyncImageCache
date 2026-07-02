// Sources/AsyncImageCache/DiskCache.swift
//
// The on-disk tier: the ORIGINAL transport bytes of each fetched image, so the cache survives relaunch and
// enables offline reads. Files live under <Caches>/AsyncImageCache/<name>/ and are named by a stable
// SHA256 hex of the URL string. A soft byte budget is enforced with an LRU-ish trim that evicts the oldest
// files (by modification date) once the directory is over budget. The OS may also evict the whole Caches
// directory at any time, which is fine: a miss just falls through to the network.

import Foundation
import CoreGraphics
import ImageIO
import CryptoKit

final class DiskCache: @unchecked Sendable {
    let directoryURL: URL
    private let byteLimit: Int
    private let fileManager = FileManager.default
    // Serialize writes + trims so a trim never races a concurrent store for a different URL.
    private let writeLock = NSLock()

    init(name: String, byteLimit: Int) {
        let caches = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        directoryURL = caches
            .appendingPathComponent("AsyncImageCache", isDirectory: true)
            .appendingPathComponent(name, isDirectory: true)
        self.byteLimit = max(0, byteLimit)
        try? fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    }

    func fileURL(for url: URL) -> URL {
        directoryURL.appendingPathComponent(Self.hash(url.absoluteString), isDirectory: false)
    }

    func fileExists(for url: URL) -> Bool {
        fileManager.fileExists(atPath: fileURL(for: url).path)
    }

    /// The cached original bytes for a URL, or nil on a miss. Safe to call off the main thread.
    func data(for url: URL) -> Data? {
        try? Data(contentsOf: fileURL(for: url))
    }

    /// Write the original bytes for a URL plus its pixel size and (if computed) its placeholder grid as
    /// extended attributes ON the bytes file, so both travel with the bytes and survive relaunch, then trim if
    /// the directory is over budget.
    func store(_ data: Data, pixelSize: CGSize, placeholder: ImagePlaceholder?, for url: URL) {
        writeLock.lock()
        defer {
            writeLock.unlock()
        }
        let file = fileURL(for: url)
        try? data.write(to: file, options: .atomic)
        writePixelSize(pixelSize, at: file)
        if let placeholder {
            writePlaceholder(placeholder, at: file)
        }
        trimIfNeeded()
    }

    /// The placeholder grid stored for a URL, or nil if absent or invalid. A cheap getxattr, NO decode - and
    /// unlike pixel size there is no header fallback (a grid needs the actual pixels, not worth a decode just
    /// for a placeholder); an absent/invalid value simply means the caller falls back to a neutral placeholder
    /// and the next real load computes + stores it.
    func placeholder(for url: URL) -> ImagePlaceholder? {
        return readPlaceholder(at: fileURL(for: url))
    }

    /// Write the placeholder xattr onto an already-cached bytes file when it is absent. Files cached by a
    /// build that predates the placeholder (or whose attribute was stripped) never pass through store() again
    /// - the disk-hit load path calls this after computing the grid, so the attribute self-repairs. A cheap
    /// size-only getxattr probe when the attribute is already there.
    func storePlaceholderIfMissing(_ placeholder: ImagePlaceholder, for url: URL) {
        let file = fileURL(for: url)
        let present = file.withUnsafeFileSystemRepresentation { path -> Bool in
            guard let path else {
                return true
            }
            return getxattr(path, DiskCache.placeholderAttrName, nil, 0, 0, XATTR_NOFOLLOW) >= 0
        }
        guard !present else {
            return
        }
        writeLock.lock()
        defer {
            writeLock.unlock()
        }
        writePlaceholder(placeholder, at: file)
    }

    /// The natural pixel size of a cached image WITHOUT decoding it. First path (the common one): a cheap
    /// getxattr of the 8-byte size attribute. Fallback: if the attribute is missing but the bytes are on disk
    /// (the xattr was lost, or the bytes were cached by an older build) read the size from the image HEADER via
    /// CGImageSource - still no full decode - then REPAIR the xattr so the next read is back on the fast path.
    /// nil only when neither the attribute nor the file yields a size.
    func pixelSize(for url: URL) -> CGSize? {
        let file = fileURL(for: url)
        if let size = readPixelSize(at: file) {
            return size
        }
        guard let size = headerPixelSize(at: file) else {
            return nil
        }
        writePixelSize(size, at: file)
        return size
    }

    // Read width/height from the image header only (no pixel decode). CGImageSource reads incrementally, so it
    // touches just the leading header bytes of the file, not the whole image.
    private func headerPixelSize(at file: URL) -> CGSize? {
        guard let source = CGImageSourceCreateWithURL(file as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = props[kCGImagePropertyPixelWidth] as? Int,
              let height = props[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0 else {
            return nil
        }
        // Header width/height are pre-rotation; EXIF orientations 5-8 render with the axes swapped, so swap
        // here too - the size must describe the image AS DISPLAYED, matching what the decode path stores.
        if let orientation = props[kCGImagePropertyOrientation] as? UInt32, (5...8).contains(orientation) {
            return CGSize(width: height, height: width)
        }
        return CGSize(width: width, height: height)
    }

    func removeAll() {
        writeLock.lock()
        defer {
            writeLock.unlock()
        }
        try? fileManager.removeItem(at: directoryURL)
        try? fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    }

    // Evict oldest-by-modification-date files until the directory is back under budget.
    private func trimIfNeeded() {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey]
        guard let items = try? fileManager.contentsOfDirectory(at: directoryURL,
                                                               includingPropertiesForKeys: keys) else {
            return
        }
        var entries: [(url: URL, size: Int, date: Date)] = []
        var total = 0
        for item in items {
            let values = try? item.resourceValues(forKeys: Set(keys))
            let size = values?.fileSize ?? 0
            let date = values?.contentModificationDate ?? .distantPast
            entries.append((item, size, date))
            total += size
        }
        guard total > byteLimit else {
            return
        }
        for entry in entries.sorted(by: { $0.date < $1.date }) {
            try? fileManager.removeItem(at: entry.url)
            total -= entry.size
            if total <= byteLimit {
                break
            }
        }
    }

    // Dimensions persist as a fixed 8-byte extended attribute (two Int32) on the cached file. The xattr
    // pattern (setxattr/getxattr, <sys/xattr.h>) works on iOS as well as macOS for files in the app sandbox;
    // Foundation re-exports the Darwin C API, so no bridging is needed. Reverse-DNS name (not com.apple.*).
    private static let pixelSizeAttrName = "public.asyncimagecache.pixelsize"

    private struct PixelSizeAttr {
        var width: Int32
        var height: Int32
    }

    private func writePixelSize(_ size: CGSize, at file: URL) {
        guard size.width > 0, size.height > 0 else {
            return
        }
        var record = PixelSizeAttr(width: Int32(size.width.rounded()), height: Int32(size.height.rounded()))
        file.withUnsafeFileSystemRepresentation { path in
            guard let path else {
                return
            }
            withUnsafeBytes(of: &record) { bytes in
                _ = setxattr(path, DiskCache.pixelSizeAttrName, bytes.baseAddress, bytes.count, 0, XATTR_NOFOLLOW)
            }
        }
    }

    private func readPixelSize(at file: URL) -> CGSize? {
        return file.withUnsafeFileSystemRepresentation { path -> CGSize? in
            guard let path else {
                return nil
            }
            var record = PixelSizeAttr(width: 0, height: 0)
            let read = withUnsafeMutableBytes(of: &record) { bytes in
                getxattr(path, DiskCache.pixelSizeAttrName, bytes.baseAddress, bytes.count, 0, XATTR_NOFOLLOW)
            }
            guard read == MemoryLayout<PixelSizeAttr>.size, record.width > 0, record.height > 0 else {
                return nil
            }
            return CGSize(width: Int(record.width), height: Int(record.height))
        }
    }

    // The placeholder grid persists as N*N RGBA cells. The dimension N is derived from the payload length
    // (length / 4 must be a perfect square) and must equal ImagePlaceholderConfig.gridDimension. A single
    // getxattr into a fixed max-size buffer; discard if the returned length does not describe that grid.
    private static let placeholderAttrName = "public.asyncimagecache.placeholder"

    private func writePlaceholder(_ placeholder: ImagePlaceholder, at file: URL) {
        let n = placeholder.dimension
        guard n > 0, n <= ImagePlaceholderConfig.maxGridDimension, placeholder.cells.count == n * n else {
            return
        }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(n * n * 4)
        for c in placeholder.cells {
            bytes.append(c.red); bytes.append(c.green); bytes.append(c.blue); bytes.append(c.alpha)
        }
        file.withUnsafeFileSystemRepresentation { path in
            guard let path else {
                return
            }
            bytes.withUnsafeBytes { raw in
                _ = setxattr(path, DiskCache.placeholderAttrName, raw.baseAddress, raw.count, 0, XATTR_NOFOLLOW)
            }
        }
    }

    private func readPlaceholder(at file: URL) -> ImagePlaceholder? {
        return file.withUnsafeFileSystemRepresentation { path -> ImagePlaceholder? in
            guard let path else {
                return nil
            }
            let maxBytes = ImagePlaceholderConfig.maxPayloadBytes
            var buf = [UInt8](repeating: 0, count: maxBytes)
            let read = buf.withUnsafeMutableBytes { raw in
                getxattr(path, DiskCache.placeholderAttrName, raw.baseAddress, maxBytes, 0, XATTR_NOFOLLOW)
            }
            guard read > 0, read <= maxBytes, read % 4 == 0 else {
                return nil
            }
            let cellCount = read / 4
            let n = Int(sqrt(Double(cellCount)))
            guard n == ImagePlaceholderConfig.gridDimension, n * n == cellCount else {
                return nil
            }
            var cells: [ImageColor] = []
            cells.reserveCapacity(cellCount)
            for i in 0..<cellCount {
                let o = i * 4
                cells.append(ImageColor(red: buf[o], green: buf[o + 1], blue: buf[o + 2], alpha: buf[o + 3]))
            }
            return ImagePlaceholder(dimension: n, cells: cells)
        }
    }

    private static func hash(_ string: String) -> String {
        let digest = SHA256.hash(data: Data(string.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
