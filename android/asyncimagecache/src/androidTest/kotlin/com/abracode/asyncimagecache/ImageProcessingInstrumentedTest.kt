// ImageProcessingInstrumentedTest.kt - instrumented (emulator) tests for the graphics pipeline. Everything here
// touches android.graphics (Bitmap/ImageDecoder/Canvas), so it cannot run on the JVM. Ports the CoreGraphics
// tests from AsyncImageCacheTests.swift: decode/size, downscale rules, rounded-corner alpha, placeholder grid
// orientation + dominant color, grid-image compositing, and memory cost. Animated-flag parity for real encoded
// images lives in the Stage F fixture suite; the byte-level sniffing is covered on the JVM.

package com.abracode.asyncimagecache

import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import androidx.test.ext.junit.runners.AndroidJUnit4
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import java.io.ByteArrayOutputStream
import kotlin.math.abs

@RunWith(AndroidJUnit4::class)
class ImageProcessingInstrumentedTest {

    // A solid-color bitmap at an exact pixel size.
    private fun solid(width: Int, height: Int, color: Int): Bitmap {
        val bitmap = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
        Canvas(bitmap).drawColor(color)
        return bitmap
    }

    // Top half `top`, bottom half `bottom`, built from a raw top-down pixel buffer so orientation is unambiguous.
    private fun topBottom(top: Int, bottom: Int, size: Int = 24): Bitmap {
        val pixels = IntArray(size * size) { i -> if (i / size < size / 2) top else bottom }
        return Bitmap.createBitmap(pixels, size, size, Bitmap.Config.ARGB_8888)
    }

    private fun png(bitmap: Bitmap): ByteArray {
        val out = ByteArrayOutputStream()
        bitmap.compress(Bitmap.CompressFormat.PNG, 100, out)
        return out.toByteArray()
    }

    // --- Decode + size ---

    @Test fun decodePreservesSize() {
        val decoded = ImageProcessing.decode(png(solid(24, 18, Color.rgb(51, 102, 204))))
        assertNotNull(decoded)
        assertEquals(24, decoded!!.width)
        assertEquals(18, decoded.height)
        assertEquals(android.util.Size(24, 18), ImageProcessing.pixelSize(decoded))
    }

    @Test fun headerPixelSizeReadsWithoutFullDecode() {
        assertEquals(android.util.Size(123, 45), ImageProcessing.headerPixelSize(png(solid(123, 45, Color.GRAY))))
    }

    @Test fun undecodableBytesReturnNull() {
        org.junit.Assert.assertNull(ImageProcessing.decode(byteArrayOf(1, 2, 3, 4, 5)))
    }

    // --- Downscale rules (cap width, height scales, never upscale) ---

    @Test fun downscaleToTargetWidth() {
        val out = ImageProcessing.variant(solid(100, 80, Color.BLUE), targetWidth = 40f, cornerRadius = 0f)
        assertEquals(40, out.width)
        assertEquals(32, out.height)   // 80 * (40/100)
    }

    @Test fun neverUpscalesBeyondNatural() {
        val out = ImageProcessing.variant(solid(20, 20, Color.BLUE), targetWidth = 100f, cornerRadius = 0f)
        assertEquals(20, out.width)
        assertEquals(20, out.height)
    }

    @Test fun noTransformReturnsSourceUnchanged() {
        // Divergence from Swift (which always redraws to force decode): the bitmap is already decoded, so with no
        // transform the same object is returned.
        val source = solid(20, 20, Color.BLUE)
        assertTrue(ImageProcessing.variant(source, targetWidth = null, cornerRadius = 0f) === source)
    }

    // --- Rounded corners ---

    @Test fun cornerRadiusMasksCorners() {
        val out = ImageProcessing.variant(solid(40, 40, Color.rgb(20, 40, 200)), targetWidth = null, cornerRadius = 12f)
        assertEquals(0, Color.alpha(out.getPixel(0, 0)))                 // corner masked away
        assertEquals(255, Color.alpha(out.getPixel(20, 20)))            // center opaque
    }

    // --- Placeholder grid ---

    @Test fun placeholderGridOfSolidImage() {
        val p = ImageProcessing.placeholder(solid(48, 48, Color.rgb(51, 102, 204)))!!
        assertEquals(6, p.dimension)
        assertEquals(36, p.cells.size)
        val c = p.dominantColor
        assertTrue("red ${c.red}", abs(c.red - 51) <= 8)
        assertTrue("green ${c.green}", abs(c.green - 102) <= 8)
        assertTrue("blue ${c.blue}", abs(c.blue - 204) <= 8)
        assertEquals(255, c.alpha)
    }

    @Test fun placeholderGridIsTopDown() {
        val p = ImageProcessing.placeholder(topBottom(Color.rgb(220, 20, 20), Color.rgb(20, 20, 220)))!!
        val n = p.dimension
        assertTrue("top-left should be red-dominant", p.cells[0].red > p.cells[0].blue)
        assertTrue("bottom-left should be blue-dominant", p.cells[(n - 1) * n].blue > p.cells[(n - 1) * n].red)
    }

    // gridBitmap's cells are straight (un-premultiplied) ARGB. White at 50% alpha over black must composite to
    // ~50% gray - a mislabeled premultiplied path would read too bright.
    @Test fun gridImageCompositesSemiTransparentCells() {
        val n = ImagePlaceholderConfig.GRID_DIMENSION
        val grid = ImagePlaceholder(n, List(n * n) { ImageColor(255, 255, 255, 128) })
        val image = ImageProcessing.gridBitmap(grid)!!

        val out = Bitmap.createBitmap(1, 1, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(out)
        canvas.drawColor(Color.BLACK)
        canvas.drawBitmap(image, android.graphics.Rect(0, 0, n, n), android.graphics.RectF(0f, 0f, 1f, 1f), Paint(Paint.FILTER_BITMAP_FLAG))
        val red = Color.red(out.getPixel(0, 0))
        assertTrue("white at 50% alpha over black should read ~128, got $red", abs(red - 128) <= 8)
    }

    // --- Memory cost + animated ---

    @Test fun memoryCostReflectsDecodedBitmapSize() {
        val bitmap = solid(100, 100, Color.RED)
        assertTrue(ImageProcessing.memoryCost(bitmap) >= 100 * 100 * 4)
    }

    @Test fun staticImageIsNotAnimated() {
        assertTrue(!ImageProcessing.isAnimated(png(solid(8, 8, Color.RED))))
    }
}
