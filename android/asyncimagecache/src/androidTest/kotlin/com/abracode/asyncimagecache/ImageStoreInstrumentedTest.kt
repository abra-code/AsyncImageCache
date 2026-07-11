// ImageStoreInstrumentedTest.kt - end-to-end integration tests for the async loader + two-tier cache, ported
// from AsyncImageCacheTests.swift and extended with the concurrency cases from porting-plan section 4: N
// concurrent loads issue exactly one fetch, disk hydration across a fresh store (simulated relaunch), trim
// under a tiny budget, non-2xx rejection, and main-thread completion. Uses data:/file: URLs and the in-process
// TestHttpServer (no real network).

package com.abracode.asyncimagecache

import android.content.Context
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.os.Looper
import android.util.Base64
import android.util.Size
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import java.io.ByteArrayOutputStream
import java.io.File
import java.util.UUID
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean

@RunWith(AndroidJUnit4::class)
class ImageStoreInstrumentedTest {

    private val context: Context get() = ApplicationProvider.getApplicationContext()

    private fun uniqueName() = "test-${UUID.randomUUID()}"

    private fun pngBytes(width: Int, height: Int, color: Int = Color.rgb(51, 102, 204)): ByteArray {
        val bitmap = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
        Canvas(bitmap).drawColor(color)
        val out = ByteArrayOutputStream()
        bitmap.compress(Bitmap.CompressFormat.PNG, 100, out)
        return out.toByteArray()
    }

    private fun dataUrl(png: ByteArray): String =
        "data:image/png;base64," + Base64.encodeToString(png, Base64.NO_WRAP)

    // Load synchronously for test convenience, asserting the completion lands on the main thread.
    private fun loadBlocking(store: ImageStore, request: ImageRequest, timeoutMs: Long = 5000): Bitmap? {
        val latch = CountDownLatch(1)
        var result: Bitmap? = null
        var onMain = false
        store.load(request) { bitmap ->
            onMain = Looper.myLooper() == Looper.getMainLooper()
            result = bitmap
            latch.countDown()
        }
        assertTrue("completion timed out", latch.await(timeoutMs, TimeUnit.MILLISECONDS))
        assertTrue("completion must fire on the main thread", onMain)
        return result
    }

    // --- data: load + sync cache + main-thread completion ---

    @Test fun loadDataUrlSucceedsOnMainAndCachesSynchronously() {
        val store = ImageStore(context, uniqueName())
        try {
            val request = ImageRequest(dataUrl(pngBytes(24, 24)))
            assertNotNull(loadBlocking(store, request))
            assertNotNull("variant cached synchronously after load", store.cachedImage(request))
            assertEquals(Size(24, 24), store.cachedPixelSize(request.url))
        } finally {
            store.removeAll()
        }
    }

    // --- Downscale ---

    @Test fun downscaleToTargetWidth() {
        val store = ImageStore(context, uniqueName())
        try {
            val request = ImageRequest(dataUrl(pngBytes(100, 100)), targetWidth = 40f)
            val image = loadBlocking(store, request)!!
            assertEquals(40, image.width)
            assertEquals(Size(100, 100), store.cachedPixelSize(request.url))   // natural size preserved
        } finally {
            store.removeAll()
        }
    }

    // --- Disk persistence across a fresh instance (simulated relaunch) ---

    @Test fun diskPersistenceAcrossFreshInstance() {
        val name = uniqueName()
        val tempFile = File(context.cacheDir, "aic-${UUID.randomUUID()}.png").apply { writeBytes(pngBytes(30, 20)) }
        val fileUrl = tempFile.toURI().toString()   // file:///...
        val request = ImageRequest(fileUrl)

        val first = ImageStore(context, name)
        assertNotNull(loadBlocking(first, request))
        assertTrue("disk dir under cacheDir/AsyncImageCache/<name>",
            first.diskDirectory.path.contains("AsyncImageCache/$name"))
        assertTrue("original bytes on disk", first.diskFileExists(fileUrl))

        // Delete the source so any later success MUST come from disk, not the file: path.
        assertTrue(tempFile.delete())

        val second = ImageStore(context, name)
        try {
            assertNull("fresh instance starts with empty memory", second.cachedImage(request))
            assertNotNull("fresh instance serves the deleted file from disk", loadBlocking(second, request))
            assertNotNull(second.cachedOriginalBytes(fileUrl))
        } finally {
            second.removeAll()
        }
    }

    @Test fun pixelSizeSurvivesRelaunchWithoutDecoding() {
        val name = uniqueName()
        val tempFile = File(context.cacheDir, "aic-${UUID.randomUUID()}.png").apply { writeBytes(pngBytes(123, 45)) }
        val fileUrl = tempFile.toURI().toString()
        val request = ImageRequest(fileUrl)

        val store = ImageStore(context, name)
        assertNotNull(loadBlocking(store, request))
        assertEquals(Size(123, 45), store.cachedPixelSize(fileUrl))

        assertTrue(tempFile.delete())
        val second = ImageStore(context, name)
        try {
            assertNull(second.cachedImage(request))
            assertEquals("size read from the disk meta, no decode", Size(123, 45), second.cachedPixelSize(fileUrl))
        } finally {
            second.removeAll()
        }
    }

