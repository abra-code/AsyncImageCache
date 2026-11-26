// Sources/AsyncImageCache/Windows/WinRTImage+Windows.swift
//
// The image a WinUI 3 program shows, made on the main thread (the UI thread a WinUI program drains the main dispatch
// queue on), which WinUI requires; every element that shows the image shares that one object:
//   - from an image's encoded bytes (a variant without rounded corners): a WinUI BitmapImage, which decodes them on
//     WinUI's own threads, at the variant's width (DecodePixelWidth), the EXIF orientation applied by WinUI, an
//     animated image showing its first frame (AutoPlay off). WinUI then keeps one copy of the pixels.
//   - from pixels (a variant with rounded corners baked in, a placeholder grid), in two steps: on the work queue the
//     pixels go into a Windows.Graphics.Imaging.SoftwareBitmap (premultiplied BGRA8), a Windows type not tied to a
//     thread, and the array is freed; on the main thread a WinUI SoftwareBitmapSource takes the bitmap
//     (SetBitmapAsync), and the SoftwareBitmap is released after. WinUI keeps two copies of those pixels.
// WinUI is reached only at run time, through WinRT activation: the package links no part of the Windows App SDK, and a
// program that has not started it (a test) gets no source, only the bitmap.
//
// The interfaces are the C declarations of CAsyncImageCacheWindows.h. Every reference taken here is released here,
// except the ones handed to the caller (a WinRTObject).

#if os(Windows)

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
import CAsyncImageCacheWindows
import Dispatch
import Synchronization
import WinSDK

/// A WinRT or COM object this holds one reference to, released with the last Swift reference: on the thread that drops
/// it, or for a WinUI object (thread-affine) on the main thread.
final class WinRTObject: @unchecked Sendable {
    let pointer: UnsafeMutableRawPointer
    private let releasesOnMain: Bool

    init(adopting pointer: UnsafeMutableRawPointer, releasesOnMain: Bool = false) {
        self.pointer = pointer
        self.releasesOnMain = releasesOnMain
    }

    deinit {
        guard releasesOnMain else {
            WinRT.release(pointer)
            return
        }
        // A WinUI object belongs to its UI thread; the cache may drop it on any thread.
        let raw = UncheckedSendableBox(pointer)
        DispatchQueue.main.async {
            WinRT.release(raw.value)
        }
    }
}

enum WinRT {
    // IIDs (CAsyncImageCacheWindows.h names where they come from).
    static let softwareBitmapFactory = GUID(Data1: 0xC99F_EB69, Data2: 0x2D62, Data3: 0x4D47,
                                            Data4: (0xA6, 0xB3, 0x4F, 0xDB, 0x6A, 0x07, 0xFD, 0xF8))
    static let memoryBuffer = GUID(Data1: 0xFBC4_DD2A, Data2: 0x245B, Data3: 0x11E4,
                                   Data4: (0xAF, 0x98, 0x68, 0x94, 0x23, 0x26, 0x0C, 0xF8))
    static let memoryBufferByteAccess = GUID(Data1: 0x5B0D_3235, Data2: 0x4DBA, Data3: 0x4D44,
                                             Data4: (0x86, 0x5E, 0x8F, 0x1D, 0x0E, 0x4F, 0xD0, 0x4D))
    static let closable = GUID(Data1: 0x30D5_A829, Data2: 0x7FA4, Data3: 0x4026,
                               Data4: (0x83, 0xBB, 0xD7, 0x5B, 0xAE, 0x4E, 0xA9, 0x9E))
    static let softwareBitmapSource = GUID(Data1: 0xA6AC_A802, Data2: 0x1F24, Data3: 0x5A1E,
                                           Data4: (0xBF, 0x08, 0x78, 0x1A, 0x85, 0xED, 0x55, 0x11))
    static let bitmapImage = GUID(Data1: 0x5CC2_9916, Data2: 0xA411, Data3: 0x5BC2,
                                  Data4: (0xA3, 0xC5, 0xA0, 0x0D, 0x99, 0xA5, 0x9D, 0xA8))
    static let bitmapSource = GUID(Data1: 0x8424_269D, Data2: 0x9B82, Data3: 0x534F,
                                   Data4: (0x8F, 0xEA, 0xAF, 0x5B, 0x5E, 0xF9, 0x6B, 0xF2))
    static let randomAccessStream = GUID(Data1: 0x905A_0FE1, Data2: 0xBC53, Data3: 0x11DF,
                                         Data4: (0x8C, 0x49, 0x00, 0x1E, 0x4F, 0xC6, 0x86, 0xDA))

