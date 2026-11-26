// Sources/AsyncImageCache/Windows/ImageProcessing+Windows.swift
//
// The Windows image pipeline, the counterpart of ImageProcessing.swift and ImageProcessing+Linux.swift - all
// intended to run OFF the main thread. Decoding goes through WIC (Windows Imaging Component), which reads PNG, JPEG,
// GIF, BMP, TIFF, ICO, JPEG XR, DDS and whatever codecs the system adds (HEIF, WebP, AVIF from the Store). WIC does
// not apply the EXIF orientation, so the decode turns the pixels itself (ImageOrientation.swift reads it), as the
// Apple and Linux decodes bake it in. The decoded pixels (premultiplied BGRA) are the working form for the
// placeholder grid and the variant; WIC's Fant scaler (an area average) shrinks them.
//
// WIC's objects are COM objects, called here through their C interfaces (lpVtbl). Each call makes its own factory
// on its own thread, inside CoInitializeEx: the work queue's threads belong to no apartment of their own.

#if os(Windows)

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
import WinSDK

/// A decoded image: `width` x `height` pixels, premultiplied BGRA, rows of width x 4 bytes, upright (the EXIF
/// orientation applied). Never modified after it is made, so it can be read from any thread.
final class DecodedImage: Sendable {
    let width: Int
    let height: Int
    let pixels: [UInt8]

    init(width: Int, height: Int, pixels: [UInt8]) {
        self.width = width
        self.height = height
        self.pixels = pixels
    }
}

enum ImageProcessing {

    /// Whether the transport bytes hold more than one frame (an animated GIF/APNG/WebP), from the container
    /// header without decoding (see AnimatedImageDetector).
    static func isAnimated(data: Data) -> Bool {
        return data.withUnsafeBytes { AnimatedImageDetector.isAnimated($0) }
    }

    /// The bytes decoded, upright, or nil when no WIC codec reads them or they declare a size past ImageLimits
    /// (checked before any pixels are allocated). An animated source gives its first frame, as on Apple platforms.
    static func decode(_ data: Data) -> DecodedImage? {
        let orientation = data.withUnsafeBytes { imageOrientation($0) }
        let decoded: (width: Int, height: Int, pixels: [UInt8])? = WIC.withFirstFrame(of: data) { factory, frame in
            var width: UINT = 0
            var height: UINT = 0
            guard frame.pointee.lpVtbl.pointee.GetSize!(frame, &width, &height) >= 0, width > 0, height > 0,
                  ImageLimits.accepts(width: ImageLength(width), height: ImageLength(height)) else {
                return nil
            }
            var converter: UnsafeMutablePointer<IWICFormatConverter>?
            guard factory.pointee.lpVtbl.pointee.CreateFormatConverter!(factory, &converter) >= 0, let converter else {
                return nil
            }
            defer {
                WIC.release(converter)
            }
            var format = WIC.premultipliedBGRA
            guard converter.pointee.lpVtbl.pointee.Initialize!(converter, WIC.source(frame), &format,
                                                                WICBitmapDitherTypeNone, nil, 0,
                                                                WICBitmapPaletteTypeMedianCut) >= 0,
                  let pixels = WIC.copyPixels(WIC.source(converter), width: Int(width), height: Int(height)) else {
                return nil
            }
            return (Int(width), Int(height), pixels)
        }
        guard let decoded else {
            return nil
        }
        return oriented(decoded.pixels, width: decoded.width, height: decoded.height, orientation: orientation)
    }

    /// Natural size in pixels, as displayed (after the EXIF orientation).
    static func pixelSize(of image: DecodedImage) -> ImageSize {
        return ImageSize(width: ImageLength(image.width), height: ImageLength(image.height))
    }

