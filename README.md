# AsyncImageCache

A small, reusable async image loading + caching component for iOS / macOS / visionOS. It is NOT tied to
RichText - it is shipped as a separate SPM library product so any consumer (RichText inline images, an
ActionUIChat image bubble, a standalone image element) can depend on just this.

Two design goals drive everything:

1. Nothing image-heavy runs on the main thread. Byte fetch, decode, downscale, and corner rounding all happen
   off-main; the ONLY main-thread work is the final completion callback. Long, image-heavy scrolling stays
   smooth.
2. Image dimensions are cheap to obtain BEFORE the pixels hydrate, so layout reserves the exact box and never
   reflows on hydration - even across app relaunch.

## API

```swift
public typealias PlatformImage = UIImage   // NSImage on macOS

// The cache variant key: a URL plus optional presentation transforms.
public struct ImageRequest: Hashable, Sendable {
    public init(url: URL, targetWidth: CGFloat? = nil, cornerRadius: CGFloat = 0)
}

public final class ImageStore: @unchecked Sendable {
    public static let shared: ImageStore
    public init(name: String = "default", memoryCountLimit: Int = 150, diskByteLimit: Int = 200 * 1024 * 1024)

    // Synchronous, thread-safe reads (fast; safe to call during layout):
    public func cachedImage(for request: ImageRequest) -> PlatformImage?            // ready-to-draw variant, nil on miss
    public func cachedPixelSize(for url: URL) -> CGSize?                            // natural size WITHOUT decoding (see below)
    public func cachedOriginalBytes(for url: URL) -> (data: Data, pixelSize: CGSize)?  // raw source bytes, e.g. for copy

    // Asynchronous load; completion fires on the MAIN thread. Concurrent identical requests are de-duplicated.
    public func load(_ request: ImageRequest, completion: @escaping (PlatformImage?) -> Void)

    public func clearMemory()
    public func removeAll()   // memory + disk
}

// SwiftUI view (named for the cache, to avoid confusion with SwiftUI's AsyncImage):
public struct CachedImage: View {
    public init(url: URL?, intrinsicSize: CGSize? = nil, cornerRadius: CGFloat = 0,
                contentMode: ContentMode = .fill, maxPixelWidth: CGFloat? = nil, store: ImageStore = .shared)
}
```

### Usage

```swift
// SwiftUI: reserves the box from `intrinsicSize` (e.g. server dims) -> zero reflow; loads off-main.
CachedImage(url: url, intrinsicSize: CGSize(width: 1024, height: 768), cornerRadius: 10)

// Direct store use (e.g. a UIView/NSView): reserve size synchronously, then hydrate.
let size = ImageStore.shared.cachedPixelSize(for: url)        // may be non-nil even on first launch of this run
ImageStore.shared.load(ImageRequest(url: url, targetWidth: 840, cornerRadius: 10)) { image in
    // on the main thread
}
```

## Design

- Two-tier cache:
  - In memory: an `NSCache` of ready-to-draw variants (keyed by the full `ImageRequest`) + an `NSCache` of
    originals (raw bytes + natural pixel size).
  - On disk: the ORIGINAL transport bytes under `<Caches>/AsyncImageCache/<name>/`, filenames = `SHA256(url)`,
    with a soft byte budget enforced by an LRU-ish trim (oldest-by-mtime). Survives relaunch; the OS may
    still evict Caches (a miss just falls through to the network).
- Byte resolution order (off-main): in-memory originals -> disk -> source (`data:`/`file:` decode locally,
  `http(s)` via `URLSession`).
- Variant key quantization: `targetWidth` / `cornerRadius` are `CGFloat` in the API (caller convenience) but
  QUANTIZED to whole pixels in the cache key, so sub-pixel layout jitter does not mint a distinct variant per
  fractional value; the store scales to the same quantized values.
- Format-agnostic: the cache stores bytes and hands back originals via `cachedOriginalBytes`. It does NOT
  transcode - copy/embedding concerns (PNG/JPEG/GIF choices, RTF still frames) belong to the consumer.
- `pixelSize` reads platform metadata, not a forced `CGImage`: `UIImage.size * scale` /
  `NSImageRep.pixelsWide/High` (NSImage's `cgImage(forProposedRect:)` can rasterize).

### Dimensions across relaunch (the "reserve now, hydrate later" guarantee)

Within a run, a loaded image's size lives in the memory cache. Across relaunch the memory tier is empty but
the disk bytes persist - so the natural pixel size is stored as an 8-byte extended attribute (two `Int32`) ON
the cached bytes file (`setxattr`/`getxattr`, `<sys/xattr.h>`; works on iOS as well as macOS - Foundation
re-exports the Darwin C API, no bridging header; xattr name `public.asyncimagecache.pixelsize`). So:

`cachedPixelSize` resolves: memory `originalCache` -> `pixelSizeMemo` (an `NSCache` of xattr-read sizes) ->
disk xattr (cheap `getxattr`, no decode; memoized). A cached image therefore reserves its exact box before its
pixels arrive, even on the first frame after a relaunch.

Fallback (resilience): should the xattr ever be missing while the bytes are still on disk - it was stripped, or
the bytes were cached by a build that predates the attribute - the size is recovered from the image HEADER via
`CGImageSource` (still no full decode), and the xattr is REPAIRED so the next read is back on the fast path. So
a lost attribute costs one slightly-slower read, never a wrong box or a full decode.

## Performance (dimensions of 100 cached ~1024x768 gradient JPEGs)

Measured with XCTest `measure` (see `AsyncImageCacheTests`), 10 iterations, per whole batch of 100:

| Getting the natural size 100x | Total (avg) | Per file |
|---|---|---|
| xattr read (`getxattr`, 8 bytes) | ~7 ms | ~70 us |
| `CGImageSource` header (no decompress) | ~10 ms | ~100 us |
| read file + decode | ~15 ms | ~150 us |

Reading:
- The xattr read is the fastest and, crucially, O(1) in image size - it touches 8 bytes regardless of whether
  the image is 8x8 or 6000x4000, while the decode/header paths grow with the file. A real multi-MB photo (a
  smooth gradient compresses well, so this is a conservative contrast) widens the gap further.
- Honestly, `CGImageSource`'s header read is a close, decode-free alternative that needs no extra write. The
  xattr still edges it (format-independent, no file open) and, once read, memoizes to a nanosecond memory hit;
  `CGImageSource` re-opens + parses each call unless cached the same way. The real win in either approach is
  the memoization that makes steady-state layout queries free.

All three paths are well under a millisecond per lookup, so obtaining dimensions is never the bottleneck; the
point is that the xattr keeps it that way as images get large.
