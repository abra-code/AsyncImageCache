// DiskCacheInstrumentedTest.kt - the on-disk tier's fallback + repair behaviors, ported from the Swift DiskCache
// tests. These are instrumented because the fallbacks call ImageProcessing (header read / container sniff),
// which touches android.graphics. The canonical-filename test pins the SHA-256 hex so a drift can never
// silently orphan an existing cache.

package com.abracode.asyncimagecache

import android.content.Context
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.util.Size
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import java.io.ByteArrayOutputStream
import java.security.MessageDigest
import java.util.UUID

@RunWith(AndroidJUnit4::class)
class DiskCacheInstrumentedTest {

    private val context: Context get() = ApplicationProvider.getApplicationContext()
    private fun uniqueName() = "test-${UUID.randomUUID()}"
    private fun disk(byteLimit: Long = 10L * 1024 * 1024) = DiskCache(context.cacheDir, uniqueName(), byteLimit)

    private fun png(width: Int, height: Int): ByteArray {
        val bitmap = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
        Canvas(bitmap).drawColor(Color.rgb(51, 102, 204))
        val out = ByteArrayOutputStream()
        bitmap.compress(Bitmap.CompressFormat.PNG, 100, out)
        return out.toByteArray()
    }

    // A minimal 2-frame GIF byte stream (enough for the container sniffer; not required to be decodable).
    private fun animatedGifBytes(): ByteArray {
        val out = ArrayList<Byte>()
        "GIF89a".forEach { out.add(it.code.toByte()) }
        out.addAll(listOf(1, 0, 1, 0, 0, 0, 0).map { it.toByte() })
        repeat(2) {
            out.add(0x2C.toByte())
            out.addAll(listOf(0, 0, 0, 0, 1, 0, 1, 0, 0).map { it.toByte() })
            out.add(0x02.toByte()); out.add(0x00.toByte())
        }
        out.add(0x3B.toByte())
        return out.toByteArray()
    }

    private fun samplePlaceholder(n: Int = 6) =
        ImagePlaceholder(n, (0 until n * n).map { ImageColor(it % 256, 100, 150, 255) })

    @Test fun filenameIsCanonicalSha256Hex() {
        val cache = disk()
        try {
            val url = "https://example.test/some/image-42.png"
            val expected = MessageDigest.getInstance("SHA-256")
                .digest(url.toByteArray(Charsets.UTF_8))
                .joinToString("") { "%02x".format(it) }
            assertEquals(expected, cache.fileForUrl(url).name)
            assertEquals(64, expected.length)
        } finally {
            cache.removeAll()
        }
    }

    @Test fun storesAndReadsPlaceholderGrid() {
        val cache = disk()
        try {
            val url = "https://example.test/p.png"
            val grid = samplePlaceholder()
            cache.store(png(4, 4), Size(4, 4), grid, isAnimated = false, url = url)
            assertEquals(grid, cache.placeholder(url))
        } finally {
            cache.removeAll()
        }
    }

    @Test fun placeholderNullWhenNotWritten() {
        val cache = disk()
        try {
            val url = "https://example.test/p2.png"
            cache.store(png(4, 4), Size(4, 4), placeholder = null, isAnimated = false, url = url)
            assertNull(cache.placeholder(url))
        } finally {
            cache.removeAll()
        }
    }

    @Test fun pixelSizeFallsBackToHeaderAndRepairsMetaWhenMissing() {
        val cache = disk()
        try {
            val url = "https://example.test/no-meta.png"
            // Write bytes straight to the cache file, bypassing store() so no meta sidecar exists.
            cache.fileForUrl(url).writeBytes(png(200, 150))
            assertEquals("size must fall back to the header", Size(200, 150), cache.pixelSize(url))
            // ...and the fallback should have repaired the meta, so the next read is the fast path.
            assertTrue("header fallback should write the meta back (repair)",
                java.io.File(cache.directory, cache.fileForUrl(url).name + ".meta").exists())
        } finally {
            cache.removeAll()
        }
    }

    @Test fun animatedFallsBackToSniffAndRepairsMeta() {
        val cache = disk()
        try {
            val gifUrl = "https://example.test/motion.gif"
            val pngUrl = "https://example.test/still.png"
            cache.fileForUrl(gifUrl).writeBytes(animatedGifBytes())
            cache.fileForUrl(pngUrl).writeBytes(png(8, 8))

            assertEquals(true, cache.isAnimated(gifUrl))
            assertEquals(false, cache.isAnimated(pngUrl))
            assertTrue(java.io.File(cache.directory, cache.fileForUrl(gifUrl).name + ".meta").exists())
        } finally {
            cache.removeAll()
        }
    }

    @Test fun isAnimatedNullWhenFileAbsent() {
        val cache = disk()
        try {
            assertNull(cache.isAnimated("https://example.test/never.gif"))
        } finally {
            cache.removeAll()
        }
    }

    @Test fun corruptMetaIsRejectedAndSizeFallsBack() {
        val cache = disk()
        try {
            val url = "https://example.test/bad.png"
            cache.fileForUrl(url).writeBytes(png(80, 60))
            // Overwrite the meta with garbage: it must be rejected, and pixelSize must fall back to the header.
            java.io.File(cache.directory, cache.fileForUrl(url).name + ".meta").writeBytes(byteArrayOf(1, 2, 3, 4, 5))
            assertNull(cache.placeholder(url))
            assertEquals(Size(80, 60), cache.pixelSize(url))
        } finally {
            cache.removeAll()
        }
    }

    @Test fun storePlaceholderIfMissingRepairs() {
        val cache = disk()
        try {
            val url = "https://example.test/legacy.png"
            cache.store(png(16, 16), Size(16, 16), placeholder = null, isAnimated = false, url = url)
            assertNull(cache.placeholder(url))
            cache.storePlaceholderIfMissing(samplePlaceholder(), url)
            assertEquals(samplePlaceholder(), cache.placeholder(url))
        } finally {
            cache.removeAll()
        }
    }

    @Test fun placeholderXattrEquivalentRepairedWhenServedFromDisk() {
        // A file cached WITHOUT a placeholder must get its meta repaired when the bytes are next served from
        // disk: the disk-hit load path computes the grid and writes it back.
        val name = uniqueName()
        val cache = DiskCache(context.cacheDir, name, 10L * 1024 * 1024)
        val url = "https://example.test/legacy2.png"
        cache.store(png(16, 16), Size(16, 16), placeholder = null, isAnimated = false, url = url)
        assertNull(cache.placeholder(url))

        val store = ImageStore(context, name)
        try {
            val latch = java.util.concurrent.CountDownLatch(1)
            store.load(ImageRequest(url)) { latch.countDown() }
            assertTrue(latch.await(5, java.util.concurrent.TimeUnit.SECONDS))
            assertFalse("sanity: served from disk", store.cachedImage(ImageRequest(url)) == null)
            assertTrue("disk-hit load should repair the missing placeholder", cache.placeholder(url) != null)
        } finally {
            store.removeAll()
        }
    }
}