    /// The natural size AS DISPLAYED of the image file at `path`, read from its header without decoding the
    /// pixels: the first frame's size, with the axes swapped for orientations 5-8 (rotations by 90 degrees), so it
    /// matches what the decode path records. nil when no codec recognizes the file.
    static func headerPixelSize(atPath path: String) -> ImageSize? {
        guard let data = FileManager.default.contents(atPath: path) else {
            return nil
        }
        let size: ImageSize? = WIC.withFirstFrame(of: data) { _, frame in
            var width: UINT = 0
            var height: UINT = 0
            guard frame.pointee.lpVtbl.pointee.GetSize!(frame, &width, &height) >= 0, width > 0, height > 0 else {
                return nil
            }
            return ImageSize(width: ImageLength(width), height: ImageLength(height))
        }
        guard let size else {
            return nil
        }
        let orientation = data.withUnsafeBytes { imageOrientation($0) }
        return (5...8).contains(orientation) ? ImageSize(width: size.height, height: size.width) : size
    }

    /// The image's placeholder grid: an N x N (N = ImagePlaceholderConfig.gridDimension) set of average colors,
    /// row 0 = TOP. The Fant scaler averages each cell's area in premultiplied pixels, so color is weighted by
    /// alpha, as the premultiplied CoreGraphics context on Apple platforms gives; the cells are unpremultiplied,
    /// as on Linux. nil if the scaled pixels cannot be made.
    static func placeholder(of image: DecodedImage) -> ImagePlaceholder? {
        let n = ImagePlaceholderConfig.gridDimension
        guard let grid = scaled(image, width: n, height: n) else {
            return nil
        }
        var cells: [ImageColor] = []
        cells.reserveCapacity(n * n)
        for index in 0..<(n * n) {
            let blue = grid[index * 4]
            let green = grid[index * 4 + 1]
            let red = grid[index * 4 + 2]
            let alpha = grid[index * 4 + 3]
            cells.append(ImageColor(red: unpremultiplied(red, alpha), green: unpremultiplied(green, alpha),
                                    blue: unpremultiplied(blue, alpha), alpha: alpha))
        }
        return ImagePlaceholder(dimension: n, cells: cells)
    }

    /// An N x N image built from a placeholder grid, for upscaling with interpolation into a soft gradient at
    /// display time. The cells are unpremultiplied; the image is premultiplied, as every PlatformImage. nil if the
    /// grid is malformed.
    static func gridImage(from placeholder: ImagePlaceholder) -> PlatformImage? {
        let n = placeholder.dimension
        guard n > 0, placeholder.cells.count == n * n else {
            return nil
        }
        var pixels = [UInt8](repeating: 0, count: n * n * 4)
        for (index, cell) in placeholder.cells.enumerated() {
            pixels[index * 4] = premultiplied(cell.blue, cell.alpha)
            pixels[index * 4 + 1] = premultiplied(cell.green, cell.alpha)
            pixels[index * 4 + 2] = premultiplied(cell.red, cell.alpha)
            pixels[index * 4 + 3] = cell.alpha
        }
        return PlatformImage(pixelWidth: n, pixelHeight: n, pixels: pixels)
    }

    /// The resident footprint of a ready-to-draw image in bytes: four per pixel.
    static func memoryCost(of image: PlatformImage) -> Int {
        return max(1, image.pixelWidth * image.pixelHeight * 4)
    }

    /// Produce the ready-to-draw variant: downscale so width <= `targetWidth` (pixels) when the image is wider
    /// (never upscale; the height scales proportionally, rounded as on Apple platforms), and apply a rounded-
    /// corner mask when `cornerRadius > 0`. nil only if the scaled pixels cannot be made. Safe off the main thread.
    static func variant(from image: DecodedImage, targetWidth: ImageLength?, cornerRadius: ImageLength) -> PlatformImage? {
        guard let size = variantSize(of: image, targetWidth: targetWidth) else {
            return nil
        }
        let pixelWidth = size.width
        let pixelHeight = size.height
        // No corners on an image left at its own size because a side rounded to nothing.
        let radius = size.isFallback ? 0 : Double(cornerRadius)
        var pixels: [UInt8]
        if pixelWidth == image.width, pixelHeight == image.height {
            // A copy on write: the mask below never writes into the shared original.
            pixels = image.pixels
        } else if let shrunk = scaled(image, width: pixelWidth, height: pixelHeight) {
            pixels = shrunk
        } else {
            return nil
        }
        if radius > 0 {
            roundCorners(of: &pixels, width: pixelWidth, height: pixelHeight,
                         radius: min(radius, Double(min(pixelWidth, pixelHeight)) / 2))
        }
        return PlatformImage(pixelWidth: pixelWidth, pixelHeight: pixelHeight, pixels: pixels)
    }

