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
// On Windows the module is built from the same portable value types and the portable files of Linux/ (the memory
// cache, the sidecar codec, the animation and orientation readers), over Windows' own libraries: WIC (Windows
// Imaging Component, in Swift's WinSDK module) decodes, WinHTTP fetches and BCrypt hashes (through
// CAsyncImageCacheWindows, a module of this package's own: WinSDK has neither). The Windows/ folders hold the
// Windows engine and its tests.
//
// See README.md for the API, design, and performance notes.

import PackageDescription

// The Apple-only sources of the AsyncImageCache target and its tests. A new Apple-only file must be added
// here, or the Linux and Windows builds fail on its Apple imports.
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

#if os(Linux)

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
            exclude: appleOnlySources + ["Windows"]
        ),
        .testTarget(
            name: "AsyncImageCacheTests",
            dependencies: ["AsyncImageCache", "CAsyncImageCacheGtk"],
            exclude: appleOnlyTests + ["Windows"]
        ),
    ]
)
#elseif os(Windows)
// The Linux engine's files that use GTK, GLib or libsoup; the rest of Linux/ is portable and built here too.
let linuxOnlySources = [
    "Linux/DiskCache+Linux.swift",
    "Linux/ImageProcessing+Linux.swift",
    "Linux/ImageStore+Linux.swift",
    "Linux/MainContext.swift",
    "Linux/PlatformImage+Linux.swift",
]

let package = Package(
    name: "AsyncImageCache",
    products: [
        .library(name: "AsyncImageCache", targets: ["AsyncImageCache"]),
    ],
    targets: [
        // WinHTTP and BCrypt, for the Windows engine.
        .systemLibrary(name: "CAsyncImageCacheWindows"),
        .target(
            name: "AsyncImageCache",
            dependencies: ["CAsyncImageCacheWindows"],
            exclude: appleOnlySources + linuxOnlySources
        ),
        .testTarget(
            name: "AsyncImageCacheTests",
            dependencies: ["AsyncImageCache"],
            exclude: appleOnlyTests + ["Linux"]
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
        // The Linux and Windows engines and their tests (in Linux/ and Windows/ folders) are not built here.
        .target(name: "AsyncImageCache", exclude: ["Linux", "Windows"]),
        .testTarget(name: "AsyncImageCacheTests", dependencies: ["AsyncImageCache"], exclude: ["Linux", "Windows"]),
    ]
)
#endif
