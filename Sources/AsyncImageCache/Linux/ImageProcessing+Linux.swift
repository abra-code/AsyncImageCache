// Sources/AsyncImageCache/Linux/ImageProcessing+Linux.swift
//
// The Linux image pipeline, the counterpart of ImageProcessing.swift - all intended to run OFF the main thread.
// Decoding goes through GdkPixbuf's loaders (PNG, JPEG, GIF, TIFF, and whatever else the system installs, WebP
// among them), which also bake the EXIF orientation into the pixels as the Apple decode does; GTK's own
// gdk_texture_new_from_bytes ignores it. The decoded pixbuf is the working form for the placeholder grid and the
// variant; the variant leaves as a GdkMemoryTexture (PlatformImage), so the pixels a widget draws are final.

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
import CAsyncImageCacheGtk

/// A decoded image: a GdkPixbuf (8 bits per channel RGB or RGBA, unpremultiplied), released with the last Swift
/// reference. Never modified after it is made, so it can be read from any thread.
final class DecodedImage: @unchecked Sendable {
    let pixbuf: OpaquePointer

    init(adopting pixbuf: OpaquePointer) {
        self.pixbuf = pixbuf
    }

    var width: Int {
        Int(gdk_pixbuf_get_width(pixbuf))
    }

    var height: Int {
        Int(gdk_pixbuf_get_height(pixbuf))
    }

    deinit {
        g_object_unref(UnsafeMutableRawPointer(pixbuf))
    }
}

enum ImageProcessing {

    /// Whether the transport bytes hold more than one frame (an animated GIF/APNG/WebP), from the container
    /// header without decoding (see AnimatedImageDetector).
    static func isAnimated(data: Data) -> Bool {
        return data.withUnsafeBytes { AnimatedImageDetector.isAnimated($0) }
    }

    // Most loaders report the size the file declares before they allocate any pixels, and a size of 0 makes them give
    // up. Some decode first (ICNS, QTIF, HEIF) or hand back a pixbuf anyway (SVG), so the flag decides, not the loader.
    private static let sizePrepared: @convention(c) (UnsafeMutablePointer<GdkPixbufLoader>?, gint, gint, gpointer?) -> Void = {
        loader, width, height, refused in
        guard !ImageLimits.accepts(width: ImageLength(width), height: ImageLength(height)) else {
            return
        }
        refused?.assumingMemoryBound(to: Bool.self).pointee = true
        gdk_pixbuf_loader_set_size(loader, 0, 0)
    }

    /// The bytes decoded, with the EXIF orientation applied, or nil when no loader reads them. An animated
    /// source gives its first frame, as on Apple platforms.
    static func decode(_ data: Data) -> DecodedImage? {
        guard !data.isEmpty, let loader = gdk_pixbuf_loader_new() else {
            return nil
        }
        defer {
            g_object_unref(UnsafeMutableRawPointer(loader))
        }
        let refused = UnsafeMutablePointer<Bool>.allocate(capacity: 1)
        refused.initialize(to: false)
        defer {
            refused.deallocate()
        }
        g_signal_connect_data(UnsafeMutableRawPointer(loader), "size-prepared", unsafeBitCast(sizePrepared, to: GCallback.self),
                              refused, nil, G_CONNECT_DEFAULT)
        var writeError: UnsafeMutablePointer<GError>?
        let wrote = data.withUnsafeBytes { raw -> gboolean in
            gdk_pixbuf_loader_write(loader, raw.bindMemory(to: guchar.self).baseAddress, gsize(raw.count), &writeError)
        }
        // Closed even after a failed write: a loader finalized unclosed warns.
        var closeError: UnsafeMutablePointer<GError>?
        let closed = gdk_pixbuf_loader_close(loader, &closeError)
        if let writeError {
            g_error_free(writeError)
        }
        if let closeError {
            g_error_free(closeError)
        }
        guard wrote != 0, closed != 0, !refused.pointee, let frame = gdk_pixbuf_loader_get_pixbuf(loader) else {
            return nil
        }
        // The loader's pixbuf is borrowed; the oriented one is a new reference (the same pixbuf when upright).
        guard gdk_pixbuf_get_colorspace(frame) == GDK_COLORSPACE_RGB, gdk_pixbuf_get_bits_per_sample(frame) == 8,
              let oriented = gdk_pixbuf_apply_embedded_orientation(frame) else {
            return nil
        }
        return DecodedImage(adopting: oriented)
    }

