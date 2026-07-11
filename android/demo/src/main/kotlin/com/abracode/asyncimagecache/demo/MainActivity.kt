// MainActivity.kt
//
// The demo app: a scrolling list of CachedImage rows mirroring the SwiftUI Demo/App/ContentView.swift. Controls
// at the top let you cap the decoded width (watch the off-main downscale), switch to a deliberately TINY memory
// budget (watch variants evict + the placeholder reappear on reload), render "placeholders only" (see the 6x6
// grid for anything loaded once), and clear the memory or the whole cache. An animated GIF section proves the
// consumer-driven playback contract.

package com.abracode.asyncimagecache.demo

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.Button
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.abracode.asyncimagecache.ImageStore

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContent {
            MaterialTheme {
                Surface(modifier = Modifier.fillMaxSize()) {
                    DemoScreen()
                }
            }
        }
    }
}

@Composable
private fun DemoScreen() {
    val context = LocalContext.current
    val defaultStore = remember { ImageStore.shared(context) }
    // A deliberately tiny store sharing the SAME disk directory ("default") so switching budgets does not
    // re-download - only the in-memory eviction behavior changes.
    val tinyStore = remember {
        ImageStore(context, name = "default", memoryCountLimit = 3, memoryByteLimit = 2L * 1024 * 1024)
    }

    var capDecodedWidth by remember { mutableStateOf(false) }
    var useTinyBudget by remember { mutableStateOf(false) }
    var showPlaceholdersOnly by remember { mutableStateOf(false) }
    // Bumped on "clear" so rows re-key and reload from a cold cache.
    var reloadToken by remember { mutableStateOf(0) }

    val store = if (useTinyBudget) tinyStore else defaultStore
    val maxPixelWidth: Float? = if (capDecodedWidth) 400f else null

    val remote = remember { DemoCatalog.remoteImages() }
    val animated = remember { DemoCatalog.animatedImages() }

    LazyColumn(
        modifier = Modifier.fillMaxSize().padding(16.dp),
        verticalArrangement = Arrangement.spacedBy(4.dp),
    ) {
        item {
            Column {
                Text("AsyncImageCache demo", style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.Bold)
                Text(
                    "Off-main decode + downscale, placeholder preview, zero-reflow layout, two-tier cache.",
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
                ToggleRow("Cap decoded width to 400 px", capDecodedWidth) { capDecodedWidth = it }
                ToggleRow("Tiny memory budget (2 MB)", useTinyBudget) { useTinyBudget = it }
                ToggleRow("Show placeholders only", showPlaceholdersOnly) { showPlaceholdersOnly = it }
                Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                    Button(onClick = {
                        defaultStore.clearMemory(); tinyStore.clearMemory(); reloadToken++
                    }) { Text("Clear memory") }
                    Button(onClick = {
                        defaultStore.removeAll(); tinyStore.clearMemory(); reloadToken++
                    }) { Text("Clear memory + disk") }
                }
            }
        }

        item { SectionHeader("Remote (picsum.photos, fetched + cached)") }
        items(remote, key = { "${it.id}-$reloadToken-$useTinyBudget-$showPlaceholdersOnly-$capDecodedWidth" }) { item ->
            ImageRow(item, maxPixelWidth, store, showPlaceholdersOnly)
        }

        item { SectionHeader("Animated (consumer-driven GIF playback)") }
        items(animated, key = { "${it.id}-$reloadToken-$useTinyBudget-$showPlaceholdersOnly-$capDecodedWidth" }) { item ->
            ImageRow(item, maxPixelWidth, store, showPlaceholdersOnly)
        }
    }
}

@Composable
private fun ToggleRow(label: String, checked: Boolean, onChange: (Boolean) -> Unit) {
    Row(
        modifier = Modifier.fillMaxWidth().padding(vertical = 2.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(label, style = MaterialTheme.typography.bodyMedium, modifier = Modifier.weight(1f))
        Switch(checked = checked, onCheckedChange = onChange)
    }
}

@Composable
private fun SectionHeader(text: String) {
    Text(
        text = text,
        style = MaterialTheme.typography.titleMedium,
        fontWeight = FontWeight.SemiBold,
        modifier = Modifier.padding(top = 12.dp, bottom = 4.dp),
    )
}
