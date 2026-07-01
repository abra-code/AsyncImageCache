// Sources/AsyncImageCache/CachedImage.swift
//
// A SwiftUI image view backed by the ImageStore cache. Named for the CACHE (not asynchronicity) to avoid
// confusion with SwiftUI's AsyncImage and app-level AsyncImage views: the point of this view is that the
// bytes come from ImageStore's memory + disk cache, decoded/scaled OFF the main thread.
//
// Layout is reserved UP FRONT from an intrinsic size hint (or, once loaded, the cache's known natural size),
// so an image whose dimensions are known - e.g. a chat attachment with server-provided width/height - never
// reflows the transcript when its pixels arrive. While loading, a placeholder fills the reserved box.

import SwiftUI

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

public struct CachedImage: View {
    private let url: URL?
    private let intrinsicSize: CGSize?
    private let cornerRadius: CGFloat
    private let contentMode: ContentMode
    private let maxPixelWidth: CGFloat?
    private let store: ImageStore

    @State private var image: PlatformImage?
    @State private var resolvedSize: CGSize?

    /// - Parameters:
    ///   - url: the image source (nil renders just the placeholder).
    ///   - intrinsicSize: the source's natural size, if known ahead of load (e.g. from server metadata). When
    ///     provided the view reserves that aspect immediately, so the picture hydrates with ZERO reflow.
    ///   - cornerRadius: rounded-corner clip (a GPU clip, so it costs no CPU mask).
    ///   - contentMode: how the image fills the reserved box (default `.fill`).
    ///   - maxPixelWidth: cap the DECODED width in pixels (the image is downscaled off-main to this width) to
    ///     bound memory for large sources; nil keeps the natural resolution.
    ///   - store: the backing cache (default `.shared`).
    public init(url: URL?,
                intrinsicSize: CGSize? = nil,
                cornerRadius: CGFloat = 0,
                contentMode: ContentMode = .fill,
                maxPixelWidth: CGFloat? = nil,
                store: ImageStore = .shared) {
        self.url = url
        self.intrinsicSize = intrinsicSize
        self.cornerRadius = cornerRadius
        self.contentMode = contentMode
        self.maxPixelWidth = maxPixelWidth
        self.store = store
    }

    // The aspect used to reserve layout: the caller's hint, else the cache's known natural size, else a
    // neutral 4:3 until we learn better.
    private var aspectRatio: CGFloat {
        // Prefer the caller's hint; else the size resolved after loading; else the cache's known natural size
        // - a cheap sync read that survives relaunch via the on-disk xattr - so a cached image reserves its
        // exact box up front with no reflow on hydration. Neutral 4:3 only until anything is known.
        let size = intrinsicSize ?? resolvedSize ?? url.flatMap { store.cachedPixelSize(for: $0) }
        if let size, size.width > 0, size.height > 0 {
            return size.width / size.height
        }
        return 4.0 / 3.0
    }

    public var body: some View {
        Color.clear
            .aspectRatio(aspectRatio, contentMode: .fit)
            .overlay {
                if let image {
                    imageView(image)
                        .resizable()
                        .aspectRatio(contentMode: contentMode)
                } else {
                    Rectangle().fill(Color.gray.opacity(0.12))
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .task(id: url) {
                await load()
            }
    }

    private func imageView(_ image: PlatformImage) -> Image {
        #if canImport(UIKit)
        return Image(uiImage: image)
        #else
        return Image(nsImage: image)
        #endif
    }

    @MainActor
    private func load() async {
        guard let url else {
            image = nil
            resolvedSize = nil
            return
        }
        let request = ImageRequest(url: url, targetWidth: maxPixelWidth, cornerRadius: 0)
        if let cached = store.cachedImage(for: request) {
            image = cached
            resolvedSize = store.cachedPixelSize(for: url)
            return
        }
        let loaded = await withCheckedContinuation { continuation in
            store.load(request) { continuation.resume(returning: $0) }
        }
        // The view may have been reused for a different url while we awaited; task(id:) cancels + restarts on
        // url change, but guard anyway so a stale result never clobbers a newer one.
        guard self.url == url else {
            return
        }
        image = loaded
        resolvedSize = store.cachedPixelSize(for: url)
    }
}
