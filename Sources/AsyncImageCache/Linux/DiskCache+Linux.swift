// Sources/AsyncImageCache/Linux/DiskCache+Linux.swift
//
// The on-disk tier on Linux, the counterpart of DiskCache.swift: the ORIGINAL transport bytes of each fetched
// image, so the cache survives relaunch and enables offline reads. Files live under
// <XDG cache folder>/AsyncImageCache/<name>/ (~/.cache unless XDG_CACHE_HOME says otherwise) and are named by
// the same SHA-256 hex of the URL string as on Apple platforms (GLib's GChecksum in place of CryptoKit). A soft
// byte budget is enforced by evicting the oldest files (by modification time) once the folder is over budget.
//
// The per-file metadata (pixel size, animated flag, placeholder grid) lives in a `<hash>.meta` sidecar
// (ImageMetaCodec), not in extended attributes; the "absent -> read the header and repair" fallbacks are kept.

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
import Glibc
import Synchronization
import CAsyncImageCacheGtk

final class DiskCache: Sendable {
    let directoryURL: URL
    private let byteLimit: Int
    // Serializes writes, repairs and trims, so a trim never races a store and the read-modify-write of a
    // sidecar cannot interleave with another and lose a field.
    private let writeLock = Mutex(())

    private static let metaSuffix = ".meta"