    /// The variant as encoded bytes for WinUI to decode (a BitmapImage), at the size `variant` would give it: `bytes`
    /// are what `image` was decoded from. No corners: a host that wants them rounded clips the image, or asks for a
    /// `cornerRadius` and gets pixels. nil only for an empty image.
    static func encodedVariant(_ bytes: Data, of image: DecodedImage, targetWidth: ImageLength?) -> PlatformImage? {
        guard let size = variantSize(of: image, targetWidth: targetWidth) else {
            return nil
        }
        return PlatformImage(pixelWidth: size.width, pixelHeight: size.height, encoded: bytes,
                             decodeWidth: size.width < image.width ? size.width : nil)
    }

    /// A variant's size: `image`'s, scaled down so its width is at most `targetWidth` (never up; the height scales
    /// proportionally, rounded as on Apple platforms). A side that rounds to nothing (a long thin strip) leaves the
    /// image at its own size, as Apple platforms and Android return their source (`isFallback`). nil for an empty
    /// image.
    private static func variantSize(of image: DecodedImage, targetWidth: ImageLength?)
        -> (width: Int, height: Int, isFallback: Bool)? {
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
        guard Int(width) > 0, Int(height) > 0 else {
            return (image.width, image.height, true)
        }
        return (Int(width), Int(height), false)
    }

    // MARK: - Pixels

    /// `image` scaled to `width` x `height` by WIC's Fant scaler, or nil.
    private static func scaled(_ image: DecodedImage, width: Int, height: Int) -> [UInt8]? {
        return image.pixels.withUnsafeBufferPointer { buffer -> [UInt8]? in
            WIC.withFactory { factory in
                var bitmap: UnsafeMutablePointer<IWICBitmap>?
                var format = WIC.premultipliedBGRA
                // The bitmap keeps a copy of the pixels.
                guard factory.pointee.lpVtbl.pointee.CreateBitmapFromMemory!(
                        factory, UINT(image.width), UINT(image.height), &format, UINT(image.width * 4),
                        UINT(buffer.count), UnsafeMutablePointer(mutating: buffer.baseAddress), &bitmap) >= 0,
                      let bitmap else {
                    return nil
                }
                defer {
                    WIC.release(bitmap)
                }
                var scaler: UnsafeMutablePointer<IWICBitmapScaler>?
                guard factory.pointee.lpVtbl.pointee.CreateBitmapScaler!(factory, &scaler) >= 0, let scaler else {
                    return nil
                }
                defer {
                    WIC.release(scaler)
                }
                guard scaler.pointee.lpVtbl.pointee.Initialize!(scaler, WIC.source(bitmap), UINT(width), UINT(height),
                                                                 WICBitmapInterpolationModeFant) >= 0 else {
                    return nil
                }
                return WIC.copyPixels(WIC.source(scaler), width: width, height: height)
            }
        }
    }

