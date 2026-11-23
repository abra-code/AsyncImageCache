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
        val url = dataUrl(pngBytes(30, 20))
        val request = ImageRequest(url)

        val first = ImageStore(context, name)
        assertNotNull(loadBlocking(first, request))
        assertTrue("disk dir under cacheDir/AsyncImageCache/<name>",
            first.diskDirectory.path.contains("AsyncImageCache/$name"))
        assertTrue("original bytes on disk", first.diskFileExists(url))

        // The data: URL could decode itself, so swap the cached bytes for a different picture: only a load served
        // from disk sees it.
        DiskCache(context.cacheDir, name, 10L * 1024 * 1024).fileForUrl(url).writeBytes(pngBytes(60, 20))

        val second = ImageStore(context, name)
        try {
            assertNull("fresh instance starts with empty memory", second.cachedImage(request))
            assertNotNull("fresh instance serves the image", loadBlocking(second, request))
            assertEquals("original bytes come from disk", Size(60, 20), second.cachedOriginalBytes(url)?.pixelSize)
        } finally {
            second.removeAll()
        }
    }

    // A local file is its own copy: it is never kept in the disk tier, so after it is edited a fresh store (a
    // relaunch) shows the new picture, not the old one.
    @Test fun localFileImagesSkipTheDiskCache() {
        val name = uniqueName()
        val tempFile = File(context.cacheDir, "aic-${UUID.randomUUID()}.png").apply { writeBytes(pngBytes(30, 20)) }
        val fileUrl = tempFile.toURI().toString()   // file:///...
        val first = ImageStore(context, name)
        try {
            assertNotNull(loadBlocking(first, ImageRequest(fileUrl)))
            assertFalse("a local file is not copied into the disk cache", first.diskFileExists(fileUrl))

            tempFile.writeBytes(pngBytes(40, 10))
            val second = ImageStore(context, name)
            assertNull("nothing about the old file was kept", second.cachedPixelSize(fileUrl))
            assertNotNull(loadBlocking(second, ImageRequest(fileUrl)))
            assertEquals("the edited file is shown", Size(40, 10), second.cachedPixelSize(fileUrl))
        } finally {
            first.removeAll()
            tempFile.delete()
        }
    }

    // In the same run: a local file's memory entries are keyed on its modification time and size, so after an
    // edit the old picture is a miss and the next load reads the new one.
    @Test fun anEditedLocalFileShowsItsNewPictureInTheSameRun() {
        val tempFile = File(context.cacheDir, "aic-${UUID.randomUUID()}.png").apply { writeBytes(pngBytes(30, 20)) }
        val fileUrl = tempFile.toURI().toString()   // file:/...
        val request = ImageRequest(fileUrl)
        val store = ImageStore(context, uniqueName())
        try {
            assertNotNull(loadBlocking(store, request))
            assertNotNull(store.cachedImage(request))

            tempFile.writeBytes(pngBytes(40, 10))
            // A different modification time for sure, not only a different size.
            tempFile.setLastModified(System.currentTimeMillis() + 10_000)
            assertNull("the old picture is not shown for the edited file", store.cachedImage(request))
            assertNull(store.cachedPixelSize(fileUrl))
            assertNotNull(loadBlocking(store, request))
            assertEquals("the edited file is shown", Size(40, 10), store.cachedPixelSize(fileUrl))
        } finally {
            store.removeAll()
            tempFile.delete()
        }
    }

    @Test fun pixelSizeSurvivesRelaunchWithoutDecoding() {
        val name = uniqueName()
        val url = dataUrl(pngBytes(123, 45))
        val request = ImageRequest(url)

        val store = ImageStore(context, name)
        assertNotNull(loadBlocking(store, request))
        assertEquals(Size(123, 45), store.cachedPixelSize(url))

        val second = ImageStore(context, name)
        try {
            assertNull(second.cachedImage(request))
            assertEquals("size read from the disk meta, no decode", Size(123, 45), second.cachedPixelSize(url))
        } finally {
            second.removeAll()
        }
    }

    @Test fun placeholderSurvivesRelaunch() {
        val name = uniqueName()
        val url = dataUrl(pngBytes(16, 16))
        val store = ImageStore(context, name)
        assertNotNull(loadBlocking(store, ImageRequest(url)))
        val afterLoad = store.placeholder(url)!!
        assertEquals(6, afterLoad.dimension)

        val second = ImageStore(context, name)
        try {
            assertEquals("grid round-trips via the meta, no decode", afterLoad, second.placeholder(url))
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

    // --- Download size limit ---

    @Test fun downloadByteLimitDefaultsSetsAndClamps() {
        val store = ImageStore(context, uniqueName())
        assertEquals(32L * 1024 * 1024, store.downloadByteLimit)
        assertEquals(32L * 1024 * 1024, ImageStore.DEFAULT_DOWNLOAD_BYTE_LIMIT)
        store.downloadByteLimit = 500L * 1024 * 1024
        assertEquals(500L * 1024 * 1024, store.downloadByteLimit)
        store.downloadByteLimit = -5
        assertEquals("a negative limit counts as 0", 0L, store.downloadByteLimit)
        assertEquals(1000L, ImageStore(context, uniqueName(), downloadByteLimit = 1000).downloadByteLimit)
        assertEquals(0L, ImageStore(context, uniqueName(), downloadByteLimit = -1).downloadByteLimit)
    }

    // A body one byte past the limit is refused, whether it declares its length or not, and nothing is cached;
    // with the limit raised to the body's size the same address loads.
    @Test fun aDownloadPastItsLimitIsRefusedUntilTheLimitIsRaised() {
        val png = pngBytes(40, 20)
        val server = TestHttpServer { path ->
            TestHttpServer.Response(200, png, contentLength = if (path == "/sized.png") png.size.toLong() else null)
        }
        server.start()
        try {
            for (path in listOf("/sized.png", "/unsized.png")) {
                val store = ImageStore(context, uniqueName(), downloadByteLimit = png.size - 1L)
                try {
                    val request = ImageRequest(server.url(path))
                    assertNull(path, loadBlocking(store, request))
                    assertFalse(path, store.diskFileExists(request.url))
                    store.downloadByteLimit = png.size.toLong()
                    val bitmap = loadBlocking(store, request)
                    assertNotNull(path, bitmap)
                    assertEquals(path, Size(40, 20), store.cachedPixelSize(request.url))
                    assertTrue(path, store.diskFileExists(request.url))
                } finally {
                    store.removeAll()
                }
            }
        } finally {
            server.stop()
        }
    }

    // A declared length past the limit ends the download before its body is read. The server declares a gigabyte
    // but sends only the picture and then waits, so a download that read the body would wait for its read timeout.
    @Test fun aDeclaredLengthPastTheLimitIsRefusedAtOnce() {
        val server = TestHttpServer {
            TestHttpServer.Response(200, pngBytes(4, 4), contentLength = 1L shl 30, holdOpenMs = 40_000)
        }
        server.start()
        val store = ImageStore(context, uniqueName())
        try {
            val start = System.nanoTime()
            assertNull(loadBlocking(store, ImageRequest(server.url("/huge.png")), timeoutMs = 10_000))
            assertTrue(System.nanoTime() - start < 5_000_000_000L)
        } finally {
            store.removeAll()
            server.stop()
        }
    }

    @Test fun anEndlessBodyIsCutOff() {
        val server = TestHttpServer { TestHttpServer.Response(200, pngBytes(4, 4), contentLength = null, endless = true) }
        server.start()
        val store = ImageStore(context, uniqueName(), downloadByteLimit = 1L shl 20)
        try {
            assertNull(loadBlocking(store, ImageRequest(server.url("/endless.png")), timeoutMs = 10_000))
        } finally {
            store.removeAll()
            server.stop()
        }
    }

    // A redirect is followed and its own body is not kept: here it never ends.
    @Test fun aRedirectWithAnEndlessBodyIsFollowed() {
        val png = pngBytes(12, 6)
        val server = TestHttpServer { path ->
            if (path == "/ok.png") {
                TestHttpServer.Response(200, png)
            } else {
                TestHttpServer.Response(302, ByteArray(0), contentLength = null, extraHeaders = listOf("Location: /ok.png"),
                                        endless = true)
            }
        }
        server.start()
        val store = ImageStore(context, uniqueName())
        try {
            val request = ImageRequest(server.url("/redirect.png"))
            assertNotNull("the redirect is followed", loadBlocking(store, request, timeoutMs = 10_000))
            assertEquals(Size(12, 6), store.cachedPixelSize(request.url))
            assertEquals("the redirect, then its target", 2, server.requestCount)
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
