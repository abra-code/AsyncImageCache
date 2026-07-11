// ImageMetaCodecTest.kt - JVM round-trip + robustness tests for the sidecar-metadata codec. Covers the same
// concerns the Swift xattr paths test (round-trip of size/placeholder/animated, rejection of malformed
// placeholder payloads, and the tri-state "absent" semantics that drive DiskCache's header fallback).

package com.abracode.asyncimagecache

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class ImageMetaCodecTest {

    private fun grid(dimension: Int = 6): ImagePlaceholder =
        ImagePlaceholder(dimension, (0 until dimension * dimension).map {
            ImageColor(red = it % 256, green = 100, blue = 150, alpha = 255)
        })

    @Test
    fun fullRecordRoundTrips() {
        val meta = ImageMeta(PixelSize(123, 45), animated = true, placeholder = grid())
        val decoded = ImageMetaCodec.decode(ImageMetaCodec.encode(meta))
        assertEquals(meta, decoded)
    }

    @Test
    fun sizeOnlyRecordRoundTrips() {
        val meta = ImageMeta(PixelSize(1024, 768), animated = null, placeholder = null)
        assertEquals(meta, ImageMetaCodec.decode(ImageMetaCodec.encode(meta)))
    }

    @Test
    fun animatedFalseIsDistinctFromUnknown() {
        val known = ImageMetaCodec.decode(ImageMetaCodec.encode(ImageMeta(null, animated = false, null)))
        assertEquals(false, known?.animated)
        val unknown = ImageMetaCodec.decode(ImageMetaCodec.encode(ImageMeta(null, animated = null, null)))
        assertNull("absent animated flag must decode as unknown, not false", unknown?.animated)
    }

    @Test
    fun placeholderRoundTripsAndDominantColorSurvives() {
        val g = grid()
        val decoded = ImageMetaCodec.decode(ImageMetaCodec.encode(ImageMeta(null, null, g)))
        assertEquals(g, decoded?.placeholder)
        assertEquals(g.dominantColor, decoded?.placeholder?.dominantColor)
    }

    @Test
    fun zeroSizeIsNotEncoded() {
        // Mirrors Swift `writePixelSize` guarding width/height > 0: a zero size is omitted, so it decodes absent.
        val decoded = ImageMetaCodec.decode(ImageMetaCodec.encode(ImageMeta(PixelSize(0, 0), null, null)))
        assertNull(decoded?.pixelSize)
    }

    @Test
    fun malformedPlaceholderGridIsNotEncoded() {
        // cells.size != dimension*dimension -> dropped on encode (mirrors the Swift write guard).
        val bad = ImagePlaceholder(dimension = 6, cells = listOf(ImageColor(1, 2, 3, 4)))
        val decoded = ImageMetaCodec.decode(ImageMetaCodec.encode(ImageMeta(null, null, bad)))
        assertNull(decoded?.placeholder)
    }

    @Test
    fun oversizedPlaceholderDimensionIsNotEncoded() {
        val n = ImagePlaceholderConfig.MAX_GRID_DIMENSION + 1
        val big = ImagePlaceholder(dimension = n, cells = (0 until n * n).map { ImageColor(0, 0, 0, 0) })
        val decoded = ImageMetaCodec.decode(ImageMetaCodec.encode(ImageMeta(PixelSize(9, 9), null, big)))
        assertNull(decoded?.placeholder)
        assertEquals(PixelSize(9, 9), decoded?.pixelSize)   // other fields still round-trip
    }

    @Test
    fun garbageBytesRejected() {
        assertNull(ImageMetaCodec.decode(byteArrayOf()))
        assertNull(ImageMetaCodec.decode(byteArrayOf(1, 2, 3, 4, 5, 6, 7, 8)))
        // Right length, wrong magic.
        assertNull(ImageMetaCodec.decode(byteArrayOf(0x00, 0x01, 0x00)))
    }

    @Test
    fun truncatedPlaceholderDroppedButSizeKept() {
        // Encode a full record, then chop off the tail of the placeholder payload: size/animated must survive,
        // placeholder must be dropped rather than misread.
        val full = ImageMetaCodec.encode(ImageMeta(PixelSize(20, 30), animated = true, placeholder = grid()))
        val truncated = full.copyOf(full.size - 10)
        val decoded = ImageMetaCodec.decode(truncated)
        assertEquals(PixelSize(20, 30), decoded?.pixelSize)
        assertEquals(true, decoded?.animated)
        assertNull(decoded?.placeholder)
    }

    @Test
    fun emptyMetaEncodesToBareHeader() {
        val bytes = ImageMetaCodec.encode(ImageMeta(null, null, null))
        assertArrayEquals(byteArrayOf(0xAC.toByte(), 0x01, 0x00), bytes)
        assertEquals(ImageMeta(null, null, null), ImageMetaCodec.decode(bytes))
    }
}
