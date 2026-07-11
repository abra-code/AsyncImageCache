// ImageProcessing.kt
//
// Pure graphics helpers - all intended to run OFF the main thread. Ports Sources/AsyncImageCache/
// ImageProcessing.swift. Where CoreGraphics drew a CGImage into a fresh CGContext, this draws a Bitmap through
// a Canvas; where UIImage deferred decode to first draw, ImageDecoder decodes eagerly (software allocator),
// which is what forces the decode off-main - the library's core promise.
//
// Platform mappings vs the Swift reference (see porting plan section 8):
//   - Decode via ImageDecoder with ALLOCATOR_SOFTWARE (we post-process the pixels). ImageDecoder applies EXIF
//     orientation automatically, so the manual `orientedUp` re-draw the Swift UIKit path needs is unnecessary -
//     the decoded bitmap is already upright, and its width/height are the displayed (rotation-corrected) size.
//   - Animated detection is container sniffing (AnimatedImageDetector), not a decoder frame count.
//   - Corner rounding uses a circular rounded rect (Android has no continuous-corner primitive).

package com.abracode.asyncimagecache

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.BitmapShader
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.ColorSpace
import android.graphics.ImageDecoder
import android.graphics.Paint
import android.graphics.RectF
import android.graphics.Shader
import android.media.ExifInterface
import android.util.Size
import java.io.ByteArrayInputStream
import java.nio.ByteBuffer
import kotlin.math.min
import kotlin.math.roundToInt

internal object ImageProcessing {

    /**
     * Whether the transport bytes hold more than one frame (an animated GIF/APNG/WebP). Used to record the flag
     * alongside the image so a consumer can decide whether to drive its own animated renderer (the cached
     * variant is always a single flattened frame - animation is a consumer concern). See AnimatedImageDetector.
     */
    fun isAnimated(data: ByteArray): Boolean = AnimatedImageDetector.isAnimated(data)

    /**
     * Decode the transport bytes to an upright software bitmap, or null if undecodable. ImageDecoder applies
     * EXIF orientation and returns the FIRST frame of an animated source (matching Swift, whose variant is a
     * single flattened frame). ALLOCATOR_SOFTWARE because the pixels are post-processed (scaled / masked / read
     * back for the placeholder), which a HARDWARE bitmap forbids.
     */
    fun decode(data: ByteArray): Bitmap? {
        return try {
            val source = ImageDecoder.createSource(ByteBuffer.wrap(data))
            ImageDecoder.decodeBitmap(source) { decoder, _, _ ->
                decoder.allocator = ImageDecoder.ALLOCATOR_SOFTWARE
                decoder.isMutableRequired = false
            }
        } catch (t: Throwable) {
            // ImageDecoder throws on malformed / unsupported bytes; treat as a decode miss.
            null
        }
    }

    /** Natural size in PIXELS of a decoded bitmap. The bitmap is already EXIF-corrected, so this is as displayed. */
    fun pixelSize(bitmap: Bitmap): Size = Size(bitmap.width, bitmap.height)

    /**
     * The natural pixel size read from the image HEADER only (no pixel decode) - the DiskCache fallback for when
     * the sidecar metadata is missing. Mirrors the Swift `headerPixelSize`: BitmapFactory.inJustDecodeBounds
     * reads width/height without decoding, and EXIF orientations 5-8 (90/270-degree rotations, transpose,
     * transverse) render with the axes swapped, so swap here too - the size must describe the image AS
     * DISPLAYED, matching what the decode path records. Uses android.media.ExifInterface (OS SDK; no extra dep).
     */
    fun headerPixelSize(data: ByteArray): Size? {
        val options = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeByteArray(data, 0, data.size, options)
        val w = options.outWidth
        val h = options.outHeight
        if (w <= 0 || h <= 0) {
            return null
        }
        val orientation = try {
            ExifInterface(ByteArrayInputStream(data))
                .getAttributeInt(ExifInterface.TAG_ORIENTATION, ExifInterface.ORIENTATION_NORMAL)
        } catch (t: Throwable) {
            ExifInterface.ORIENTATION_NORMAL
        }
        val swap = orientation == ExifInterface.ORIENTATION_ROTATE_90 ||
            orientation == ExifInterface.ORIENTATION_ROTATE_270 ||
            orientation == ExifInterface.ORIENTATION_TRANSPOSE ||
            orientation == ExifInterface.ORIENTATION_TRANSVERSE
        return if (swap) Size(h, w) else Size(w, h)
    }

