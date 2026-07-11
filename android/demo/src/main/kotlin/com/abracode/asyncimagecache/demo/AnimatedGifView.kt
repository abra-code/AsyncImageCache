// AnimatedGifView.kt
//
// The Android analog of Demo/App/GIFPlayer.swift, and the whole point of the "playback is a consumer concern"
// design: the library caches + hands back the ORIGINAL transport bytes (store.cachedOriginalBytes) and reports
// that the source is animated (store.isAnimated); the app decodes and plays them. On Android that is one call -
// ImageDecoder.decodeDrawable yields an AnimatedImageDrawable whose start() runs the frames - so there is no
// manual frame-stepping timer (the platform owns it). CachedImage still shows the flattened FIRST frame; this
// player is layered on only when the user taps Play.

package com.abracode.asyncimagecache.demo

import android.graphics.ImageDecoder
import android.graphics.drawable.AnimatedImageDrawable
import android.graphics.drawable.Drawable
import android.widget.ImageView
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.viewinterop.AndroidView
import com.abracode.asyncimagecache.ImageRequest
import com.abracode.asyncimagecache.ImageStore
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.nio.ByteBuffer

@Composable
fun AnimatedGifView(
    url: String,
    store: ImageStore,
    intrinsicSize: Size?,
    modifier: Modifier = Modifier,
) {
    val aspect = intrinsicSize?.let { if (it.height > 0f) it.width / it.height else 1f } ?: 1f
    var drawable by remember(url) { mutableStateOf<Drawable?>(null) }

    LaunchedEffect(url) {
        // Ask the cache for the source bytes; load through the store if they are not resident (e.g. evicted).
        var bytes = store.cachedOriginalBytes(url)?.data
        if (bytes == null) {
            store.loadAsync(ImageRequest(url))
            bytes = store.cachedOriginalBytes(url)?.data
        }
        val decoded = bytes?.let {
            withContext(Dispatchers.Default) {
                runCatching { ImageDecoder.decodeDrawable(ImageDecoder.createSource(ByteBuffer.wrap(it))) }.getOrNull()
            }
        }
        drawable = decoded
    }

    AndroidView(
        modifier = modifier.aspectRatio(aspect),
        factory = { context ->
            ImageView(context).apply { adjustViewBounds = true }
        },
        update = { imageView ->
            imageView.setImageDrawable(drawable)
            (drawable as? AnimatedImageDrawable)?.takeIf { !it.isRunning }?.start()
        },
    )
}