    /// Natural size in pixels, as displayed (after the EXIF orientation).
    static func pixelSize(of image: DecodedImage) -> ImageSize {
        return ImageSize(width: ImageLength(image.width), height: ImageLength(image.height))
    }

    /// The natural size AS DISPLAYED of the image file at `path`, read from its header without decoding the
    /// pixels: GdkPixbuf's file info, with the axes swapped for orientations 5-8 (rotations by 90 degrees; from a
    /// JPEG's EXIF or a TIFF's own tag, the two formats whose orientation GdkPixbuf applies when decoding),
    /// so it matches what the decode path records. nil when no loader recognizes the file.
    static func headerPixelSize(atPath path: String) -> ImageSize? {
        var width: Int32 = 0
        var height: Int32 = 0
        guard gdk_pixbuf_get_file_info(path, &width, &height) != nil, width > 0, height > 0 else {
            return nil
        }
        // Mapped, not read: only the leading segments are touched.
        let data = try? Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe)
        let orientation = data?.withUnsafeBytes { imageOrientation($0) } ?? 1
        if (5...8).contains(orientation) {
            return ImageSize(width: ImageLength(height), height: ImageLength(width))
        }
        return ImageSize(width: ImageLength(width), height: ImageLength(height))
    }

    /// The image's placeholder grid: an N x N (N = ImagePlaceholderConfig.gridDimension) set of average colors,
    /// row 0 = TOP. GdkPixbuf's bilinear reduction integrates over each cell's area, weighting color by alpha,
    /// which is what the Apple path gets from a premultiplied CoreGraphics context; the pixbuf is unpremultiplied,
    /// so the cells need no un-premultiplying. nil if the scaled pixbuf cannot be made.
    static func placeholder(of image: DecodedImage) -> ImagePlaceholder? {
        let n = ImagePlaceholderConfig.gridDimension
        guard let grid = gdk_pixbuf_scale_simple(image.pixbuf, Int32(n), Int32(n), GDK_INTERP_BILINEAR) else {
            return nil
        }
        defer {
            g_object_unref(UnsafeMutableRawPointer(grid))
        }
        let channels = Int(gdk_pixbuf_get_n_channels(grid))
        let rowStride = Int(gdk_pixbuf_get_rowstride(grid))
        let hasAlpha = gdk_pixbuf_get_has_alpha(grid) != 0
        guard let pixels = gdk_pixbuf_read_pixels(grid), channels >= (hasAlpha ? 4 : 3) else {
            return nil
        }
        var cells: [ImageColor] = []
        cells.reserveCapacity(n * n)
        for row in 0..<n {
            for column in 0..<n {
                let p = pixels + row * rowStride + column * channels
                cells.append(ImageColor(red: p[0], green: p[1], blue: p[2], alpha: hasAlpha ? p[3] : 255))
            }
        }
        return ImagePlaceholder(dimension: n, cells: cells)
    }

    /// An N x N image built from a placeholder grid, for upscaling with interpolation into a soft gradient at
    /// display time. The cells are unpremultiplied, and so is the texture's format. nil if the grid is malformed.
    static func gridImage(from placeholder: ImagePlaceholder) -> PlatformImage? {
        let n = placeholder.dimension
        guard n > 0, placeholder.cells.count == n * n else {
            return nil
        }
        var buffer = [UInt8](repeating: 0, count: n * n * 4)
        for (i, c) in placeholder.cells.enumerated() {
            buffer[i * 4] = c.red; buffer[i * 4 + 1] = c.green; buffer[i * 4 + 2] = c.blue; buffer[i * 4 + 3] = c.alpha
        }
        let bytes = buffer.withUnsafeBytes { g_bytes_new($0.baseAddress, gsize($0.count)) }
        defer {
            g_bytes_unref(bytes)
        }
        guard let texture = gdk_memory_texture_new(Int32(n), Int32(n), GDK_MEMORY_R8G8B8A8, bytes, gsize(n * 4)) else {
            return nil
        }
        return PlatformImage(adopting: texture)
    }

    /// The resident footprint of a ready-to-draw image in bytes: four per pixel, as GTK keeps a texture.
    static func memoryCost(of image: PlatformImage) -> Int {
        return max(1, image.pixelWidth * image.pixelHeight * 4)
    }

    /// Produce the ready-to-draw variant: downscale so width <= `targetWidth` (pixels) when the image is wider
    /// (never upscale; the height scales proportionally, rounded as on Apple platforms), and apply a rounded-
    /// corner mask when `cornerRadius > 0`. nil only if a pixbuf or the texture cannot be made. Safe off the
    /// main thread.
    static func variant(from image: DecodedImage, targetWidth: ImageLength?, cornerRadius: ImageLength) -> PlatformImage? {
        let naturalWidth = Double(image.width)
        let naturalHeight = Double(image.height)
        guard naturalWidth > 0, naturalHeight > 0 else {
            return nil
        }
        var width = naturalWidth
        var height = naturalHeight
        if let targetWidth, targetWidth > 0, naturalWidth > Double(targetWidth) {
            let scale = Double(targetWidth) / naturalWidth
            width = (naturalWidth * scale).rounded()
            height = (naturalHeight * scale).rounded()
        }
        var pixelWidth = Int(width)
        var pixelHeight = Int(height)
        var radius = cornerRadius
        if pixelWidth <= 0 || pixelHeight <= 0 {
            // A side that rounds to nothing (a long thin strip): the image as it is, as Apple platforms and
            // Android return their source.
            pixelWidth = image.width
            pixelHeight = image.height
            radius = 0
        }

        // A new reference in every branch, released after the texture copies the pixels out.
        var working: OpaquePointer
        if pixelWidth == image.width, pixelHeight == image.height {
            working = image.pixbuf
            g_object_ref(UnsafeMutableRawPointer(working))
        } else if let scaled = gdk_pixbuf_scale_simple(image.pixbuf, Int32(pixelWidth), Int32(pixelHeight),
                                                       GDK_INTERP_BILINEAR) {
            working = scaled
        } else {
            return nil
        }
        defer {
            g_object_unref(UnsafeMutableRawPointer(working))
        }
        if radius > 0 {
            // A fresh RGBA copy (also when it had alpha), so the mask never writes into the shared original.
            guard let masked = gdk_pixbuf_add_alpha(working, 0, 0, 0, 0) else {
                return nil
            }
            g_object_unref(UnsafeMutableRawPointer(working))
            working = masked
            roundCorners(of: working, radius: min(Double(radius), Double(min(pixelWidth, pixelHeight)) / 2))
        }

        let hasAlpha = gdk_pixbuf_get_has_alpha(working) != 0
        guard let bytes = gdk_pixbuf_read_pixel_bytes(working) else {
            return nil
        }
        defer {
            g_bytes_unref(bytes)
        }
        let format = hasAlpha ? GDK_MEMORY_R8G8B8A8 : GDK_MEMORY_R8G8B8
        guard let texture = gdk_memory_texture_new(Int32(pixelWidth), Int32(pixelHeight), format, bytes,
                                                   gsize(gdk_pixbuf_get_rowstride(working))) else {
            return nil
        }
        return PlatformImage(adopting: texture)
    }

    // Scale the alpha of the pixels outside the rounded rectangle by their coverage: 0 well outside each corner's
    // circle, 1 inside it, a linear ramp across the one-pixel edge (antialiasing, as CoreGraphics' clip gives).
    // `pixbuf` is an RGBA pixbuf this code owns.
    private static func roundCorners(of pixbuf: OpaquePointer, radius: Double) {
        guard radius > 0, let pixels = gdk_pixbuf_get_pixels(pixbuf) else {
            return
        }
        let width = Int(gdk_pixbuf_get_width(pixbuf))
        let height = Int(gdk_pixbuf_get_height(pixbuf))
        let rowStride = Int(gdk_pixbuf_get_rowstride(pixbuf))
        let span = Int(radius.rounded(.up))
        for y in 0..<height where y < span || y >= height - span {
            let centerY = y < span ? radius : Double(height) - radius
            for x in 0..<width where x < span || x >= width - span {
                let centerX = x < span ? radius : Double(width) - radius
                let dx = Double(x) + 0.5 - centerX
                let dy = Double(y) + 0.5 - centerY
                // Only the part beyond the circle's center, toward the corner, is curved.
                guard (x < span ? dx < 0 : dx > 0), (y < span ? dy < 0 : dy > 0) else {
                    continue
                }
                let coverage = min(1, max(0, radius - (dx * dx + dy * dy).squareRoot() + 0.5))
                let alpha = pixels + y * rowStride + x * 4 + 3
                alpha.pointee = UInt8((Double(alpha.pointee) * coverage).rounded())
            }
        }
    }

    // The orientation (1...8) of JPEG or TIFF bytes; 1 for other formats or no valid orientation.
    static func imageOrientation(_ d: UnsafeRawBufferPointer) -> Int {
        return tiffOrientation(d, from: 0, to: d.count) ?? jpegOrientation(d)
    }

    // The EXIF orientation (1...8) of JPEG bytes, from the TIFF IFD0 of the APP1 "Exif" segment; 1 when the
    // bytes are not JPEG or carry no valid orientation. Reads only the segments before the image data.
    static func jpegOrientation(_ d: UnsafeRawBufferPointer) -> Int {
        guard d.count >= 4, d[0] == 0xFF, d[1] == 0xD8 else {
            return 1
        }
        var i = 2
        while i + 4 <= d.count {
            guard d[i] == 0xFF else {
                return 1
            }
            let marker = d[i + 1]
            if marker == 0xFF {   // a fill byte before the marker
                i += 1
                continue
            }
            if marker == 0x01 || (0xD0...0xD8).contains(marker) {   // markers without a length
                i += 2
                continue
            }
            if marker == 0xDA || marker == 0xD9 {   // start of scan or end of image: no EXIF before it
                return 1
            }
            let length = Int(d[i + 2]) << 8 | Int(d[i + 3])
            let end = i + 2 + length
            guard length >= 2, end <= d.count else {
                return 1
            }
            if marker == 0xE1, let orientation = exifOrientation(d, from: i + 4, to: end) {
                return orientation
            }
            i = end
        }
        return 1
    }

    // The orientation of an APP1 payload "Exif\0\0" + TIFF, or nil.
    private static func exifOrientation(_ d: UnsafeRawBufferPointer, from start: Int, to end: Int) -> Int? {
        let exifHeader: [UInt8] = [0x45, 0x78, 0x69, 0x66, 0x00, 0x00]
        guard end - start >= 14, d[start..<(start + 6)].elementsEqual(exifHeader) else {
            return nil
        }
        return tiffOrientation(d, from: start + 6, to: end)
    }

    // The orientation tag (0x0112, a SHORT) of IFD0 in TIFF data at d[tiff..<end] (a TIFF file, or the payload of
    // a JPEG's EXIF segment), or nil when it is not TIFF or has no valid tag.
    private static func tiffOrientation(_ d: UnsafeRawBufferPointer, from tiff: Int, to end: Int) -> Int? {
        guard end - tiff >= 8 else {
            return nil
        }
        let littleEndian: Bool
        if d[tiff] == 0x49, d[tiff + 1] == 0x49 {
            littleEndian = true
        } else if d[tiff] == 0x4D, d[tiff + 1] == 0x4D {
            littleEndian = false
        } else {
            return nil
        }
        func u16(_ o: Int) -> Int? {
            guard o >= tiff, o + 2 <= end else {
                return nil
            }
            return littleEndian ? Int(d[o]) | Int(d[o + 1]) << 8 : Int(d[o]) << 8 | Int(d[o + 1])
        }
        func u32(_ o: Int) -> Int? {
            guard let low = u16(littleEndian ? o : o + 2), let high = u16(littleEndian ? o + 2 : o) else {
                return nil
            }
            return high << 16 | low
        }
        guard u16(tiff + 2) == 42, let ifdOffset = u32(tiff + 4), let count = u16(tiff + ifdOffset) else {
            return nil
        }
        for entry in 0..<count {
            let e = tiff + ifdOffset + 2 + entry * 12
            guard let tag = u16(e) else {
                return nil
            }
            if tag == 0x0112 {
                guard u16(e + 2) == 3, let value = u16(e + 8), (1...8).contains(value) else {
                    return nil
                }
                return value
            }
        }
        return nil
    }
}
