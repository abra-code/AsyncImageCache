// ImageStore.kt
//
// The public entry point: an async image loader + two-tier cache. EVERYTHING heavy - byte fetch, decode,
// downscale, corner-rounding, encoding - runs off the main thread; the ONLY main-thread work is the final
// completion callback. Ports Sources/AsyncImageCache/ImageStore.swift.
//
// Two tiers:
//   - in-memory: a MemoryCache of ready-to-draw variants (keyed by the full ImageRequest) + a MemoryCache of
//     originals (raw transport bytes + natural pixel size + placeholder + animated flag, keyed by URL).
//   - on-disk: the ORIGINAL transport bytes (DiskCache), which survive relaunch and enable offline reads.
//
// Thread safety comes from the MemoryCache/ConcurrentHashMap tiers plus a single lock guarding the in-flight
// de-duplication table (the NSLock discipline is ported 1:1 - a plain lock + a list of completions, no clever
// coroutine sharing). Off-main pipeline: fetch on Dispatchers.IO, decode/process on Dispatchers.Default,
// completion posted to the main Looper so the main-thread guarantee holds even for callers outside coroutines.

package com.abracode.asyncimagecache

import android.app.ActivityManager
import android.content.ComponentCallbacks2
import android.content.Context
import android.content.res.Configuration
import android.graphics.Bitmap
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.util.Base64
import android.util.Size
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withContext
import java.io.File
import java.net.HttpURLConnection
import java.net.URL
import java.net.URLDecoder
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.locks.ReentrantLock
import kotlin.concurrent.withLock
import kotlin.coroutines.resume

/** The original transport bytes + natural pixel size for a loaded URL (for consumers that need the source). */
data class OriginalBytes(val data: ByteArray, val pixelSize: Size) {
    override fun equals(other: Any?): Boolean {
        if (this === other) return true
        if (other !is OriginalBytes) return false
        return pixelSize == other.pixelSize && data.contentEquals(other.data)
    }

    override fun hashCode(): Int = 31 * pixelSize.hashCode() + data.contentHashCode()
}

