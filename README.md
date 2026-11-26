# AsyncImageCache

A small, reusable async image loading + caching component for iOS / macOS / visionOS, for GTK 4 programs on Linux, and for Windows programs. Shipped as a separate SPM library product so any consumer (RichText inline images, an
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
    public init(name: String = "default", memoryCountLimit: Int = 150,
                memoryByteLimit: Int = ImageStore.recommendedMemoryByteLimit(),  // scales with device RAM
                diskByteLimit: Int = 200 * 1024 * 1024,
                downloadByteLimit: Int = ImageStore.defaultDownloadByteLimit)

    // The most bytes one http or https download may bring (see "Download size limit"). Settable at any time.
    public static let defaultDownloadByteLimit: Int   // 32 MB
    public var downloadByteLimit: Int

    // A per-tier memory budget scaled to physical RAM (a fraction, clamped per platform). macOS gets a higher
    // ceiling than iOS, where NSCache's automatic memory-pressure purge is the real safety net.
    public static func recommendedMemoryByteLimit() -> Int

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
    originals (raw bytes + natural pixel size). Each tier is bounded by BOTH a count limit and a byte
    (`totalCostLimit`) budget: variant cost is the DECODED bitmap size (`width*height*4`), original cost is the
    compressed transport size. So a handful of large photos evict on wired-RAM pressure, not just on count -
    `memoryByteLimit` caps each tier (default 100 MB).
  - On disk: the ORIGINAL transport bytes under `<Caches>/AsyncImageCache/<name>/`, filenames = `SHA256(url)`,
    with a soft byte budget enforced by an LRU-ish trim (oldest-by-mtime). Survives relaunch; the OS may
    still evict Caches (a miss just falls through to the network). Local `file:` images (and `content:` on
    Android) are never copied here: the file is its own copy, and a copy would go on showing the old picture
    after the file is edited. In memory, a local file's entries are keyed on its modification time and size
    too, so the next load after an edit reads the new picture (the store does not watch files).
- Byte resolution order (off-main): in-memory originals -> disk -> source (`data:`/`file:` decode locally,
  `http(s)` via `URLSession`, with none of the app's cookies or stored credentials, and no answer to a
  sign-in challenge: an image address can come from anywhere).
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

## Image size limit

A file names its own size, and an image can come from anywhere, so an image declaring more than 65,536 pixels on a side, or more than 268 megapixels (16384 x 16384), or 64 megapixels (8192 x 8192) on iOS, where the system ends an app that takes too much memory, is refused before anything is rasterized: it fails to load like a corrupt file, and nothing is cached. That is well past any photo or panorama. Vector images (SVG, PDF on macOS) count at the size they declare, and rasterize at that size. An image at the limit costs two to four times its decoded size at the peak of loading it: 2 to 4 GB, or up to about 1 GB on iOS.

## Download size limit

A server can send a huge body, or one that never ends, so one http or https download may bring at most `downloadByteLimit` bytes, 32 MB by default. A response that declares a larger size is refused before its body is read, and one that sends more is cut off when it passes the limit; the load then delivers nil, as for a failed download, and nothing is cached. Images read from a file or a data: URL, and bytes already in the cache, are not limited.

32 MB is past any photo a web page shows. A host that shows raw camera files or photos saved with little compression raises the limit, on the shared store or its own, once at launch; a new value applies to downloads that start after it is set:

```swift
ImageStore.shared.downloadByteLimit = 200 * 1024 * 1024
```

The Android port has the same setting, in bytes as a Long (`ImageStore.DEFAULT_DOWNLOAD_BYTE_LIMIT`, `downloadByteLimit` on the store and in its constructor); content: URLs are not limited either:

```kotlin
ImageStore.shared(context).downloadByteLimit = 200L * 1024 * 1024
```

## Linux

On Linux the same `AsyncImageCache` module builds over the platform's own libraries, found through pkg-config: GTK 4 (`gtk4`, which brings GLib and GdkPixbuf) and libsoup 3 (`libsoup-3.0`). It uses FoundationEssentials only, so a program that links it carries no ICU data. The oldest versions supported are GNOME 48's: GTK 4.18, GLib 2.84 and libsoup 3.6. https needs the GIO TLS backend, glib-networking, which GNOME desktops install.

The API is the one above, with these differences:

- `PlatformImage` is a class around a GdkTexture: `texture` (a `GdkTexture *` as an `OpaquePointer`), `pixelWidth` and `pixelHeight`. Show it with `gtk_picture_set_paintable`; the widget takes its own reference.
- Sizes are `ImageSize` (`width`, `height`) where the Apple API returns CGSize, and `ImageRequest` takes its lengths as `ImageLength`, which is CGFloat on Apple platforms and Double on Linux.
- Completions run on the thread of GLib's default main context, the GTK main loop, so any GTK program receives them however it drives libdispatch's main queue. Tests that wait for one iterate the context (`g_main_context_iteration`).
- Decoding goes through GdkPixbuf's loaders (PNG, JPEG, GIF, TIFF, and others the system installs, such as WebP), with the EXIF orientation applied. A truncated image does not decode.
- The disk cache lives in `$XDG_CACHE_HOME/AsyncImageCache/<name>/` (`~/.cache` by default), with the same file names as on Apple platforms. The size, animated flag and placeholder are kept in a `<file>.meta` file beside each image rather than in extended attributes, which Linux cache folders cannot be relied on to keep. The format is the Android port's.
- http and https go through one libsoup session, which sends a User-Agent and allows six connections per host, as URLSession does, and has no cookie jar, as the Apple session keeps none. The store reads each body in pieces to hold it to the download limit, and follows redirects itself (up to 20), since libsoup's own following reads a redirect's body outside any limit.
- Linux has no memory-pressure signal for a process, so the memory limits are the whole bound. `recommendedMemoryByteLimit()` uses the desktop range: 1/16 of RAM, between 256 MB and 1 GB.
- `CachedImage` (the SwiftUI view) is Apple-only.

Tests run with `swift test` on Linux too. The shared fixtures (`Fixtures/`) hold Linux to the same decoded values as Apple platforms and Android.

## Windows

On Windows the same `AsyncImageCache` module builds over Windows' own libraries: WIC (Windows Imaging Component, in Swift's WinSDK module) decodes, WinHTTP fetches and BCrypt hashes, through `CAsyncImageCacheWindows`, a module of this package's own (WinSDK has neither WinHTTP nor BCrypt). It needs Windows 10 or later.