    /// The `width` x `height` pixels turned upright for the EXIF `orientation` (1-8): mirrored and rotated as
    /// orientations 2-8 ask, the sides swapped for 5-8. The same image for 1 or a value out of range.
    static func oriented(_ pixels: [UInt8], width: Int, height: Int, orientation: Int) -> DecodedImage {
        guard (2...8).contains(orientation) else {
            return DecodedImage(width: width, height: height, pixels: pixels)
        }
        let swapsSides = orientation >= 5
        let outWidth = swapsSides ? height : width
        let outHeight = swapsSides ? width : height
        var turned = [UInt8](repeating: 0, count: pixels.count)
        pixels.withUnsafeBytes { source in
            turned.withUnsafeMutableBytes { destination in
                let from = source.bindMemory(to: UInt32.self)
                let to = destination.bindMemory(to: UInt32.self)
                for y in 0..<outHeight {
                    for x in 0..<outWidth {
                        // The source pixel each output pixel shows.
                        let (sourceX, sourceY): (Int, Int)
                        switch orientation {
                        case 2: (sourceX, sourceY) = (width - 1 - x, y)                // mirrored left to right
                        case 3: (sourceX, sourceY) = (width - 1 - x, height - 1 - y)   // turned half a turn
                        case 4: (sourceX, sourceY) = (x, height - 1 - y)               // mirrored top to bottom
                        case 5: (sourceX, sourceY) = (y, x)                            // mirrored on the diagonal
                        case 6: (sourceX, sourceY) = (y, height - 1 - x)               // turned a quarter clockwise
                        case 7: (sourceX, sourceY) = (width - 1 - y, height - 1 - x)   // mirrored on the other diagonal
                        default: (sourceX, sourceY) = (width - 1 - y, x)               // 8: a quarter counterclockwise
                        }
                        to[y * outWidth + x] = from[sourceY * width + sourceX]
                    }
                }
            }
        }
        return DecodedImage(width: outWidth, height: outHeight, pixels: turned)
    }

    // Scale the pixels outside the rounded rectangle by their coverage: 0 well outside each corner's circle, 1
    // inside it, a linear ramp across the one-pixel edge (antialiasing, as CoreGraphics' clip gives). Premultiplied,
    // so all four channels scale.
    private static func roundCorners(of pixels: inout [UInt8], width: Int, height: Int, radius: Double) {
        guard radius > 0 else {
            return
        }
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
                let start = (y * width + x) * 4
                for channel in start..<(start + 4) {
                    pixels[channel] = UInt8((Double(pixels[channel]) * coverage).rounded())
                }
            }
        }
    }

    private static func unpremultiplied(_ value: UInt8, _ alpha: UInt8) -> UInt8 {
        guard alpha > 0 else {
            return 0
        }
        return UInt8(min(255, (Int(value) * 255 + Int(alpha) / 2) / Int(alpha)))
    }

    private static func premultiplied(_ value: UInt8, _ alpha: UInt8) -> UInt8 {
        return UInt8((Int(value) * Int(alpha) + 127) / 255)
    }
}

/// WIC through its C interfaces.
enum WIC {
    // CLSID_WICImagingFactory and IID_IWICImagingFactory, by value: the SDK declares them extern, and which library
    // defines them differs between SDKs.
    static let factoryClass = GUID(Data1: 0xCACA_F262, Data2: 0x9370, Data3: 0x4615,
                                   Data4: (0xA1, 0x3B, 0x9F, 0x55, 0x39, 0xDA, 0x4C, 0x0A))
    static let factoryInterface = GUID(Data1: 0xEC5E_C8A9, Data2: 0xC395, Data3: 0x4314,
                                       Data4: (0x9C, 0x77, 0x54, 0xD7, 0xA9, 0x35, 0xFF, 0x70))
    /// GUID_WICPixelFormat32bppPBGRA: premultiplied BGRA, 8 bits a channel.
    static let premultipliedBGRA = GUID(Data1: 0x6FDD_C324, Data2: 0x4E03, Data3: 0x4BFE,
                                        Data4: (0xB1, 0x85, 0x3D, 0x77, 0x76, 0x8D, 0xC9, 0x10))

    /// Runs `body` with a new imaging factory, on this thread in the multithreaded apartment (unless the thread is
    /// already in one: then in that), and releases the factory after. nil when no factory can be made.
    static func withFactory<Result>(_ body: (UnsafeMutablePointer<IWICImagingFactory>) -> Result?) -> Result? {
        let initialized = CoInitializeEx(nil, DWORD(COINIT_MULTITHREADED.rawValue))
        defer {
            // S_OK and S_FALSE are balanced; RPC_E_CHANGED_MODE (a single-threaded apartment) took no reference.
            if initialized >= 0 {
                CoUninitialize()
            }
        }
        var factoryClass = factoryClass
        var factoryInterface = factoryInterface
        var made: LPVOID?
        guard CoCreateInstance(&factoryClass, nil, DWORD(CLSCTX_INPROC_SERVER.rawValue), &factoryInterface, &made) >= 0,
              let made else {
            return nil
        }
        let factory = made.assumingMemoryBound(to: IWICImagingFactory.self)
        defer {
            release(factory)
        }
        return body(factory)
    }

