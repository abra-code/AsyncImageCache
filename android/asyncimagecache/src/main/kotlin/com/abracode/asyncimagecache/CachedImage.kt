// CachedImage.kt
//
// The Compose entry point, a 1:1 port of the SwiftUI `CachedImage` view. It reserves the layout box at the
// correct aspect BEFORE the pixels arrive (zero reflow on hydration), shows the cached blurry placeholder grid
// while loading, then swaps in the ready-to-draw variant - no spinner, no transition, exactly like the Swift
// view.
//
// Faithful to the Swift reference (Sources/AsyncImageCache/CachedImage.swift), NOT the resolved-width sketch in
// porting-plan section 3:
//   - the decode target width is `maxPixelWidth` (the explicit cap), so an uncapped image decodes at its
//     natural resolution, exactly as Swift builds `ImageRequest(url:, targetWidth: maxPixelWidth, cornerRadius: 0)`;
//   - the composable's own `cornerRadius` is a GPU clip (Modifier.clip), not baked into the variant - matching
//     Swift's `.clipShape(RoundedRectangle(...))`. Baking is still available for consumers (the ActionUI element)
//     through `ImageRequest.cornerRadius`.
//
// Aspect-box reservation chain (identical to Swift): explicit `intrinsicSize` -> the size resolved after load ->
// the store's cachedPixelSize -> a neutral 4:3. `resolvedSize`/`loadedUrl` state make the box reflow to the
// image's true aspect once loaded, so an image without a server-provided size still ends up correctly shaped.
//
// Recomposition safety: the load is keyed (LaunchedEffect) on url, so recompositions do not re-request, and a
// changed url cancels the previous LaunchedEffect - its suspended loadAsync resumes into a dead continuation, so
// a stale result can never overwrite the new one (the stale-completion guard Swift gets from task identity). The
// rendered image is additionally gated on `loadedUrl == url` so a reused view never shows the old bitmap.

package com.abracode.asyncimagecache

import android.graphics.Bitmap
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.FilterQuality
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp

/** How the image fills its reserved box - the Swift `contentMode`. */
enum class ContentMode { Fit, Fill }

private val NEUTRAL_PLACEHOLDER = Color.Gray.copy(alpha = 0.12f)
private const val DEFAULT_ASPECT = 4f / 3f

@Composable
fun CachedImage(
    url: String?,
    modifier: Modifier = Modifier,
    intrinsicSize: Size? = null,
    cornerRadius: Dp = 0.dp,
    contentMode: ContentMode = ContentMode.Fill,
    maxPixelWidth: Float? = null,
    store: ImageStore = ImageStore.shared(LocalContext.current),
    contentDescription: String? = null,
) {
    var image by remember { mutableStateOf<Bitmap?>(null) }
    // The url `image`/`resolvedSize` belong to. When the view is reused with a NEW url, the old bitmap must not
    // keep displaying (or sizing the box) while the new one loads - render + aspect gate on loadedUrl == url.
    var loadedUrl by remember { mutableStateOf<String?>(null) }
    var resolvedSize by remember { mutableStateOf<Size?>(null) }

    // Recomputed on every recomposition (it reads the resolvedSize/loadedUrl state), so the box reflows once the
    // image loads. Precedence identical to Swift: caller hint -> resolved-after-load -> cache's known size -> 4:3.
    val aspectRatio = run {
        val size = intrinsicSize
            ?: (if (loadedUrl == url) resolvedSize else null)
            ?: url?.let { store.cachedPixelSize(it)?.toComposeSize() }
        if (size != null && size.width > 0f && size.height > 0f) size.width / size.height else DEFAULT_ASPECT
    }

    LaunchedEffect(url) {
        if (url == null) {
            image = null; loadedUrl = null; resolvedSize = null
            return@LaunchedEffect
        }
        val request = ImageRequest(url, targetWidth = maxPixelWidth, cornerRadius = 0f)
        store.cachedImage(request)?.let {
            image = it; loadedUrl = url; resolvedSize = store.cachedPixelSize(url)?.toComposeSize()
            return@LaunchedEffect
        }
        // If url changes, this coroutine is cancelled at the suspension point, so the assignments below never run
        // with a stale result.
        val loaded = store.loadAsync(request)
        image = loaded
        loadedUrl = url
        resolvedSize = store.cachedPixelSize(url)?.toComposeSize()
    }

    val contentScale = if (contentMode == ContentMode.Fill) ContentScale.Crop else ContentScale.Fit
    Box(
        modifier = modifier
            .aspectRatio(aspectRatio)
            .clip(RoundedCornerShape(cornerRadius)),
    ) {
        val current = image
        if (current != null && loadedUrl == url) {
            Image(
                bitmap = current.asImageBitmap(),
                contentDescription = contentDescription,
                modifier = Modifier.fillMaxSize(),
                contentScale = contentScale,
            )
        } else {
            // Placeholder grid (soft gradient) while loading, or a neutral fill if none is known yet. Drawn with
            // low filter quality so the 6x6 grid upscales into a smooth blur (the Swift interpolated upscale).
            val preview = url?.let { store.placeholderImage(it) }
            if (preview != null) {
                Image(
                    bitmap = preview.asImageBitmap(),
                    contentDescription = contentDescription,
                    modifier = Modifier.fillMaxSize(),
                    contentScale = contentScale,
                    filterQuality = FilterQuality.Low,
                )
            } else {
                Box(Modifier.fillMaxSize().background(NEUTRAL_PLACEHOLDER))
            }
        }
    }
}

private fun android.util.Size.toComposeSize(): Size = Size(width.toFloat(), height.toFloat())