    @Test fun placeholderSurvivesRelaunch() {
        val name = uniqueName()
        val tempFile = File(context.cacheDir, "aic-${UUID.randomUUID()}.png").apply { writeBytes(pngBytes(16, 16)) }
        val fileUrl = tempFile.toURI().toString()
        val store = ImageStore(context, name)
        assertNotNull(loadBlocking(store, ImageRequest(fileUrl)))
        val afterLoad = store.placeholder(fileUrl)!!
        assertEquals(6, afterLoad.dimension)

        assertTrue(tempFile.delete())
        val second = ImageStore(context, name)
        try {
            assertEquals("grid round-trips via the meta, no decode", afterLoad, second.placeholder(fileUrl))
        } finally {
            second.removeAll()
        }
    }

    // --- removeAll ---

    @Test fun removeAllClearsMemoryAndDisk() {
        val store = ImageStore(context, uniqueName())
        val request = ImageRequest(dataUrl(pngBytes(20, 20)))
        assertNotNull(loadBlocking(store, request))
        assertNotNull(store.cachedImage(request))

        store.removeAll()
        assertNull(store.cachedImage(request))
        assertNull(store.cachedOriginalBytes(request.url))
        assertFalse(store.diskFileExists(request.url))
    }

    // --- In-flight de-duplication: N concurrent loads -> exactly one fetch ---

    @Test fun concurrentIdenticalRequestsDeduplicateToOneFetch() {
        val png = pngBytes(32, 32)
        val server = TestHttpServer { TestHttpServer.Response(200, png, delayMs = 300) }
        server.start()
        val store = ImageStore(context, uniqueName())
        try {
            val request = ImageRequest(server.url("/image.png"))
            val count = 8
            val latch = CountDownLatch(count)
            val allMain = AtomicBoolean(true)
            repeat(count) {
                store.load(request) { bitmap ->
                    if (Looper.myLooper() != Looper.getMainLooper()) allMain.set(false)
                    if (bitmap == null) allMain.set(false)
                    latch.countDown()
                }
            }
            assertTrue("all completions fired", latch.await(10, TimeUnit.SECONDS))
            assertTrue("every completion non-null on the main thread", allMain.get())
            assertEquals("de-dup must issue exactly one network fetch", 1, server.requestCount)
            assertNotNull(store.cachedImage(request))
        } finally {
            store.removeAll()
            server.stop()
        }
    }

    // --- Non-2xx rejection ---

    @Test fun non2xxResponseIsRejectedAndNotCached() {
        val server = TestHttpServer { TestHttpServer.Response(404, "not found".toByteArray()) }
        server.start()
        val store = ImageStore(context, uniqueName())
        try {
            val request = ImageRequest(server.url("/missing.png"))
            assertNull("a 404 body must not decode to a variant", loadBlocking(store, request))
            assertNull(store.cachedImage(request))
            assertFalse("a rejected body must not be persisted", store.diskFileExists(request.url))
        } finally {
            store.removeAll()
            server.stop()
        }
    }

    // --- Trim under a tiny disk budget ---

    @Test fun diskTrimEvictsUnderTinyBudget() {
        // Budget only large enough for ~1 image; a second store write should evict the first.
        val store = ImageStore(context, uniqueName(), diskByteLimit = 4 * 1024)
        try {
            val a = ImageRequest(dataUrl(pngBytes(200, 200, Color.RED)))
            val b = ImageRequest(dataUrl(pngBytes(200, 200, Color.BLUE)))
            assertNotNull(loadBlocking(store, a))
            assertNotNull(loadBlocking(store, b))
            // After the second store + trim, the directory must be within a small multiple of the budget.
            val bytesOnDisk = store.diskDirectory.listFiles()
                ?.filter { it.isFile }?.sumOf { it.length() } ?: 0L
            assertTrue("disk usage $bytesOnDisk should be bounded by the trim", bytesOnDisk <= 64 * 1024)
        } finally {
            store.removeAll()
        }
    }

    // --- Animated flag after load ---

    @Test fun staticImageReportsNotAnimatedAfterLoad() {
        val store = ImageStore(context, uniqueName())
        try {
            val request = ImageRequest(dataUrl(pngBytes(10, 10)))
            assertFalse("unknown (false) before load", store.isAnimated(request.url))
            assertNotNull(loadBlocking(store, request))
            assertFalse("a PNG is not animated", store.isAnimated(request.url))
        } finally {
            store.removeAll()
        }
    }

    @Test fun placeholderImageRendersAfterLoad() {
        val store = ImageStore(context, uniqueName())
        try {
            val request = ImageRequest(dataUrl(pngBytes(16, 16)))
            assertNull("no preview before load", store.placeholderImage(request.url))
            assertNotNull(loadBlocking(store, request))
            val preview = store.placeholderImage(request.url)
            assertNotNull("a preview exists after load", preview)
            assertTrue(preview!!.width > 0)
        } finally {
            store.removeAll()
        }
    }

    // --- Memory limits ---

    @Test fun memoryByteLimitConfiguredOnBothTiers() {
        val store = ImageStore(context, uniqueName(), memoryByteLimit = 5L * 1024 * 1024)
        try {
            assertEquals(5L * 1024 * 1024, store.variantByteLimit)
            assertEquals(5L * 1024 * 1024, store.originalByteLimit)
        } finally {
            store.removeAll()
        }
    }

    @Test fun recommendedMemoryByteLimitWithinClamp() {
        val recommended = ImageStore.recommendedMemoryByteLimit(context)
        assertTrue(recommended >= 64L * 1024 * 1024)
        assertTrue(recommended <= 320L * 1024 * 1024)
        val store = ImageStore(context, uniqueName())
        try {
            assertEquals("a default store uses the recommended limit", recommended, store.variantByteLimit)
        } finally {
            store.removeAll()
        }
    }
}
