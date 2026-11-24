// Sources/AsyncImageCache/Windows/PlatformImage+Windows.swift
//
// PlatformImage on Windows: the image a WinUI 3 program shows, as a UIImage is on Apple platforms and a GdkTexture on
// Linux. Its pixels live in exactly one place at a time:
//   - decoded pixels (premultiplied BGRA), as the work queue makes the variant;
//   - then a Windows SoftwareBitmap, still on the work queue (WinRTImage+Windows.swift), the array freed;
//   - then, on the main thread, a WinUI SoftwareBitmapSource, the bitmap released. The store makes it as it delivers
//     the image, before any completion runs, so what the cache holds and hands out is that one source, shared by every
//     element that shows the image.
// The heavy work (fetch, decode, scale, corners, placeholder) stays on the work queue; the main thread only hands
// WinUI a ready bitmap, which WinUI requires to happen on its UI thread.

#if os(Windows)

import Synchronization

/// A ready-to-draw image of `pixelWidth` x `pixelHeight` pixels. Show it with `imageSource` on the main thread.
public final class PlatformImage: @unchecked Sendable {
    /// The width in pixels.
    public let pixelWidth: Int
    /// The height in pixels.
    public let pixelHeight: Int

    private enum Form {
        /// Premultiplied BGRA, rows of pixelWidth x 4 bytes.
        case pixels([UInt8])
        /// A Windows.Graphics.Imaging.SoftwareBitmap.
        case bitmap(WinRTObject)
        /// A Microsoft.UI.Xaml.Media.Imaging.SoftwareBitmapSource.
        case source(WinRTObject)
    }

    private let form: Mutex<Form>

    init(pixelWidth: Int, pixelHeight: Int, pixels: [UInt8]) {
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        form = Mutex(.pixels(pixels))
    }

    /// The image as a WinUI ImageSource: a borrowed `IInspectable *` of a Microsoft.UI.Xaml.Media.Imaging
    /// SoftwareBitmapSource, valid while this image lives. Every element showing the image may set it as its
    /// Image's Source. nil when the program has no WinUI (it has not started the Windows App SDK). Main thread
    /// only, the UI thread of a WinUI program, which must drain the main dispatch queue there.
    @MainActor
    public var imageSource: UnsafeMutableRawPointer? {
        form.withLock { form -> UnsafeMutableRawPointer? in
            let bitmap: WinRTObject
            switch form {
            case .source(let source):
                return source.pointer
            case .bitmap(let made):
                bitmap = made
            case .pixels(let pixels):
                // An image the work queue did not prepare (a placeholder grid): small, made here.
                guard let made = WinRT.makeSoftwareBitmap(pixels, width: pixelWidth, height: pixelHeight) else {
                    return nil
                }
                bitmap = made
                form = .bitmap(made)
            }
            guard let source = WinRT.makeImageSource(bitmap) else {
                return nil
            }
            form = .source(source)
            return source.pointer
        }
    }

    /// Moves the pixels into a SoftwareBitmap and frees the array, off the main thread; keeps the pixels when no
    /// SoftwareBitmap can be made. The store calls it on the work queue before it publishes the image.
    func prepareForDisplay() {
        form.withLock { form in
            guard case .pixels(let pixels) = form,
                  let bitmap = WinRT.makeSoftwareBitmap(pixels, width: pixelWidth, height: pixelHeight) else {
                return
            }
            form = .bitmap(bitmap)
        }
    }

    /// The pixels (premultiplied BGRA, rows of pixelWidth x 4 bytes) while the image still has them, as an array or
    /// in its SoftwareBitmap; nil once WinUI holds them. For tests.
    var pixelBytes: [UInt8]? {
        form.withLock { form -> [UInt8]? in
            switch form {
            case .pixels(let pixels):
                return pixels
            case .bitmap(let bitmap):
                return WinRT.pixels(of: bitmap, width: pixelWidth, height: pixelHeight)
            case .source:
                return nil
            }
        }
    }

    /// Whether the pixels are in a SoftwareBitmap (prepareForDisplay worked). For tests.
    var holdsBitmap: Bool {
        form.withLock { form in
            if case .bitmap = form {
                return true
            }
            return false
        }
    }
}

/// A size in pixels, the Windows counterpart of the CGSize the Apple API returns (as on Linux).
public struct ImageSize: Hashable, Sendable {
    public var width: ImageLength
    public var height: ImageLength

    public init(width: ImageLength, height: ImageLength) {
        self.width = width
        self.height = height
    }
}

/// A minimal escape hatch for moving a non-Sendable value (a caller's completion closure) across a thread hop.
/// The value is written once and read once; the component ensures no concurrent access, which is why
/// `@unchecked Sendable` is sound here. (The Apple and Linux counterparts are in PlatformImage.swift and
/// MainContext.swift.)
struct UncheckedSendableBox<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) {
        self.value = value
    }
}

#endif
