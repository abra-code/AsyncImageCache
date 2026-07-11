// Demo app entry point. Stage A: a minimal shell that confirms the module compiles and launches against the
// library. Stage E replaces the body with the grid / placeholder / GIF-playback screens that mirror the
// SwiftUI Demo/ app.

package com.abracode.asyncimagecache.demo

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContent {
            MaterialTheme {
                Surface(modifier = Modifier.fillMaxSize()) {
                    DemoRoot()
                }
            }
        }
    }
}

@Composable
private fun DemoRoot() {
    Box(modifier = Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
        Text("AsyncImageCache demo - screens land in Stage E")
    }
}