    /// Keeps the process's multithreaded apartment alive once a work queue thread has made a WinRT object in it, so
    /// the object outlives that thread's CoUninitialize.
    private static let apartment: Mutex<Bool> = Mutex(false)

    /// `pixels` (premultiplied BGRA, rows of width x 4 bytes) as a new SoftwareBitmap, or nil. Any thread.
    static func makeSoftwareBitmap(_ pixels: [UInt8], width: Int, height: Int) -> WinRTObject? {
        guard width > 0, height > 0, width <= Int(Int32.max), height <= Int(Int32.max),
              pixels.count == width * height * 4 else {
            return nil
        }
        return inApartment {
            guard let factory: UnsafeMutablePointer<AICSoftwareBitmapFactory> =
                    activationFactory("Windows.Graphics.Imaging.SoftwareBitmap", softwareBitmapFactory) else {
                return nil
            }
            defer {
                release(factory)
            }
            var bitmap: UnsafeMutablePointer<AICSoftwareBitmap>?
            guard factory.pointee.lpVtbl.pointee.CreateWithAlpha!(factory, AIC_BITMAP_PIXEL_FORMAT_BGRA8, Int32(width),
                                                                  Int32(height), AIC_BITMAP_ALPHA_MODE_PREMULTIPLIED,
                                                                  &bitmap) >= 0,
                  let bitmap else {
                return nil
            }
            let object = WinRTObject(adopting: UnsafeMutableRawPointer(bitmap))
            let rowBytes = width * 4
            let written = withBytes(of: bitmap, mode: AIC_BITMAP_BUFFER_ACCESS_WRITE) { buffer, plane in
                guard Int(plane.Stride) >= rowBytes, Int(plane.StartIndex) >= 0,
                      Int(plane.StartIndex) + Int(plane.Stride) * (height - 1) + rowBytes <= buffer.count else {
                    return false
                }
                pixels.withUnsafeBytes { source in
                    for row in 0..<height {
                        let target = buffer.baseAddress! + Int(plane.StartIndex) + row * Int(plane.Stride)
                        target.copyMemory(from: source.baseAddress! + row * rowBytes, byteCount: rowBytes)
                    }
                }
                return true
            }
            return written == true ? object : nil
        }
    }

    /// The pixels of a SoftwareBitmap the store made (premultiplied BGRA, rows of width x 4 bytes), or nil. For tests.
    static func pixels(of bitmap: WinRTObject, width: Int, height: Int) -> [UInt8]? {
        let typed = bitmap.pointer.assumingMemoryBound(to: AICSoftwareBitmap.self)
        return inApartment {
            withBytes(of: typed, mode: AIC_BITMAP_BUFFER_ACCESS_READ) { buffer, plane -> [UInt8]? in
                let rowBytes = width * 4
                guard Int(plane.Stride) >= rowBytes, Int(plane.StartIndex) >= 0,
                      Int(plane.StartIndex) + Int(plane.Stride) * (height - 1) + rowBytes <= buffer.count else {
                    return nil
                }
                var pixels = [UInt8](repeating: 0, count: rowBytes * height)
                pixels.withUnsafeMutableBytes { target in
                    for row in 0..<height {
                        (target.baseAddress! + row * rowBytes).copyMemory(
                            from: buffer.baseAddress! + Int(plane.StartIndex) + row * Int(plane.Stride), byteCount: rowBytes)
                    }
                }
                return pixels
            } ?? nil
        }
    }

