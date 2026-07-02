// Demo/App/DemoApp.swift
//
// A tiny multiplatform (iOS + macOS) SwiftUI app that exercises AsyncImageCache's CachedImage in a scrolling
// LazyVStack: local build-time-generated images and remote images side by side, so you can watch off-main
// decode, the placeholder preview, zero-reflow layout, and the disk/memory cache take effect.

import SwiftUI

@main
struct AsyncImageCacheDemoApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        #if os(macOS)
        .defaultSize(width: 560, height: 940)
        #endif
    }
}
