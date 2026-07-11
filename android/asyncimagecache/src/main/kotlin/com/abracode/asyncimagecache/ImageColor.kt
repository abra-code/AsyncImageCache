// ImageColor.kt
//
// A plain sRGB RGBA color (8 bits/channel), used for the persisted dominant-color placeholder. Deliberately
// UI-framework-free (no Compose Color type) so it can be computed off-main, packed into 4 bytes of the sidecar
// metadata, and handed to any renderer; CachedImage turns it into a Compose Color via `argb`. A 1:1 port of the
// Swift `ImageColor` struct.
//
// Stored as a single packed Int (R,G,B,A from high byte to low) so the type is a zero-allocation value class.
// Channel accessors return 0-255. Pure logic - JVM-testable, no android.* import.

package com.abracode.asyncimagecache

@JvmInline
value class ImageColor(val rgba: Int) {

    /** Component initializer mirroring the Swift `init(red:green:blue:alpha:)`. Channels are masked to 8 bits. */
    constructor(red: Int, green: Int, blue: Int, alpha: Int) : this(
        ((red and 0xFF) shl 24) or ((green and 0xFF) shl 16) or ((blue and 0xFF) shl 8) or (alpha and 0xFF)
    )

    val red: Int get() = (rgba ushr 24) and 0xFF
    val green: Int get() = (rgba ushr 16) and 0xFF
    val blue: Int get() = (rgba ushr 8) and 0xFF
    val alpha: Int get() = rgba and 0xFF

    /**
     * The color packed as an Android ARGB_8888 Int - the layout consumed by `android.graphics.Color` and by
     * Compose's `Color(argb: Int)` constructor. Kept separate from the internal `rgba` storage so the on-disk /
     * grid byte order (R,G,B,A) stays independent of the platform's ARGB draw order.
     */
    val argb: Int
        get() = (alpha shl 24) or (red shl 16) or (green shl 8) or blue
}