    /// A WinUI SoftwareBitmapSource showing `bitmap` (an IInspectable, released on the main thread), or nil when the
    /// program has no WinUI. Main thread only: a WinUI object is made on its UI thread.
    @MainActor
    static func makeImageSource(_ bitmap: WinRTObject) -> WinRTObject? {
        var made: UnsafeMutablePointer<IInspectable>?
        let activated = withString("Microsoft.UI.Xaml.Media.Imaging.SoftwareBitmapSource") { name in
            RoActivateInstance(name, &made)
        }
        guard activated >= 0, let made else {
            return nil
        }
        let object = WinRTObject(adopting: UnsafeMutableRawPointer(made), releasesOnMain: true)
        guard let source: UnsafeMutablePointer<AICSoftwareBitmapSource> = query(made, softwareBitmapSource) else {
            return nil
        }
        defer {
            release(source)
        }
        // The operation copies the bitmap into the source; it holds what it needs until it ends.
        var operation: UnsafeMutablePointer<IInspectable>?
        let typed = bitmap.pointer.assumingMemoryBound(to: AICSoftwareBitmap.self)
        guard source.pointee.lpVtbl.pointee.SetBitmapAsync!(source, typed, &operation) >= 0 else {
            return nil
        }
        if let operation {
            release(operation)
        }
        return object
    }

    /// A WinUI BitmapImage decoding `data` (an image's encoded bytes) to `decodeWidth` pixels wide when given (its
    /// height in proportion), else at its own size; showing an animated image's first frame. nil when the program has
    /// no WinUI or the bytes cannot be handed over. Main thread only: a WinUI object is made on its UI thread.
    @MainActor
    static func makeBitmapImage(_ data: Data, decodeWidth: Int?) -> WinRTObject? {
        guard !data.isEmpty, data.count <= Int(UINT32.max) else {
            return nil
        }
        var made: UnsafeMutablePointer<IInspectable>?
        let activated = withString("Microsoft.UI.Xaml.Media.Imaging.BitmapImage") { name in
            RoActivateInstance(name, &made)
        }
        guard activated >= 0, let made else {
            return nil
        }
        let object = WinRTObject(adopting: UnsafeMutableRawPointer(made), releasesOnMain: true)
        guard let image: UnsafeMutablePointer<AICBitmapImage> = query(made, bitmapImage) else {
            return nil
        }
        defer {
            release(image)
        }
        // Both before SetSource, which starts the decode.
        _ = image.pointee.lpVtbl.pointee.put_AutoPlay!(image, 0)
        if let decodeWidth, decodeWidth > 0, decodeWidth <= Int(Int32.max) {
            _ = image.pointee.lpVtbl.pointee.put_DecodePixelWidth!(image, Int32(decodeWidth))
        }
        guard let source: UnsafeMutablePointer<AICBitmapSource> = query(made, bitmapSource) else {
            return nil
        }
        defer {
            release(source)
        }
        // A copy of the bytes in a memory stream, which the image holds while it needs it.
        let memory = data.withUnsafeBytes { bytes in
            SHCreateMemStream(bytes.baseAddress?.assumingMemoryBound(to: BYTE.self), UINT(bytes.count))
        }
        guard let memory else {
            return nil
        }
        defer {
            release(memory)
        }
        var interface = randomAccessStream
        var stream: UnsafeMutableRawPointer?
        guard CreateRandomAccessStreamOverStream(memory, BSOS_DEFAULT, &interface, &stream) >= 0, let stream else {
            return nil
        }
        defer {
            release(stream)
        }
        let typed = stream.assumingMemoryBound(to: IInspectable.self)
        guard source.pointee.lpVtbl.pointee.SetSource!(source, typed) >= 0 else {
            return nil
        }
        return object
    }

    // MARK: - Helpers

