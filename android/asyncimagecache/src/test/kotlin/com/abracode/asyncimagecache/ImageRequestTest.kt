// ImageRequestTest.kt - JVM unit tests for the variant-key quantization, ported from the Swift
// `testVariantKeyQuantizesToWholePixels`. The key format must stay byte-identical to Swift's so cache files and
// cross-platform fixtures align.

package com.abracode.asyncimagecache

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class ImageRequestTest {

    @Test
    fun variantKeyQuantizesToWholePixels() {
        val url = "https://example.test/i.png"
        val a = ImageRequest(url = url, targetWidth = 342.4f, cornerRadius = 9.6f)
        val b = ImageRequest(url = url, targetWidth = 342.2f, cornerRadius = 10.1f)

        assertEquals("sub-pixel widths/radii should collapse to one variant", a.variantKey, b.variantKey)
        assertTrue(a.variantKey, a.variantKey.contains("|w=342|"))
        assertTrue(a.variantKey, a.variantKey.endsWith("|r=10"))
        assertEquals("$url|w=nil|r=0", ImageRequest(url = url).variantKey)
    }

    @Test
    fun quantizedTargetWidthClampsToAtLeastOne() {
        // A sub-1px target rounds toward 0 but must never mint a 0-wide variant (mirrors Swift `max(1, ...)`).
        assertEquals(1, ImageRequest(url = "u", targetWidth = 0.4f).quantizedTargetWidth)
        assertEquals(1, ImageRequest(url = "u", targetWidth = 0.6f).quantizedTargetWidth)
        assertEquals(null, ImageRequest(url = "u").quantizedTargetWidth)
    }

    @Test
    fun quantizedCornerRadiusClampsToZero() {
        assertEquals(0, ImageRequest(url = "u", cornerRadius = 0f).quantizedCornerRadius)
        assertEquals(3, ImageRequest(url = "u", cornerRadius = 2.5f).quantizedCornerRadius)
    }

    @Test
    fun equalRequestsShareKeyDifferentWidthsDoNot() {
        val url = "https://example.test/i.png"
        assertEquals(
            ImageRequest(url, 100f, 0f).variantKey,
            ImageRequest(url, 100f, 0f).variantKey,
        )
        assertTrue(ImageRequest(url, 100f).variantKey != ImageRequest(url, 200f).variantKey)
    }
}
