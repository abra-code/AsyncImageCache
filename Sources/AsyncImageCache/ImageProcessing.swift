// Sources/AsyncImageCache/ImageProcessing.swift
//
// Pure CoreGraphics helpers - all intended to run OFF the main thread. Decode is PlatformImage(data:) at the
// call site; this file handles the natural-pixel-size lookup, the downscale-to-target-width, and the
// rounded-corner mask, all by drawing into a fresh CGContext and wrapping the result back into a
// PlatformImage.

import Foundation
import CoreGraphics

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

enum ImageProcessing {

    /// The backing CGImage, if the platform image has one.
    static func cgImage(from image: PlatformImage) -> CGImage? {
        #if canImport(UIKit)
        return image.cgImage
        #else
        return image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        #endif
    }

    /// The image with its EXIF orientation baked into the pixels. UIImage keeps the UNROTATED bitmap in
    /// `cgImage` and applies `imageOrientation` only at draw time - so the variant/placeholder pipelines,
    /// which draw the CGImage directly, would render phone photos sideways (and disagree with `pixelSize`,
    /// which IS orientation-corrected). Redraws only when not already `.up`; NSImage applies EXIF orientation
    /// at decode, so macOS returns the image untouched. Off-main safe (UIGraphicsImageRenderer is thread-safe).
    static func orientedUp(_ image: PlatformImage) -> PlatformImage {
        #if canImport(UIKit)
        guard image.imageOrientation != .up else {
            return image
        }
        let format = UIGraphicsImageRendererFormat()
        format.scale = image.scale
        return UIGraphicsImageRenderer(size: image.size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: image.size))
        }
        #else
        return image
        #endif
    }

    /// The image's placeholder grid: an N x N (N = ImagePlaceholderConfig.gridDimension) set of average colors
    /// in sRGB. Draws the image into an N x N context (CoreGraphics area-averages as it downsamples) and reads
    /// the cells back, row 0 = TOP (a CGBitmapContext stores memory row 0 as the top of the drawn image). The
    /// bitmap is premultiplied, so each cell is un-premultiplied by alpha to recover the true tint (alpha kept,
    /// so transparent images give a translucent placeholder). Off-main; nil if there is no CGImage / context.
    static func placeholder(of image: PlatformImage) -> ImagePlaceholder? {
        guard let cg = cgImage(from: image) else {
            return nil
        }
        let n = ImagePlaceholderConfig.gridDimension
        var buf = [UInt8](repeating: 0, count: n * n * 4)
        let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let drawn = buf.withUnsafeMutableBytes { raw -> Bool in
            guard let base = raw.baseAddress,
                  let ctx = CGContext(data: base, width: n, height: n, bitsPerComponent: 8, bytesPerRow: n * 4,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
                return false
            }
            ctx.interpolationQuality = .medium
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: n, height: n))
            return true
        }
        guard drawn else {
            return nil
        }
        var cells: [ImageColor] = []
        cells.reserveCapacity(n * n)
        for i in 0..<(n * n) {
            let alpha = buf[i * 4 + 3]
            func un(_ channel: UInt8) -> UInt8 { alpha == 0 ? 0 : UInt8(min(255, Int(channel) * 255 / Int(alpha))) }
            cells.append(ImageColor(red: un(buf[i * 4]), green: un(buf[i * 4 + 1]), blue: un(buf[i * 4 + 2]), alpha: alpha))
        }
        return ImagePlaceholder(dimension: n, cells: cells)
    }

    /// An N x N platform image built from a placeholder grid, for upscaling with interpolation into a soft
    /// gradient at display time. nil if the grid is malformed.
    static func gridImage(from placeholder: ImagePlaceholder) -> PlatformImage? {
        let n = placeholder.dimension
        guard n > 0, placeholder.cells.count == n * n else {
            return nil
        }
        var buf = [UInt8](repeating: 0, count: n * n * 4)
        for (i, c) in placeholder.cells.enumerated() {
            buf[i * 4] = c.red; buf[i * 4 + 1] = c.green; buf[i * 4 + 2] = c.blue; buf[i * 4 + 3] = c.alpha
        }
        let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        // The cells hold UN-premultiplied rgba (placeholder(of:) un-premultiplies on capture), so the image
        // must be tagged .last, not premultiplied - otherwise semi-transparent placeholders composite too
        // bright (the color channels get counted at full strength AND the backdrop shows through).
        guard let provider = CGDataProvider(data: Data(buf) as CFData),
              let cg = CGImage(width: n, height: n, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: n * 4,
                               space: space, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                               provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) else {
            return nil
        }
        return platformImage(from: cg, size: CGSize(width: n, height: n))
    }

    /// Natural size in PIXELS, read from the image's own metadata rather than by forcing a CGImage. For
    /// UIImage that is size * scale (UIImage.cgImage is cheap for bitmap-backed images but nil for
    /// CIImage/symbol-backed, so this is both cheaper and more robust). For NSImage it is the largest
    /// representation's pixel dimensions - NSImage.cgImage(forProposedRect:) can RASTERIZE, which is wasteful
    /// just to read dimensions on the hot load path; NSImageRep.pixelsWide/High reads the header only.
    static func pixelSize(of image: PlatformImage) -> CGSize {
        #if canImport(UIKit)
        return CGSize(width: image.size.width * image.scale, height: image.size.height * image.scale)
        #else
        var best = CGSize.zero
        for rep in image.representations {
            let size = CGSize(width: rep.pixelsWide, height: rep.pixelsHigh)   // 0 for resolution-independent reps
            if size.width * size.height > best.width * best.height {
                best = size
            }
        }
        return (best.width > 0 && best.height > 0) ? best : image.size
        #endif
    }

    /// The resident RAM footprint of a decoded image in bytes - its DECODED bitmap, not its compressed
    /// transport size. Used as the NSCache cost so the variant cache is bounded by wired memory rather than a
    /// bare object count (a single 12 MP photo decodes to ~48 MB regardless of how well its JPEG compressed).
    /// `bytesPerRow * height` is the exact allocation (it accounts for row padding); the size*4 branch is a
    /// floor for the rare image with no CGImage.
    static func memoryCost(of image: PlatformImage) -> Int {
        if let cg = cgImage(from: image) {
            return max(1, cg.bytesPerRow * cg.height)
        }
        let size = pixelSize(of: image)
        return max(1, Int(size.width) * Int(size.height) * 4)
    }

    /// Wrap a CGImage back into a platform image at 1x (so `.size` in points == pixel dimensions). On macOS
    /// this goes through NSBitmapImageRep(cgImage:), NOT NSImage(cgImage:size:): the latter reports its pixel
    /// dimensions as size * the display's backing scale, so `pixelsWide` (and therefore pixelSize / memoryCost)
    /// reads 2x on a Retina screen. A bitmap rep carries the exact pixel dimensions, so downstream size and
    /// cost accounting stay accurate and machine-independent.
    static func platformImage(from cg: CGImage, size: CGSize) -> PlatformImage {
        #if canImport(UIKit)
        return UIImage(cgImage: cg)
        #else
        let rep = NSBitmapImageRep(cgImage: cg)
        rep.size = size
        let image = NSImage(size: size)
        image.addRepresentation(rep)
        return image
        #endif
    }

    /// Produce the ready-to-draw variant: downscale so width <= `targetWidth` (pixels) when the image is
    /// wider, apply a rounded-corner mask when `cornerRadius > 0`, and ALWAYS redraw into a fresh bitmap even
    /// when neither transform applies - PlatformImage(data:) defers the actual transport-format decompression
    /// to first draw, which would otherwise land on the MAIN thread at render time; drawing here forces the
    /// decode on the work queue, which is the library's core promise. Returns the original image only when
    /// there is no CGImage to draw or no context can be made. Safe off the main thread.
    static func variant(from image: PlatformImage, targetWidth: CGFloat?, cornerRadius: CGFloat) -> PlatformImage {
        guard let cg = cgImage(from: image) else {
            return image
        }
        // Base the geometry on the TRUE natural pixel size, NOT cg.width: on macOS cgImage(forProposedRect:)
        // can rasterize an NSImage at the display's backing scale, so cg.width is 2x the real size on a Retina
        // screen. pixelSize reads the native dimensions (representations / UIImage.scale); cg is only the
        // content, and ctx.draw scales it into the target rect. This also keeps output sizes deterministic
        // across machines (a headless 1x runner vs a 2x display).
        let natural = pixelSize(of: image)
        let naturalWidth = natural.width
        let naturalHeight = natural.height
        guard naturalWidth > 0, naturalHeight > 0 else {
            return image
        }

        var width = naturalWidth
        var height = naturalHeight
        if let targetWidth, targetWidth > 0, naturalWidth > targetWidth {
            let scale = targetWidth / naturalWidth
            width = (naturalWidth * scale).rounded()
            height = (naturalHeight * scale).rounded()
        }

        let pixelWidth = Int(width)
        let pixelHeight = Int(height)
        guard pixelWidth > 0, pixelHeight > 0 else {
            return image
        }
        // Keep an RGB-model source space (e.g. Display P3) so wide-gamut images are not clamped to sRGB;
        // other models (indexed, CMYK, grayscale) draw into sRGB, and if the source space cannot back a
        // bitmap context, sRGB is the fallback.
        let sRGB = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let space = (cg.colorSpace?.model == .rgb ? cg.colorSpace : nil) ?? sRGB
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
        guard let ctx = CGContext(data: nil, width: pixelWidth, height: pixelHeight, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: space, bitmapInfo: bitmapInfo)
            ?? CGContext(data: nil, width: pixelWidth, height: pixelHeight, bitsPerComponent: 8,
                         bytesPerRow: 0, space: sRGB, bitmapInfo: bitmapInfo) else {
            return image
        }
        ctx.interpolationQuality = .high
        let rect = CGRect(x: 0, y: 0, width: CGFloat(pixelWidth), height: CGFloat(pixelHeight))
        if cornerRadius > 0 {
            let radius = min(cornerRadius, min(CGFloat(pixelWidth), CGFloat(pixelHeight)) / 2)
            let path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
            ctx.addPath(path)
            ctx.clip()
        }
        ctx.draw(cg, in: rect)
        guard let out = ctx.makeImage() else {
            return image
        }
        return platformImage(from: out, size: CGSize(width: width, height: height))
    }
}
