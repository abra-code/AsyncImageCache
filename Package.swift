// swift-tools-version: 6.0
//
// AsyncImageCache - a small, DEPENDENCY-FREE async image loading + caching component for
// iOS / iPadOS / macOS / visionOS. An off-main fetch/decode/downscale/round pipeline, a two-tier
// memory + on-disk cache, and size-known-upfront dimensions (persisted as a file extended attribute)
// so layout reserves the exact box with no reflow on hydration - even across relaunch.
//
// On Linux the same AsyncImageCache module is built from the portable value types, over the
// platform's own libraries (GTK 4, GLib and libsoup 3, found through pkg-config) and FoundationEssentials
// only: the Apple engine files (CoreGraphics, ImageIO, CryptoKit, UIKit/AppKit, SwiftUI) are not compiled,
// and the Linux/ folders hold the Linux engine and its tests.
//
// See README.md for the API, design, and performance notes.

import PackageDescription

#if os(Linux)
// The Apple-only sources of the AsyncImageCache target and its tests. A new Apple-only file must be added
// here, or the Linux build fails on its Apple imports.
let appleOnlySources = [
    "CachedImage.swift",
    "DiskCache.swift",
    "ImageProcessing.swift",
    "ImageStore.swift",
    "PlatformImage.swift",
]
let appleOnlyTests = [
    "AsyncImageCacheTests.swift",
    "FixtureEmitterTests.swift",
]

let package = Package(
    name: "AsyncImageCache",
    products: [
        .library(name: "AsyncImageCache", targets: ["AsyncImageCache"]),
    ],
    targets: [
        // GTK 4's C API (GdkTexture) with GLib's, and libsoup 3's, for the Linux engine.
        .systemLibrary(name: "CAsyncImageCacheGtk", pkgConfig: "gtk4"),
        .systemLibrary(name: "CAsyncImageCacheSoup", pkgConfig: "libsoup-3.0"),
        .target(
            name: "AsyncImageCache",
            dependencies: ["CAsyncImageCacheGtk", "CAsyncImageCacheSoup"],
            exclude: appleOnlySources
        ),
        .testTarget(
            name: "AsyncImageCacheTests",
            dependencies: ["AsyncImageCache", "CAsyncImageCacheGtk"],
            exclude: appleOnlyTests
        ),
    ]
)
#else
let package = Package(
    name: "AsyncImageCache",
    platforms: [
        .macOS(.v13),
        .iOS(.v16),
        .visionOS(.v1),
    ],
    products: [
        .library(name: "AsyncImageCache", targets: ["AsyncImageCache"]),
    ],
    targets: [
        // The Linux engine and its tests (in Linux/ folders) are not built here.
        .target(name: "AsyncImageCache", exclude: ["Linux"]),
        .testTarget(name: "AsyncImageCacheTests", dependencies: ["AsyncImageCache"], exclude: ["Linux"]),
    ]
)
#endif
