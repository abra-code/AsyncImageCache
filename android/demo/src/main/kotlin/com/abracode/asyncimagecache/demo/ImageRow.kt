// ImageRow.kt
//
// One catalog entry: a caption (with remote/animated badges) plus the image. Passing intrinsicSize reserves the
// box at the correct aspect immediately (no reflow when the pixels arrive). Mirrors Demo/App/ImageRow.swift.
//
// Three display modes:
//   - normal: CachedImage - placeholder grid while loading, then the flattened first-frame image.
//   - animated: CachedImage with a Play overlay that swaps in AnimatedGifView (consumer-driven playback).
//   - "show placeholders only": the cached blurry preview rendered statically, so the grid is plainly visible
//     for anything loaded once (flat gray until then).

package com.abracode.asyncimagecache.demo

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.clickable
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.FilterQuality
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.foundation.Image
import com.abracode.asyncimagecache.CachedImage
import com.abracode.asyncimagecache.ContentMode
import com.abracode.asyncimagecache.ImageRequest
import com.abracode.asyncimagecache.ImageStore

@Composable
fun ImageRow(
    item: DemoImage,
    maxPixelWidth: Float?,
    store: ImageStore,
    showPlaceholderOnly: Boolean,
) {
    var isAnimated by remember(item.id) { mutableStateOf(store.isAnimated(item.url)) }
    var playing by remember(item.id) { mutableStateOf(false) }

    // Ensure the image passes through the cache so the derived metadata (animated flag, placeholder) becomes
    // known. De-duplicated with CachedImage's own load, so this is not a second fetch.
    LaunchedEffect(item.id) {
        store.loadAsync(ImageRequest(item.url, maxPixelWidth))
        isAnimated = store.isAnimated(item.url)
    }

    androidx.compose.foundation.layout.Column(modifier = Modifier.fillMaxWidth().padding(vertical = 8.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(item.title, style = MaterialTheme.typography.titleSmall, fontWeight = FontWeight.SemiBold)
            androidx.compose.foundation.layout.Spacer(Modifier.weight(1f))
            if (isAnimated) Badge("animated", Color(0xFFFF9800))
            Badge(if (item.isRemote) "remote" else "local", if (item.isRemote) Color(0xFF2196F3) else Color(0xFF4CAF50))
        }

        Box(
            modifier = Modifier
                .fillMaxWidth()
                .padding(top = 6.dp)
                .clip(RoundedCornerShape(14.dp)),
            contentAlignment = Alignment.BottomEnd,
        ) {
            when {
                showPlaceholderOnly -> PlaceholderOnly(item, store)
                isAnimated && playing -> AnimatedGifView(item.url, store, item.intrinsicSize, Modifier.fillMaxWidth())
                else -> CachedImage(
                    url = item.url,
                    modifier = Modifier.fillMaxWidth(),
                    intrinsicSize = item.intrinsicSize,
                    cornerRadius = 14.dp,
                    contentMode = ContentMode.Fill,
                    maxPixelWidth = maxPixelWidth,
                    store = store,
                )
            }
            if (isAnimated && !showPlaceholderOnly) {
                Text(
                    text = if (playing) "Pause" else "Play",
                    style = MaterialTheme.typography.labelMedium,
                    fontWeight = FontWeight.SemiBold,
                    color = Color.White,
                    modifier = Modifier
                        .padding(10.dp)
                        .clip(RoundedCornerShape(50))
                        .background(Color.Black.copy(alpha = 0.45f))
                        .clickable { playing = !playing }
                        .padding(horizontal = 14.dp, vertical = 8.dp),
                )
            }
        }

        item.intrinsicSize?.let {
            Text(
                "intrinsic ${it.width.toInt()} x ${it.height.toInt()}",
                style = MaterialTheme.typography.labelSmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.padding(top = 2.dp),
            )
        }
    }
}

// The reserved box filled with the cached blurry preview, or a labeled gray box if none exists yet.
@Composable
private fun PlaceholderOnly(item: DemoImage, store: ImageStore) {
    val aspect = item.intrinsicSize?.let { if (it.height > 0f) it.width / it.height else 4f / 3f } ?: (4f / 3f)
    LocalContext.current   // keep the store bound to a context lifecycle for parity with CachedImage default
    val preview = remember(item.id) { store.placeholderImage(item.url) }
    Box(modifier = Modifier.fillMaxWidth().aspectRatio(aspect), contentAlignment = Alignment.Center) {
        if (preview != null) {
            Image(
                bitmap = preview.asImageBitmap(),
                contentDescription = item.title,
                modifier = Modifier.fillMaxWidth().aspectRatio(aspect),
                contentScale = ContentScale.Crop,
                filterQuality = FilterQuality.Low,
            )
        } else {
            Box(Modifier.fillMaxWidth().aspectRatio(aspect).background(Color.Gray.copy(alpha = 0.12f)))
            Text(
                "no placeholder yet\nload once first",
                style = MaterialTheme.typography.labelSmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
    }
}

@Composable
private fun Badge(text: String, color: Color) {
    Text(
        text = text,
        style = MaterialTheme.typography.labelSmall,
        fontWeight = FontWeight.SemiBold,
        color = color,
        modifier = Modifier
            .padding(start = 6.dp)
            .background(color.copy(alpha = 0.15f), RoundedCornerShape(50))
            .padding(horizontal = 8.dp, vertical = 3.dp),
    )
}
