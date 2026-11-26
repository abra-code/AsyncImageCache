// Sources/AsyncImageCache/Windows/PlatformImage+Windows.swift
//
// PlatformImage on Windows: the image a WinUI 3 program shows, as a UIImage is on Apple platforms and a GdkTexture on
// Linux. It is one of two kinds, each held in one place at a time:
//   - a variant without rounded corners keeps the image's encoded bytes and its size; on the main thread a WinUI
//     BitmapImage takes them and decodes them on WinUI's threads at that size, and the bytes are dropped. WinUI then
//     holds one copy of the pixels.
//   - a variant with rounded corners (baked into its pixels) and a placeholder grid are decoded pixels (premultiplied
//     BGRA); on the work queue they move into a Windows SoftwareBitmap, the array freed, and on the main thread into a
//     WinUI SoftwareBitmapSource, the bitmap released (WinRTImage+Windows.swift).
// The store makes the WinUI object as it delivers the image, before any completion runs, so what the cache holds and
// hands out is that one object, shared by every element that shows the image. The fetch, the size, the placeholder and
// any corners are worked out on the work queue; the main thread only hands WinUI the bytes or a ready bitmap, which
// WinUI requires to happen on its UI thread.

#if os(Windows)

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
import Synchronization

/// A ready-to-draw image of `pixelWidth` x `pixelHeight` pixels. Show it with `imageSource` on the main thread.
public final class PlatformImage: @unchecked Sendable {
    /// The width in pixels.
    public let pixelWidth: Int
    /// The height in pixels.
    public let pixelHeight: Int

    private enum Form {
        /// The image's encoded bytes (a PNG, a JPEG...), shown `decodeWidth` pixels wide when given, else at their own
        /// size.
        case encoded(Data, decodeWidth: Int?)
        /// Premultiplied BGRA, rows of pixelWidth x 4 bytes.
        case pixels([UInt8])
        /// A Windows.Graphics.Imaging.SoftwareBitmap.
        case bitmap(WinRTObject)
        /// A Microsoft.UI.Xaml.Media.Imaging.SoftwareBitmapSource or BitmapImage.
        case source(WinRTObject)
    }

    private let form: Mutex<Form>

    init(pixelWidth: Int, pixelHeight: Int, pixels: [UInt8]) {
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        form = Mutex(.pixels(pixels))
    }

    /// An image WinUI decodes from `encoded` (bytes the work queue decoded once already, for the size), `pixelWidth`
    /// wide: `decodeWidth` is the width to decode to when smaller than the bytes' own, else nil.
    init(pixelWidth: Int, pixelHeight: Int, encoded: Data, decodeWidth: Int?) {
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        form = Mutex(.encoded(encoded, decodeWidth: decodeWidth))
    }

    /// The image as a WinUI ImageSource: a borrowed `IInspectable *` of a Microsoft.UI.Xaml.Media.Imaging
    /// BitmapImage or SoftwareBitmapSource, valid while this image lives. Every element showing the image may set it
    /// as its Image's Source. nil when the program has no WinUI (it has not started the Windows App SDK). Main thread
    /// only, the UI thread of a WinUI program, which must drain the main dispatch queue there.
    @MainActor
    public var imageSource: UnsafeMutableRawPointer? {
        // Encoded bytes go to WinUI outside the lock: BitmapImage's SetSource waits while WinUI reads them, and code
        // that runs on this thread meanwhile may ask for the same image.
        let encoded = form.withLock { form -> (Data, Int?)? in
            if case .encoded(let data, let decodeWidth) = form {
                return (data, decodeWidth)
            }
            return nil
        }
        if let (data, decodeWidth) = encoded {
            let made = WinRT.makeBitmapImage(data, decodeWidth: decodeWidth)
            return form.withLock { form -> UnsafeMutableRawPointer? in
                // A source made meanwhile wins; ours is dropped (released on the main thread).
                if case .source(let source) = form {
                    return source.pointer
                }
                guard let made else {
                    return nil
                }
                // The bytes are dropped here: WinUI holds the image now.
                form = .source(made)
                return made.pointer
            }
        }
        return form.withLock { form -> UnsafeMutableRawPointer? in
            let bitmap: WinRTObject
            switch form {
            case .source(let source):
                return source.pointer
            case .encoded:
                // Only while another call on this thread is handing the same bytes to WinUI.
                return nil
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
    /// in its SoftwareBitmap, or decoded from its bytes as WinUI would (upright, scaled to the image's width); nil once
    /// WinUI holds them. For tests.
    var pixelBytes: [UInt8]? {
        form.withLock { form -> [UInt8]? in
            switch form {
            case .encoded(let data, _):
                return ImageProcessing.decode(data).flatMap {
                    ImageProcessing.variant(from: $0, targetWidth: ImageLength(pixelWidth), cornerRadius: 0)?.pixelBytes
                }
            case .pixels(let pixels):
                return pixels
            case .bitmap(let bitmap):
                return WinRT.pixels(of: bitmap, width: pixelWidth, height: pixelHeight)
            case .source:
                return nil
            }
        }
    }

    /// Whether the image is encoded bytes WinUI is to decode. For tests.
    var holdsEncodedBytes: Bool {
        form.withLock { form in
            if case .encoded = form {
                return true
            }
            return false
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
