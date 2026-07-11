// DiskCache.kt
//
// The on-disk tier: the ORIGINAL transport bytes of each fetched image, so the cache survives relaunch and
// enables offline reads. Files live under <cacheDir>/AsyncImageCache/<name>/ and are named by a stable SHA-256
// hex of the URL string. A soft byte budget is enforced with an LRU-ish trim that evicts the oldest files (by
// last-modified) once the directory is over budget. The OS may also purge cacheDir wholesale at any time, which
// is fine: a miss just falls through to the network. Ports Sources/AsyncImageCache/DiskCache.swift.
//
// The Swift package stored per-file metadata (pixel size, animated flag, placeholder grid) in three extended
// attributes ON the bytes file. Android app storage has no dependable xattr, so each field lives in a sidecar
// `<hash>.meta` file next to the bytes, encoded by ImageMetaCodec. The "attribute absent -> read the header and
// repair" fallbacks are preserved exactly (see pixelSize / isAnimated).

package com.abracode.asyncimagecache

import android.util.Size
import java.io.File
import java.security.MessageDigest
import java.util.concurrent.atomic.AtomicLong
import java.util.concurrent.locks.ReentrantLock
import kotlin.concurrent.withLock

internal class DiskCache(
    cacheRoot: File,
    name: String,
    byteLimit: Long,
) {
    val directory: File = File(File(cacheRoot, "AsyncImageCache"), name)
    private val byteLimit: Long = maxOf(0L, byteLimit)
    // Serialize writes + trims so a trim never races a concurrent store for a different URL, and so the
    // read-modify-write of the sidecar meta (repair paths) cannot interleave and clobber a field.
    private val writeLock = ReentrantLock()

    init {
        directory.mkdirs()
    }

    fun fileForUrl(url: String): File = File(directory, hash(url))

    private fun metaFileForUrl(url: String): File = File(directory, hash(url) + META_SUFFIX)

    fun fileExists(url: String): Boolean = fileForUrl(url).exists()

    /** The cached original bytes for a URL, or null on a miss. Safe to call off the main thread. */
    fun data(url: String): ByteArray? {
        val file = fileForUrl(url)
        return try {
            if (file.exists()) file.readBytes() else null
        } catch (t: Throwable) {
            null
        }
    }

    /**
     * Write the original bytes plus the pixel size, animated flag, and (if computed) placeholder grid as a
     * single sidecar meta file, so all of it travels with the bytes and survives relaunch, then trim if the
     * directory is over budget. Bytes and meta are each written atomically (temp file + rename).
     */
    fun store(data: ByteArray, pixelSize: Size, placeholder: ImagePlaceholder?, isAnimated: Boolean, url: String) {
        writeLock.withLock {
            val file = fileForUrl(url)
            if (!writeAtomically(file, data)) {
                return
            }
            val meta = ImageMeta(
                pixelSize = PixelSize(pixelSize.width, pixelSize.height),
                animated = isAnimated,
                placeholder = placeholder,
            )
            writeAtomically(metaFileForUrl(url), ImageMetaCodec.encode(meta))
            trimIfNeeded()
        }
    }

    /**
     * The placeholder grid stored for a URL, or null if absent/invalid. A cheap meta read, NO decode - and
     * unlike pixel size there is no header fallback (a grid needs the actual pixels); an absent value simply
     * means the caller falls back to a neutral placeholder and the next real load computes + stores it.
     */
    fun placeholder(url: String): ImagePlaceholder? = readMeta(url)?.placeholder

    /**
     * Write the placeholder into the meta when it is absent. Files cached by a build that predates the
     * placeholder (or whose meta was stripped) never pass through store() again - the disk-hit load path calls
     * this after computing the grid, so the meta self-repairs. A cheap presence check when it is already there.
     */
    fun storePlaceholderIfMissing(placeholder: ImagePlaceholder, url: String) {
        if (readMeta(url)?.placeholder != null) {
            return
        }
        writeLock.withLock {
            val current = readMeta(url) ?: ImageMeta(null, null, null)
            if (current.placeholder == null) {
                writeAtomically(metaFileForUrl(url), ImageMetaCodec.encode(current.copy(placeholder = placeholder)))
            }
        }
    }

    /**
     * The natural pixel size of a cached image WITHOUT decoding it. First path (the common one): read it from
     * the meta. Fallback: if the meta lacks a size but the bytes are on disk (meta lost, or bytes cached by an
     * older build) read the size from the image HEADER (still no full decode) then REPAIR the meta so the next
     * read is back on the fast path. null only when neither the meta nor the file yields a size.
     */
    fun pixelSize(url: String): Size? {
        readMeta(url)?.pixelSize?.let {
            return Size(it.width, it.height)
        }
        val bytes = data(url) ?: return null
        val size = ImageProcessing.headerPixelSize(bytes) ?: return null
        writeLock.withLock {
            val current = readMeta(url) ?: ImageMeta(null, null, null)
            if (current.pixelSize == null) {
                val repaired = current.copy(pixelSize = PixelSize(size.width, size.height))
                writeAtomically(metaFileForUrl(url), ImageMetaCodec.encode(repaired))
            }
        }
        return size
    }

    /**
     * Whether the cached bytes are a multi-frame (animated) image, or null if the file is absent. First path: a
     * cheap meta read. Fallback: if the flag is missing but the bytes are on disk (older build, or the meta was
     * stripped) sniff the container header (no pixel decode) then REPAIR the meta so the next read is O(1).
     * Mirrors the pixel-size resolve.
     */
    fun isAnimated(url: String): Boolean? {
        readMeta(url)?.animated?.let {
            return it
        }
        val bytes = data(url) ?: return null
        val animated = ImageProcessing.isAnimated(bytes)
        writeLock.withLock {
            val current = readMeta(url) ?: ImageMeta(null, null, null)
            if (current.animated == null) {
                writeAtomically(metaFileForUrl(url), ImageMetaCodec.encode(current.copy(animated = animated)))
            }
        }
        return animated
    }

    fun removeAll() {
        writeLock.withLock {
            directory.deleteRecursively()
            directory.mkdirs()
        }
    }

    // Read + decode the sidecar meta, or null if absent/corrupt. Lock-free (a plain file read), like the Swift
    // getxattr reads.
    private fun readMeta(url: String): ImageMeta? {
        val file = metaFileForUrl(url)
        return try {
            if (file.exists()) ImageMetaCodec.decode(file.readBytes()) else null
        } catch (t: Throwable) {
            null
        }
    }

    // Evict oldest-by-last-modified files until the directory is back under budget, deleting each bytes file
    // together with its meta sidecar. Trim accounting uses the pure DiskTrim.filesToEvict (JVM-tested).
    private fun trimIfNeeded() {
        val files = directory.listFiles() ?: return
        val entries = files
            .filter { it.isFile && HASH_REGEX.matches(it.name) }
            .map { byteFile ->
                val meta = File(directory, byteFile.name + META_SUFFIX)
                val metaSize = if (meta.exists()) meta.length() else 0L
                TrimEntry(id = byteFile, size = byteFile.length() + metaSize, lastModified = byteFile.lastModified())
            }
        for (byteFile in DiskTrim.filesToEvict(entries, byteLimit)) {
            byteFile.delete()
            File(directory, byteFile.name + META_SUFFIX).delete()
        }
    }

    // Write bytes to a temp file in the same directory, then atomically rename over the destination. A partial
    // write can never be observed as a valid cache entry. Returns false if the write failed.
    private fun writeAtomically(destination: File, bytes: ByteArray): Boolean {
        val temp = File(destination.parentFile, destination.name + TEMP_SUFFIX + tempCounter.getAndIncrement())
        return try {
            temp.writeBytes(bytes)
            if (temp.renameTo(destination)) {
                true
            } else {
                // renameTo can fail if the destination exists on some filesystems; replace explicitly.
                destination.delete()
                temp.renameTo(destination).also { if (!it) temp.delete() }
            }
        } catch (t: Throwable) {
            temp.delete()
            false
        }
    }

    companion object {
        private const val META_SUFFIX = ".meta"
        private const val TEMP_SUFFIX = ".tmp"
        private val HASH_REGEX = Regex("^[0-9a-f]{64}$")
        private val HEX = "0123456789abcdef".toCharArray()

        // Monotonic counter for unique temp-file names during atomic writes (thread-safe, collision-free).
        private val tempCounter = AtomicLong(0)

        // SHA-256 hex of the URL string, used as the on-disk filename (matches the Swift CryptoKit usage). Hot
        // path - a table-based encoder keeps it fast and produces canonical lowercase hex, so cache filenames
        // stay stable.
        private fun hash(string: String): String {
            val digest = MessageDigest.getInstance("SHA-256").digest(string.toByteArray(Charsets.UTF_8))
            val chars = CharArray(digest.size * 2)
            for (i in digest.indices) {
                val b = digest[i].toInt() and 0xFF
                chars[i * 2] = HEX[b ushr 4]
                chars[i * 2 + 1] = HEX[b and 0x0F]
            }
            return String(chars)
        }
    }
}