class ImageStore(
    context: Context,
    val name: String = "default",
    memoryCountLimit: Int = DEFAULT_MEMORY_COUNT_LIMIT,
    memoryByteLimit: Long = recommendedMemoryByteLimit(context),
    diskByteLimit: Long = DEFAULT_DISK_BYTE_LIMIT,
) {
    // Application context: needed for cacheDir + the memory-pressure callback; never leak an Activity.
    private val appContext: Context = context.applicationContext

    private val variantCache = MemoryCache<String, Bitmap>(
        countLimit = memoryCountLimit,
        byteLimit = maxOf(0L, memoryByteLimit),
        sizeOf = { it.memoryCost.toLong() },
    )
    private val originalCache = MemoryCache<String, OriginalEntry>(
        countLimit = memoryCountLimit,
        byteLimit = maxOf(0L, memoryByteLimit),
        sizeOf = { maxOf(1L, it.rawData.size.toLong()) },
    )

    // Decode-free memos sourced from the disk meta (pixel size / placeholder / animated). The plan specifies
    // ConcurrentHashMap; cleared on clearMemory and under memory pressure.
    private val pixelSizeMemo = ConcurrentHashMap<String, Size>()
    private val placeholderMemo = ConcurrentHashMap<String, ImagePlaceholder>()
    private val animatedMemo = ConcurrentHashMap<String, Boolean>()

    private val diskCache = DiskCache(appContext.cacheDir, name, diskByteLimit)

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    private val mainHandler = Handler(Looper.getMainLooper())

    // De-duplicate concurrent identical requests: the first inserts an entry, later ones append their
    // completion, and all fire together when the single fetch finishes. Guarded by `lock`.
    private val lock = ReentrantLock()
    private val inFlight = HashMap<ImageRequest, MutableList<(Bitmap?) -> Unit>>()

    // Memory-pressure hook - the explicit Android analog of NSCache's automatic purge (porting plan section 8).
    // The TRIM_MEMORY_* levels are deprecated as of API 34 but remain the mechanism for proportional eviction on
    // the minSdk 31 baseline; the deprecation is intentional here.
    @Suppress("DEPRECATION")
    private val memoryCallback = object : ComponentCallbacks2 {
        override fun onTrimMemory(level: Int) {
            when {
                level >= ComponentCallbacks2.TRIM_MEMORY_COMPLETE -> clearMemory()
                level >= ComponentCallbacks2.TRIM_MEMORY_BACKGROUND -> {
                    variantCache.trimToBytes(variantCache.byteLimit / 2)
                    originalCache.trimToBytes(originalCache.byteLimit / 2)
                }
            }
        }

        @Deprecated("Deprecated in Java")
        override fun onLowMemory() = clearMemory()

        override fun onConfigurationChanged(newConfig: Configuration) {}
    }

    init {
        appContext.registerComponentCallbacks(memoryCallback)
    }

    /** The in-memory record of an original: raw bytes + natural size + placeholder + animated flag. Immutable. */
    private class OriginalEntry(
        val rawData: ByteArray,
        val pixelSize: Size,
        val placeholder: ImagePlaceholder?,
        val isAnimated: Boolean,
    )

    // MARK: - Synchronous lookups

    /** The ready-to-draw variant for the exact request, if in memory. null on a miss. Thread-safe. */
    fun cachedImage(request: ImageRequest): Bitmap? = variantCache.get(request.variantKey)

    /**
     * The natural PIXEL size of a URL's image, if known WITHOUT decoding. Thread-safe. Lets a consumer reserve
     * layout space before the pixels arrive - including across relaunch: memory is empty then, but the size rode
     * along with the on-disk bytes in the sidecar meta, so this reads it (no decode) and memoizes it.
     */
    fun cachedPixelSize(url: String): Size? {
        originalCache.get(url)?.let { return it.pixelSize }
        pixelSizeMemo[url]?.let { return it }
        val size = diskCache.pixelSize(url) ?: return null
        pixelSizeMemo[url] = size
        return size
    }

    /**
     * The placeholder grid for a URL's image, if known WITHOUT decoding - a soft preview to fill the reserved
     * box while the pixels load. Thread-safe, survives relaunch via the on-disk meta. null when none was stored
     * (the caller then uses a neutral fallback); there is no decode fallback, since the grid needs real pixels.
     */
    fun placeholder(url: String): ImagePlaceholder? {
        originalCache.get(url)?.let { return it.placeholder }
        placeholderMemo[url]?.let { return it }
        val placeholder = diskCache.placeholder(url) ?: return null
        placeholderMemo[url] = placeholder
        return placeholder
    }

    /**
     * The placeholder grid rendered as a ready-to-draw bitmap (the soft-gradient preview), or null if no
     * placeholder is known for the URL. Available only AFTER the image has been loaded once, then it survives
     * relaunch via the on-disk meta.
     */
    fun placeholderImage(url: String): Bitmap? {
        val grid = placeholder(url) ?: return null
        return ImageProcessing.gridBitmap(grid)
    }

    /**
     * Whether the URL's image is a multi-frame (animated) source. Thread-safe and decode-free: resolves memory
     * originalCache -> animatedMemo -> the on-disk meta (with a container-sniff fallback), so it survives
     * relaunch. Returns false when unknown - the flag is known only AFTER the image has passed through once. The
     * ready-to-draw variant is always a single flattened frame; a consumer that wants playback reads
     * cachedOriginalBytes(url) and drives its own animated renderer.
     */
    fun isAnimated(url: String): Boolean {
        originalCache.get(url)?.let { return it.isAnimated }
        animatedMemo[url]?.let { return it }
        val animated = diskCache.isAnimated(url) ?: return false
        animatedMemo[url] = animated
        return animated
    }

    /**
     * The ORIGINAL transport bytes + natural pixel size for a loaded URL, or null if not loaded. For consumers
     * that need the source bytes (e.g. driving GIF playback); the cache does no format transcoding itself.
     */
    fun cachedOriginalBytes(url: String): OriginalBytes? {
        val record = originalCache.get(url) ?: return null
        return OriginalBytes(record.rawData, record.pixelSize)
    }

    // MARK: - Loading

    /**
     * Resolve the ready-to-draw variant for `request`, calling `completion` on the MAIN thread. A memory hit
     * delivers immediately; otherwise the byte fetch / decode / downscale / rounding all happen off-main.
     */
    fun load(request: ImageRequest, completion: (Bitmap?) -> Unit) {
        variantCache.get(request.variantKey)?.let {
            deliver(it, listOf(completion))
            return
        }

        var shouldLaunch = false
        lock.withLock {
            val pending = inFlight[request]
            if (pending != null) {
                pending.add(completion)
            } else {
                inFlight[request] = mutableListOf(completion)
                shouldLaunch = true
            }
        }
        if (shouldLaunch) {
            scope.launch {
                startProduction(request)
            }
        }
    }

    /** Kotlin-native convenience over the same path; resumes with the variant (or null) once loaded. */
    suspend fun loadAsync(request: ImageRequest): Bitmap? = suspendCancellableCoroutine { continuation ->
        load(request) { bitmap ->
            continuation.resume(bitmap)
        }
    }

    fun clearMemory() {
        variantCache.clear()
        originalCache.clear()
        pixelSizeMemo.clear()
        placeholderMemo.clear()
        animatedMemo.clear()
    }

    fun removeAll() {
        clearMemory()
        diskCache.removeAll()
    }

    // MARK: - Test hooks (internal)

    internal val diskDirectory: File get() = diskCache.directory
    internal fun diskFileExists(url: String): Boolean = diskCache.fileExists(url)
    internal val variantByteLimit: Long get() = variantCache.byteLimit
    internal val originalByteLimit: Long get() = originalCache.byteLimit

    // MARK: - Off-main pipeline

    // Resolve original bytes (memory -> disk -> source) and hand them to finishProduction. Local schemes
    // (data:/file:/content:) and remote fetches all resolve on Dispatchers.IO; the decode/process work happens
    // on Dispatchers.Default. Fresh bytes are written to disk; cache hits are not.
    private suspend fun startProduction(request: ImageRequest) {
        val url = request.url
        originalCache.get(url)?.let {
            finishProduction(request, it.rawData, writeDisk = false)
            return
        }
        val disk = withContext(Dispatchers.IO) { diskCache.data(url) }
        if (disk != null) {
            finishProduction(request, disk, writeDisk = false)
            return
        }
        val scheme = try {
            Uri.parse(url).scheme?.lowercase()
        } catch (t: Throwable) {
            null
        }
        val bytes = withContext(Dispatchers.IO) {
            when (scheme) {
                "data", "file", "content" -> resolveLocalBytes(url, scheme)
                else -> fetchRemote(url)
            }
        }
        finishProduction(request, bytes, writeDisk = true)
    }

    // Decode, record the original (+ disk write for fresh bytes), build + cache the ready-to-draw variant, then
    // fire the pending completions. nil bytes (fetch failed) delivers nil.
    private suspend fun finishProduction(request: ImageRequest, bytes: ByteArray?, writeDisk: Boolean) {
        var variant: Bitmap? = null
        try {
            if (bytes != null) {
                val decoded = ImageProcessing.decode(bytes)
                if (decoded != null) {
                    recordOriginal(request.url, bytes, decoded, writeDisk)
                    val built = ImageProcessing.variant(
                        source = decoded,
                        targetWidth = request.quantizedTargetWidth?.toFloat(),
                        cornerRadius = request.quantizedCornerRadius.toFloat(),
                    )
                    variantCache.put(request.variantKey, built)
                    variant = built
                }
            }
        } catch (c: kotlinx.coroutines.CancellationException) {
            throw c
        } catch (t: Throwable) {
            // Any unexpected failure (e.g. an allocation error deep in the pipeline) delivers nil rather than
            // crashing the work thread - and, crucially, the `finally` below still removes the in-flight entry so
            // pending completions always fire and a later identical load is not appended to a dead list.
            variant = null
        } finally {
            val pending = lock.withLock { inFlight.remove(request) } ?: emptyList()
            deliver(variant, pending)
        }
    }

    // Record the raw bytes + natural size + placeholder + animated flag in memory and (for freshly fetched
    // bytes) persist the ORIGINAL transport bytes to disk. No transcoding here - that is a consumer concern.
    private suspend fun recordOriginal(url: String, data: ByteArray, decoded: Bitmap, writeDisk: Boolean) {
        val pixelSize = ImageProcessing.pixelSize(decoded)
        val placeholder = ImageProcessing.placeholder(decoded)
        val isAnimated = ImageProcessing.isAnimated(data)
        originalCache.put(url, OriginalEntry(data, pixelSize, placeholder, isAnimated))
        if (writeDisk) {
            withContext(Dispatchers.IO) {
                diskCache.store(data, pixelSize, placeholder, isAnimated, url)
            }
        } else if (placeholder != null) {
            // Bytes came from the cache: files written by a build that predates the placeholder (or whose meta
            // was stripped) never pass through store() again, so repair the meta here.
            withContext(Dispatchers.IO) {
                diskCache.storePlaceholderIfMissing(placeholder, url)
            }
        }
    }

    // The ONLY main-thread work: fire the pending completions.
    private fun deliver(image: Bitmap?, completions: List<(Bitmap?) -> Unit>) {
        if (completions.isEmpty()) {
            return
        }
        mainHandler.post {
            for (completion in completions) {
                completion(image)
            }
        }
    }

    // --- Byte sources ---

    // Fetch remote bytes over HTTP(S). Bypasses any shared cache (we own caching - no double cache, mirroring
    // the Swift `urlCache = nil`). A non-2xx status is rejected so an error page (some CDNs serve a placeholder
    // image or an HTML error with a 404/500) is never decoded into a "successful" variant or persisted to disk.
    private fun fetchRemote(url: String): ByteArray? {
        val connection = try {
            (URL(url).openConnection() as HttpURLConnection)
        } catch (t: Throwable) {
            return null
        }
        return try {
            connection.useCaches = false
            connection.connectTimeout = CONNECT_TIMEOUT_MS
            connection.readTimeout = READ_TIMEOUT_MS
            connection.connect()
            if (connection.responseCode !in 200..299) {
                return null
            }
            connection.inputStream.use { it.readBytes() }
        } catch (t: Throwable) {
            null
        } finally {
            connection.disconnect()
        }
    }

    // data:/file:/content: bytes. `data:` is decoded inline (base64 or percent-encoded); `file:` is read
    // directly; `content:` goes through the ContentResolver (the Android-idiom addition for photo-picker flows -
    // porting plan section 8). content: is Android-app-level only; the ActionUI element contract stays
    // http/https/data/file.
    private fun resolveLocalBytes(url: String, scheme: String?): ByteArray? {
        return try {
            when (scheme) {
                "data" -> decodeDataUri(url)
                "file" -> File(Uri.parse(url).path ?: return null).readBytes()
                "content" -> appContext.contentResolver.openInputStream(Uri.parse(url))?.use { it.readBytes() }
                else -> null
            }
        } catch (t: Throwable) {
            null
        }
    }

    private fun decodeDataUri(url: String): ByteArray? {
        val comma = url.indexOf(',')
        if (comma < 0) {
            return null
        }
        val meta = url.substring(0, comma)
        val payload = url.substring(comma + 1)
        return if (meta.contains(";base64", ignoreCase = true)) {
            Base64.decode(payload, Base64.DEFAULT)
        } else {
            URLDecoder.decode(payload, "UTF-8").toByteArray(Charsets.UTF_8)
        }
    }

    companion object {
        const val DEFAULT_MEMORY_COUNT_LIMIT = 150
        const val DEFAULT_DISK_BYTE_LIMIT = 200L * 1024 * 1024

        private const val CONNECT_TIMEOUT_MS = 15_000
        private const val READ_TIMEOUT_MS = 30_000

        @Volatile
        private var sharedInstance: ImageStore? = null

        /** Lazy singleton bound to the application context. */
        fun shared(context: Context): ImageStore {
            return sharedInstance ?: synchronized(this) {
                sharedInstance ?: ImageStore(context.applicationContext).also { sharedInstance = it }
            }
        }

        /**
         * A per-tier memory budget scaled to the device's RAM. A fixed default is wrong at both ends: too low
         * starves a modern flagship, too high risks an OOM/kill on a low-RAM device. So: a fraction of total
         * device RAM, clamped to a floor and ceiling, tightened on `isLowRamDevice`. Mirrors the Swift
         * `recommendedMemoryByteLimit` philosophy (physical/16, clamped). Bitmap pixels live in native memory
         * (since Android O), so bounding by device RAM - not the Java heap - is the right measure.
         */
        fun recommendedMemoryByteLimit(context: Context): Long {
            val activityManager = context.getSystemService(Context.ACTIVITY_SERVICE) as? ActivityManager
            val fraction: Long
            val lowRam: Boolean
            if (activityManager != null) {
                val info = ActivityManager.MemoryInfo()
                activityManager.getMemoryInfo(info)
                fraction = info.totalMem / 16
                lowRam = activityManager.isLowRamDevice
            } else {
                fraction = Runtime.getRuntime().maxMemory() / 4
                lowRam = false
            }
            val floorBytes = 64L * 1024 * 1024
            val ceilingBytes = if (lowRam) 128L * 1024 * 1024 else 320L * 1024 * 1024
            return fraction.coerceIn(floorBytes, ceilingBytes)
        }
    }
}
