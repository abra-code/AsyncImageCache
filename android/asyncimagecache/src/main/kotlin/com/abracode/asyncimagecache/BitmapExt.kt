// BitmapExt.kt
//
// Small glue around android.graphics.Bitmap, the platform's ready-to-draw image type. `Bitmap` replaces the
// Swift `PlatformImage` (UIImage/NSImage) alias, so there is no separate PlatformImage.kt; the pieces the Swift
// code needed from that file live here.

package com.abracode.asyncimagecache

import android.graphics.Bitmap

/**
 * The resident RAM footprint of a decoded bitmap in bytes - used as the LruCache cost so the variant tier is
 * bounded by wired memory rather than a bare object count (a single 12 MP photo decodes to ~48 MB regardless of
 * how well its source compressed). `allocationByteCount` is the exact backing allocation; the Swift analog is
 * `bytesPerRow * height`.
 */
internal val Bitmap.memoryCost: Int
    get() = maxOf(1, allocationByteCount)
