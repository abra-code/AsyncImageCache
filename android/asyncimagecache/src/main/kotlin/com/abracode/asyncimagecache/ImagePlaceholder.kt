// ImagePlaceholder.kt
//
// A tiny N x N grid of average colors - a cheap, dependency-free "blurhash-ish" preview shown while an image
// loads. It is computed once off-main (Stage C), persisted in the sidecar metadata, and rendered by upscaling
// the NxN grid with bilinear interpolation (a soft gradient). Row 0 is the TOP of the image. A 1:1 port of the
// Swift `ImagePlaceholder` struct + `ImagePlaceholderConfig`. Pure logic - JVM-testable.

package com.abracode.asyncimagecache

/**
 * Internal, tweakable configuration for the placeholder grid. NOT part of the public API - callers get a
 * finished placeholder, not the knobs.
 */
internal object ImagePlaceholderConfig {
    /**
     * The N of the N x N grid. 6 is a soft, clearly-a-placeholder preview; the cost is flat across sizes, so
     * this is a purely aesthetic/storage tradeoff (N*N*4 bytes on disk).
     */
    const val GRID_DIMENSION = 6

    /**
     * Upper bound on a grid dimension accepted when READING stored metadata. A security clamp: a corrupt or
     * foreign meta payload cannot describe an oversized grid, and the payload length must be N*N*4.
     */
    const val MAX_GRID_DIMENSION = 16

    /** The largest placeholder payload we will read: maxN*maxN RGBA cells (dimension is derived from length). */
    const val MAX_PAYLOAD_BYTES = MAX_GRID_DIMENSION * MAX_GRID_DIMENSION * 4
}

/**
 * An N x N grid of average colors (row-major, row 0 = top of the image).
 *
 * `equals`/`hashCode` come from `data class`, matching the Swift `Equatable` conformance (a placeholder equals
 * another iff dimension and every cell match).
 */
data class ImagePlaceholder(
    val dimension: Int,
    val cells: List<ImageColor>,
) {
    /** The average of all cells - a single dominant tint for consumers that just want one color. */
    val dominantColor: ImageColor
        get() {
            if (cells.isEmpty()) {
                return ImageColor(red = 0, green = 0, blue = 0, alpha = 0)
            }
            var r = 0
            var g = 0
            var b = 0
            var a = 0
            for (c in cells) {
                r += c.red; g += c.green; b += c.blue; a += c.alpha
            }
            val n = cells.size
            return ImageColor(red = r / n, green = g / n, blue = b / n, alpha = a / n)
        }
}