    /// Runs `body` with the bytes of `bitmap`'s first plane, locked for `mode`, and that plane's layout; nil when the
    /// bytes cannot be reached. Closes and releases everything it took, which unlocks the bitmap.
    private static func withBytes<Result>(of bitmap: UnsafeMutablePointer<AICSoftwareBitmap>, mode: Int32,
                                          _ body: (UnsafeMutableRawBufferPointer, AICBitmapPlaneDescription) -> Result)
        -> Result? {
        var locked: UnsafeMutablePointer<AICBitmapBuffer>?
        guard bitmap.pointee.lpVtbl.pointee.LockBuffer!(bitmap, mode, &locked) >= 0, let locked else {
            return nil
        }
        defer {
            close(locked)
            release(locked)
        }
        var plane = AICBitmapPlaneDescription()
        guard locked.pointee.lpVtbl.pointee.GetPlaneDescription!(locked, 0, &plane) >= 0,
              let memory: UnsafeMutablePointer<AICMemoryBuffer> = query(locked, memoryBuffer) else {
            return nil
        }
        defer {
            release(memory)
        }
        var reference: UnsafeMutablePointer<AICMemoryBufferReference>?
        guard memory.pointee.lpVtbl.pointee.CreateReference!(memory, &reference) >= 0, let reference else {
            return nil
        }
        defer {
            close(reference)
            release(reference)
        }
        guard let access: UnsafeMutablePointer<AICMemoryBufferByteAccess> = query(reference, memoryBufferByteAccess) else {
            return nil
        }
        defer {
            release(access)
        }
        var bytes: UnsafeMutablePointer<BYTE>?
        var capacity: UINT32 = 0
        guard access.pointee.lpVtbl.pointee.GetBuffer!(access, &bytes, &capacity) >= 0, let bytes else {
            return nil
        }
        return body(UnsafeMutableRawBufferPointer(start: bytes, count: Int(capacity)), plane)
    }

    /// Runs `body` on this thread in the multithreaded apartment (unless the thread is in one already), keeping that
    /// apartment alive for the process from the first call on.
    private static func inApartment<Result>(_ body: () -> Result?) -> Result? {
        let initialized = CoInitializeEx(nil, DWORD(COINIT_MULTITHREADED.rawValue))
        defer {
            if initialized >= 0 {
                CoUninitialize()
            }
        }
        apartment.withLock { kept in
            if !kept {
                var cookie: CO_MTA_USAGE_COOKIE?
                kept = CoIncrementMTAUsage(&cookie) >= 0
            }
        }
        return body()
    }

    /// The activation factory of the runtime class `name` for the interface `iid`, or nil.
    private static func activationFactory<Interface>(_ name: String, _ iid: GUID) -> UnsafeMutablePointer<Interface>? {
        var interface = iid
        var factory: UnsafeMutableRawPointer?
        let found = withString(name) { RoGetActivationFactory($0, &interface, &factory) }
        guard found >= 0, let factory else {
            return nil
        }
        return factory.assumingMemoryBound(to: Interface.self)
    }

    /// `object` as the interface `iid` (a new reference), or nil.
    private static func query<Object, Interface>(_ object: UnsafeMutablePointer<Object>, _ iid: GUID)
        -> UnsafeMutablePointer<Interface>? {
        let unknown = UnsafeMutablePointer<IUnknown>(OpaquePointer(object))
        var interface = iid
        var result: UnsafeMutableRawPointer?
        guard unknown.pointee.lpVtbl.pointee.QueryInterface!(unknown, &interface, &result) >= 0, let result else {
            return nil
        }
        return result.assumingMemoryBound(to: Interface.self)
    }

    /// Closes `object` through IClosable (a buffer, a reference), when it is one.
    private static func close<Object>(_ object: UnsafeMutablePointer<Object>) {
        guard let closable: UnsafeMutablePointer<AICClosable> = query(object, closable) else {
            return
        }
        _ = closable.pointee.lpVtbl.pointee.Close!(closable)
        release(closable)
    }

    /// Calls `body` with `text` as an HSTRING, deleted after.
    private static func withString<Result>(_ text: String, _ body: (HSTRING?) -> Result) -> Result {
        let characters = Array(text.utf16)
        var string: HSTRING?
        _ = characters.withUnsafeBufferPointer { WindowsCreateString($0.baseAddress, UINT32($0.count), &string) }
        defer {
            WindowsDeleteString(string)
        }
        return body(string)
    }

    /// Releases a COM object through IUnknown.
    static func release<Object>(_ object: UnsafeMutablePointer<Object>) {
        release(UnsafeMutableRawPointer(object))
    }

    static func release(_ object: UnsafeMutableRawPointer) {
        let unknown = object.assumingMemoryBound(to: IUnknown.self)
        _ = unknown.pointee.lpVtbl.pointee.Release!(unknown)
    }
}

#endif
