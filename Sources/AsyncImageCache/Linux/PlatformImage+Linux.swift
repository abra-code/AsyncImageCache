// Sources/AsyncImageCache/Linux/PlatformImage+Linux.swift
//
// PlatformImage on Linux: a GdkTexture, which a GTK program shows with a GtkPicture (gtk_picture_set_paintable)
// or draws in a snapshot. Textures are immutable and their reference count is atomic, so one made on the work
// queue can be handed to the main thread as it is. The texture is an OpaquePointer rather than a GdkTexture type,
// so a program that sees GTK through a module of its own never meets two imports of the same C type.

import CAsyncImageCacheGtk

/// A ready-to-draw image: a GdkTexture this object holds one reference to, released with the last Swift
/// reference. A widget showing the texture takes its own reference, so it may outlive this object.
public final class PlatformImage: @unchecked Sendable {
    /// The GdkTexture (a `GdkTexture *`).
    public let texture: OpaquePointer

    init(adopting texture: OpaquePointer) {
        self.texture = texture
    }

    /// The width in pixels.
    public var pixelWidth: Int {
        Int(gdk_texture_get_width(texture))
    }

    /// The height in pixels.
    public var pixelHeight: Int {
        Int(gdk_texture_get_height(texture))
    }

    deinit {
        g_object_unref(UnsafeMutableRawPointer(texture))
    }
}

/// A size in pixels, the Linux counterpart of the CGSize the Apple API returns.
public struct ImageSize: Hashable, Sendable {
    public var width: ImageLength
    public var height: ImageLength

    public init(width: ImageLength, height: ImageLength) {
        self.width = width
        self.height = height
    }
}