    /// Runs `body` with a factory and the first frame of the image `data` holds (read in place, during the call), or
    /// returns nil when no codec reads it.
    static func withFirstFrame<Result>(of data: Data,
                                       _ body: (UnsafeMutablePointer<IWICImagingFactory>,
                                                UnsafeMutablePointer<IWICBitmapFrameDecode>) -> Result?) -> Result? {
        guard !data.isEmpty, data.count <= Int(UInt32.max) else {
            return nil
        }
        return data.withUnsafeBytes { raw -> Result? in
            guard let base = raw.baseAddress else {
                return nil
            }
            return withFactory { factory in
                var stream: UnsafeMutablePointer<IWICStream>?
                guard factory.pointee.lpVtbl.pointee.CreateStream!(factory, &stream) >= 0, let stream else {
                    return nil
                }
                defer {
                    release(stream)
                }
                let bytes = UnsafeMutablePointer(mutating: base.assumingMemoryBound(to: UInt8.self))
                guard stream.pointee.lpVtbl.pointee.InitializeFromMemory!(stream, bytes, DWORD(raw.count)) >= 0 else {
                    return nil
                }
                var decoder: UnsafeMutablePointer<IWICBitmapDecoder>?
                guard factory.pointee.lpVtbl.pointee.CreateDecoderFromStream!(
                        factory, UnsafeMutablePointer<IStream>(OpaquePointer(stream)), nil,
                        WICDecodeMetadataCacheOnDemand, &decoder) >= 0,
                      let decoder else {
                    return nil
                }
                defer {
                    release(decoder)
                }
                var frame: UnsafeMutablePointer<IWICBitmapFrameDecode>?
                guard decoder.pointee.lpVtbl.pointee.GetFrame!(decoder, 0, &frame) >= 0, let frame else {
                    return nil
                }
                defer {
                    release(frame)
                }
                return body(factory, frame)
            }
        }
    }

    /// The `width` x `height` pixels of `source` (32 bits a pixel), rows of width x 4 bytes, or nil.
    static func copyPixels(_ source: UnsafeMutablePointer<IWICBitmapSource>, width: Int, height: Int) -> [UInt8]? {
        let rowBytes = width * 4
        let (count, overflow) = rowBytes.multipliedReportingOverflow(by: height)
        guard width > 0, height > 0, !overflow, count <= Int(UInt32.max) else {
            return nil
        }
        var pixels = [UInt8](repeating: 0, count: count)
        let copied = pixels.withUnsafeMutableBufferPointer { buffer in
            source.pointee.lpVtbl.pointee.CopyPixels!(source, nil, UINT(rowBytes), UINT(count), buffer.baseAddress)
        }
        return copied >= 0 ? pixels : nil
    }

    /// A WIC object as the IWICBitmapSource it also is (a frame, a converter, a scaler, a bitmap): their interfaces
    /// begin with IWICBitmapSource's methods.
    static func source<Interface>(_ object: UnsafeMutablePointer<Interface>) -> UnsafeMutablePointer<IWICBitmapSource> {
        return UnsafeMutablePointer<IWICBitmapSource>(OpaquePointer(object))
    }

    /// Releases a COM object through IUnknown, which every interface begins with.
    static func release<Interface>(_ object: UnsafeMutablePointer<Interface>) {
        let unknown = UnsafeMutablePointer<IUnknown>(OpaquePointer(object))
        _ = unknown.pointee.lpVtbl.pointee.Release!(unknown)
    }
}

#endif
