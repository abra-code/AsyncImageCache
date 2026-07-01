// swift-tools-version: 6.0
//
// AsyncImageCache - a small, DEPENDENCY-FREE async image loading + caching component for
// iOS / iPadOS / macOS / visionOS. An off-main fetch/decode/downscale/round pipeline, a two-tier
// memory + on-disk cache, and size-known-upfront dimensions (persisted as a file extended attribute)
// so layout reserves the exact box with no reflow on hydration - even across relaunch.
//
// See README.md for the API, design, and performance notes.

import PackageDescription

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
        .target(name: "AsyncImageCache"),
        .testTarget(name: "AsyncImageCacheTests", dependencies: ["AsyncImageCache"]),
    ]
)