The API is the Linux one above (`ImageSize`, `ImageLength` as Double), with these differences:

- `PlatformImage` is the image a WinUI 3 program shows: `pixelWidth`, `pixelHeight` and, on the main thread, `imageSource`, a borrowed `IInspectable *` of a WinUI image source to set as an Image's `Source`. Every element that shows the image shares that one source. For a variant without rounded corners it is a WinUI `BitmapImage` given the image's encoded bytes: WinUI decodes them on its own threads at the variant's width, applies the EXIF orientation, shows an animated image's first frame, and keeps one copy of the pixels. A variant with corners (baked into its pixels) and the placeholder grid are a `SoftwareBitmapSource`: the pixels are made on the work queue and end in a Windows `SoftwareBitmap` there, and WinUI keeps two copies of them; a host that rounds corners itself (a clip) asks for none. Only the WinUI object is made on the main thread, which WinUI requires. An image shown at full size costs its full decoded size: a host that shows thumbnails asks for a `targetWidth` near the size it shows them at. The program must have started the Windows App SDK, and its main dispatch queue must be drained on its UI thread; without WinUI (a test) `imageSource` is nil. The package links nothing of the Windows App SDK: WinUI is reached through WinRT activation at run time.
- Completions run on the main dispatch queue. A program that uses the store drains that queue from its message loop; tests run the main run loop while they wait.
- Decoding goes through WIC (PNG, JPEG, GIF, BMP, TIFF, ICO, JPEG XR, and codecs the system adds, such as HEIF and WebP). WIC does not apply the EXIF orientation, so the decode turns the pixels itself. WIC's Fant scaler shrinks variants and makes the placeholder grid.
- The disk cache lives in `%LOCALAPPDATA%\AsyncImageCache\<name>\` (FileManager's caches folder is the temporary folder on Windows, which the system empties), with the same file names and `.meta` files as on Linux.
- A file: URL is read from the path Windows opens for it: with a host, a file on that server's share (`file://server/share/a.png`). A host program that shows content it does not trust judges that path before it asks the store. Only regular files are read, never a device such as NUL or CON.
- http and https go through one WinHTTP session, synchronously on a network queue, at most six downloads at a time. A download carries none of the user's identity: no cookies, no automatic Windows sign-in (to a server or a proxy) and no answers to sign-in challenges. It follows redirects itself (up to 20, http and https only), holds the body to the download limit, and allows each step 60 seconds. The system's proxy settings are used.
- As on Linux, the memory limits are the whole bound, and `CachedImage` (the SwiftUI view) is Apple-only.

Tests run with `swift test` on Windows too, against the same shared fixtures.

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