    /**
     * The image's placeholder grid: an N x N (N = GRID_DIMENSION) set of average colors. Downsamples the bitmap
     * to N x N with bilinear filtering (area-averaging, the same intent as Swift's draw-into-NxN-context) and
     * reads the cells back, row 0 = TOP. `getPixel` returns straight (un-premultiplied) sRGB ARGB, so the cells
     * carry the true tint with alpha preserved - no manual un-premultiply needed (Android does it in getPixel).
     * null only if the source has no pixels.
     */
    fun placeholder(bitmap: Bitmap): ImagePlaceholder? {
        if (bitmap.width <= 0 || bitmap.height <= 0) {
            return null
        }
        val n = ImagePlaceholderConfig.GRID_DIMENSION
        val scaled = try {
            Bitmap.createScaledBitmap(bitmap, n, n, true)
        } catch (t: Throwable) {
            return null
        }
        val cells = ArrayList<ImageColor>(n * n)
        for (y in 0 until n) {
            for (x in 0 until n) {
                val px = scaled.getPixel(x, y)
                cells.add(ImageColor(Color.red(px), Color.green(px), Color.blue(px), Color.alpha(px)))
            }
        }
        if (scaled !== bitmap) {
            scaled.recycle()
        }
        return ImagePlaceholder(dimension = n, cells = cells)
    }

    /**
     * An N x N bitmap built from a placeholder grid, for upscaling with bilinear interpolation into a soft
     * gradient at display time. The cells hold straight (un-premultiplied) ARGB, which is exactly what
     * `setPixels` expects, so the semi-transparent case composites correctly. null if the grid is malformed.
     */
    fun gridBitmap(placeholder: ImagePlaceholder): Bitmap? {
        val n = placeholder.dimension
        if (n <= 0 || placeholder.cells.size != n * n) {
            return null
        }
        val pixels = IntArray(n * n) { placeholder.cells[it].argb }
        val bitmap = Bitmap.createBitmap(n, n, Bitmap.Config.ARGB_8888)
        bitmap.setPixels(pixels, 0, n, 0, 0, n, n)
        return bitmap
    }

    /** The resident RAM footprint of a decoded bitmap, in bytes (the LruCache cost). */
    fun memoryCost(bitmap: Bitmap): Int = bitmap.memoryCost

    /**
     * Produce the ready-to-draw variant: downscale so width <= `targetWidth` (pixels) when the image is wider,
     * and apply a rounded-corner mask when `cornerRadius > 0`. Mirrors the Swift geometry exactly (cap width,
     * height scales proportionally, never upscale; radius clamped to half the shorter side). The wide-gamut
     * color space is preserved across the redraw (Display P3 survives), matching the Swift intent.
     *
     * Divergence from Swift: Swift ALWAYS redraws even with no transform, to force the deferred decode off-main.
     * Here the decode already happened eagerly in `decode()`, so with no transform the already-decoded software
     * bitmap is returned as-is - there is no deferred decode to force. Returns the source unchanged only when it
     * has no usable dimensions.
     */
    fun variant(source: Bitmap, targetWidth: Float?, cornerRadius: Float): Bitmap {
        val naturalWidth = source.width
        val naturalHeight = source.height
        if (naturalWidth <= 0 || naturalHeight <= 0) {
            return source
        }

        var width = naturalWidth
        var height = naturalHeight
        if (targetWidth != null && targetWidth > 0f && naturalWidth > targetWidth) {
            val scale = targetWidth / naturalWidth
            width = (naturalWidth * scale).roundToInt()
            height = (naturalHeight * scale).roundToInt()
        }
        if (width <= 0 || height <= 0) {
            return source
        }

        // Wrap the allocations: an OutOfMemoryError from createScaledBitmap/createBitmap on a large source must
        // not escape (the Swift reference returns the original image on any failure and never throws - letting it
        // propagate would crash the work thread and leave the caller's in-flight entry dangling). On failure,
        // fall back to the source so a degraded-but-present image is still delivered.
        return try {
            val scaled = if (width == naturalWidth && height == naturalHeight) {
                source
            } else {
                Bitmap.createScaledBitmap(source, width, height, true)
            }

            if (cornerRadius <= 0f) {
                return scaled
            }

            val radius = min(cornerRadius, min(width, height) / 2f)
            val colorSpace = scaled.colorSpace ?: ColorSpace.get(ColorSpace.Named.SRGB)
            // ARGB_8888 with alpha so the masked-off corners are transparent; keep the source's (possibly wide)
            // color space so P3 is not clamped to sRGB.
            val output = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888, true, colorSpace)
            val canvas = Canvas(output)
            val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
                isFilterBitmap = true
                shader = BitmapShader(scaled, Shader.TileMode.CLAMP, Shader.TileMode.CLAMP)
            }
            canvas.drawRoundRect(RectF(0f, 0f, width.toFloat(), height.toFloat()), radius, radius, paint)

            if (scaled !== source) {
                scaled.recycle()
            }
            output
        } catch (t: Throwable) {
            source
        }
    }
}
