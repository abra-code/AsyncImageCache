// ImageRequest.kt
//
// A ready-to-draw image variant is identified by the full request: the source URL plus the presentation
// transforms (width cap + corner radius). Two requests for the same URL but different `targetWidth` are
// distinct variants that share one on-disk original. A 1:1 port of the Swift `ImageRequest` struct, keeping the
// variant-key format byte-identical so cross-platform fixtures and behavior align.
//
// Divergence from Swift: the URL is a plain `String` (Swift keys on `URL.absoluteString`); parsing to a
// `android.net.Uri` happens at fetch time only. This keeps the key identical to Swift's for the same URL text.

package com.abracode.asyncimagecache

import kotlin.math.roundToInt

data class ImageRequest(
    val url: String,
    /**
     * Cap width in PIXELS; the height scales proportionally. `null` keeps the natural size. Taken as `Float`
     * for caller convenience (layout math is float), but QUANTIZED to whole pixels for caching - see below.
     */
    val targetWidth: Float? = null,
    /** Corner radius in PIXELS; `0` = no rounding. Also quantized to whole pixels for the variant key. */
    val cornerRadius: Float = 0f,
) {
    // The transforms QUANTIZED to whole pixels. Fractional widths from layout (e.g. 342.6667) would otherwise
    // mint a distinct cache variant per sub-pixel value - wasted decodes + memory, and a bloated key. The store
    // scales to these same values, so the cached bitmap matches its key exactly. `roundToInt()` rounds half up,
    // matching Swift's `.rounded()` for the non-negative widths/radii used here.
    internal val quantizedTargetWidth: Int?
        get() = targetWidth?.let { maxOf(1, it.roundToInt()) }

    internal val quantizedCornerRadius: Int
        get() = maxOf(0, cornerRadius.roundToInt())

    /** A stable string key for the exact ready-to-draw variant (used as the in-memory cache key). */
    internal val variantKey: String
        get() {
            val width = quantizedTargetWidth?.toString() ?: "nil"
            return "$url|w=$width|r=$quantizedCornerRadius"
        }
}
