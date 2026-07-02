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
        guard let provider = CGDataProvider(data: Data(buf) as CFData),
              let cg = CGImage(width: n, height: n, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: n * 4,
                               space: space, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
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

    /// Wrap a CGImage back into a platform image at 1x (so `.size` in points == pixel dimensions).
    static func platformImage(from cg: CGImage, size: CGSize) -> PlatformImage {
        #if canImport(UIKit)
        return UIImage(cgImage: cg)
        #else
        return NSImage(cgImage: cg, size: size)
        #endif
    }

    /// Produce the ready-to-draw variant: downscale so width <= `targetWidth` (points) when the image is
    /// wider, then apply a rounded-corner mask when `cornerRadius > 0`. Returns the original image untouched
    /// when neither transform applies. Everything here is CoreGraphics and safe off the main thread.
    static func variant(from image: PlatformImage, targetWidth: CGFloat?, cornerRadius: CGFloat) -> PlatformImage {
        guard let cg = cgImage(from: image) else {
            return image
        }
        let naturalWidth = CGFloat(cg.width)
        let naturalHeight = CGFloat(cg.height)
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

        let unchanged = width == naturalWidth && height == naturalHeight
        if unchanged && cornerRadius <= 0 {
            return image
        }

        let pixelWidth = Int(width)
        let pixelHeight = Int(height)
        guard pixelWidth > 0, pixelHeight > 0 else {
            return image
        }
        let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: nil, width: pixelWidth, height: pixelHeight, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
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
