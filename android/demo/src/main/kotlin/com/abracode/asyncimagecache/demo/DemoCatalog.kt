// DemoCatalog.kt
//
// The demo's image catalog. Mirrors the SwiftUI Demo/App/DemoModel.swift: remote images from picsum.photos at
// KNOWN intrinsic sizes so CachedImage can reserve the exact box up front (zero reflow on hydration), plus a
// couple of animated sources to exercise the consumer-driven playback path. The Swift demo also ships local
// build-time-generated JPEGs; on Android those belong to the Stage F fixtures, so the catalog here is remote.

package com.abracode.asyncimagecache.demo

import androidx.compose.ui.geometry.Size

data class DemoImage(
    val id: String,
    val title: String,
    val url: String,
    val intrinsicSize: Size?,
    val isRemote: Boolean,
)

object DemoCatalog {

    fun remoteImages(): List<DemoImage> {
        val specs = listOf(
            Triple("aic-meadow", 1200, 800),
            Triple("aic-canyon", 1000, 1500),
            Triple("aic-harbor", 1600, 900),
            Triple("aic-street", 900, 900),
            Triple("aic-peaks", 1400, 1050),
            Triple("aic-market", 800, 1200),
        )
        return specs.map { (seed, w, h) ->
            DemoImage(
                id = "remote-$seed",
                title = "$seed ${w}x$h",
                url = "https://picsum.photos/seed/$seed/$w/$h",
                intrinsicSize = Size(w.toFloat(), h.toFloat()),
                isRemote = true,
            )
        }
    }

    // Animated sources for the GIF playback sample. CachedImage shows the flattened first frame; the GIF player
    // (AnimatedGifView) drives the frames on demand. Remote, so they require network - swap for a bundled asset
    // if you need an offline demo.
    fun animatedImages(): List<DemoImage> = listOf(
        DemoImage(
            id = "gif-earth",
            title = "Rotating earth (animated GIF)",
            url = "https://upload.wikimedia.org/wikipedia/commons/2/2c/Rotating_earth_%28large%29.gif",
            intrinsicSize = Size(400f, 400f),
            isRemote = true,
        ),
    )
}