    init(name: String, byteLimit: Int) {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: FileManager.default.temporaryDirectory.path)
        directoryURL = caches
            .appendingPathComponent("AsyncImageCache", isDirectory: true)
            .appendingPathComponent(name, isDirectory: true)
        self.byteLimit = max(0, byteLimit)
        try? FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    }

    func fileURL(for url: URL) -> URL {
        directoryURL.appendingPathComponent(Self.hash(url.absoluteString), isDirectory: false)
    }

    private func metaURL(for url: URL) -> URL {
        directoryURL.appendingPathComponent(Self.hash(url.absoluteString) + Self.metaSuffix, isDirectory: false)
    }

    func fileExists(for url: URL) -> Bool {
        FileManager.default.fileExists(atPath: fileURL(for: url).path)
    }

    /// The cached original bytes for a URL, or nil on a miss. Safe to call off the main thread.
    func data(for url: URL) -> Data? {
        try? Data(contentsOf: fileURL(for: url))
    }

    /// Write the original bytes for a URL and its metadata sidecar (each atomically), then trim if the folder is
    /// over budget.
    func store(_ data: Data, pixelSize: ImageSize, placeholder: ImagePlaceholder?,
               isAnimated: Bool = false, for url: URL) {
        writeLock.withLock { _ in
            do {
                try data.write(to: fileURL(for: url), options: .atomic)
            } catch {
                return
            }
            let size = pixelSize.width > 0 && pixelSize.height > 0
                ? (Int(pixelSize.width.rounded()), Int(pixelSize.height.rounded())) : nil
            writeMeta(ImageMeta(pixelSize: size, animated: isAnimated, placeholder: placeholder), for: url)
            trimIfNeeded()
        }
    }

    /// The placeholder grid stored for a URL, or nil if absent or invalid. No decode fallback: a grid needs
    /// the pixels, and the next real load computes and stores it.
    func placeholder(for url: URL) -> ImagePlaceholder? {
        guard let placeholder = readMeta(for: url)?.placeholder,
              placeholder.dimension == ImagePlaceholderConfig.gridDimension else {
            return nil
        }
        return placeholder
    }

    /// Add the placeholder to an already-cached file's metadata when it is absent (files whose sidecar was lost
    /// never pass through store() again; the disk-hit load path calls this after computing the grid).
    func storePlaceholderIfMissing(_ placeholder: ImagePlaceholder, for url: URL) {
        guard readMeta(for: url)?.placeholder == nil else {
            return
        }
        repairMeta(for: url) { meta in
            if meta.placeholder == nil {
                meta.placeholder = placeholder
            }
        }
    }

    /// The natural pixel size of a cached image WITHOUT decoding it: from the sidecar, or, when that has none but
    /// the bytes are on disk, from the image HEADER (then the sidecar is repaired). nil when neither yields one.
    func pixelSize(for url: URL) -> ImageSize? {
        if let size = readMeta(for: url)?.pixelSize {
            return ImageSize(width: ImageLength(size.width), height: ImageLength(size.height))
        }
        let file = fileURL(for: url)
        guard FileManager.default.fileExists(atPath: file.path),
              let size = ImageProcessing.headerPixelSize(atPath: file.path) else {
            return nil
        }
        repairMeta(for: url) { meta in
            if meta.pixelSize == nil {
                meta.pixelSize = (Int(size.width), Int(size.height))
            }
        }
        return size
    }

    /// Whether the cached bytes are a multi-frame (animated) image, or nil if the file is absent: from the
    /// sidecar, or by sniffing the bytes' container header (then the sidecar is repaired).
    func isAnimated(for url: URL) -> Bool? {
        if let animated = readMeta(for: url)?.animated {
            return animated
        }
        guard let bytes = data(for: url) else {
            return nil
        }
        let animated = ImageProcessing.isAnimated(data: bytes)
        repairMeta(for: url) { meta in
            if meta.animated == nil {
                meta.animated = animated
            }
        }
        return animated
    }

    func removeAll() {
        writeLock.withLock { _ in
            try? FileManager.default.removeItem(at: directoryURL)
            try? FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        }
    }

    // MARK: - Sidecar

    // Read and decode the sidecar, or nil if absent or corrupt, or when its bytes file is gone (an extended
    // attribute on Apple platforms goes with its file). Lock-free (plain file reads): writes replace the file
    // atomically, so a read sees the old record or the new one.
    private func readMeta(for url: URL) -> ImageMeta? {
        guard FileManager.default.fileExists(atPath: fileURL(for: url).path),
              let bytes = try? Data(contentsOf: metaURL(for: url)) else {
            return nil
        }
        return ImageMetaCodec.decode([UInt8](bytes))
    }

    // Called with writeLock held.
    private func writeMeta(_ meta: ImageMeta, for url: URL) {
        try? Data(ImageMetaCodec.encode(meta)).write(to: metaURL(for: url), options: .atomic)
    }

    // Re-read under the lock, change, write back - only while the bytes are still cached, so a repair never
    // leaves a sidecar without its file.
    private func repairMeta(for url: URL, _ change: (inout ImageMeta) -> Void) {
        writeLock.withLock { _ in
            guard FileManager.default.fileExists(atPath: fileURL(for: url).path) else {
                return
            }
            var meta = readMeta(for: url) ?? ImageMeta()
            change(&meta)
            writeMeta(meta, for: url)
        }
    }

    // MARK: - Trim

    // Evict the oldest files (by modification time) until the folder is back under budget. Every file counts, as
    // on Apple platforms: a cached file together with its sidecar, and on its own anything else (a sidecar whose
    // file is gone, a temporary file an interrupted write left). Called with writeLock held.
    private func trimIfNeeded() {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directoryURL.path) else {
            return
        }
        let present = Set(names)
        var entries: [String: (size: Int, modified: Int)] = [:]   // by the cached file's name, or the file's own
        var total = 0
        for name in names {
            guard let info = Self.status(of: directoryURL.appendingPathComponent(name).path) else {
                continue
            }
            let owner = String(name.dropLast(Self.metaSuffix.count))
            let key = name.hasSuffix(Self.metaSuffix) && Self.isHash(owner) && present.contains(owner) ? owner : name
            let previous = entries[key] ?? (0, Int.max)
            entries[key] = (previous.size + info.size, min(previous.modified, info.modified))
            total += info.size
        }
        guard total > byteLimit else {
            return
        }
        for (name, entry) in entries.sorted(by: { $0.value.modified < $1.value.modified }) {
            try? FileManager.default.removeItem(at: directoryURL.appendingPathComponent(name))
            if Self.isHash(name) {
                try? FileManager.default.removeItem(at: directoryURL.appendingPathComponent(name + Self.metaSuffix))
            }
            total -= entry.size
            if total <= byteLimit {
                break
            }
        }
    }

    // A file's size and modification time in nanoseconds, or nil if it does not exist.
    private static func status(of path: String) -> (size: Int, modified: Int)? {
        var info = stat()
        guard stat(path, &info) == 0 else {
            return nil
        }
        return (Int(info.st_size), Int(info.st_mtim.tv_sec) * 1_000_000_000 + Int(info.st_mtim.tv_nsec))
    }

    private static func isHash(_ name: String) -> Bool {
        let scalars = name.unicodeScalars
        return scalars.count == 64 && scalars.allSatisfy { ("0"..."9").contains($0) || ("a"..."f").contains($0) }
    }

    // SHA-256 lowercase hex of the URL string, used as the on-disk file name: the same names as the Apple cache.
    private static func hash(_ string: String) -> String {
        guard let hex = g_compute_checksum_for_string(G_CHECKSUM_SHA256, string, -1) else {
            return ""
        }
        defer {
            g_free(hex)
        }
        return String(cString: hex)
    }
}
