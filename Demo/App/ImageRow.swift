// Demo/App/ImageRow.swift
//
// One catalog entry: a caption (with local/remote and animated badges) plus the image. Passing intrinsicSize
// means the box is reserved at the correct aspect immediately (no reflow when the pixels arrive).
//
// Two display modes:
//   - normal: a CachedImage, which shows the placeholder grid while loading, then the (flattened first-frame)
//     image.
//   - "show placeholders only": the cached blurry preview rendered statically via store.placeholderImage, so
//     the placeholder is plainly visible for anything loaded once (flat gray until then).
//
// The animated badge and the placeholder both become known only AFTER the image has loaded (they are derived
// from the pixels), so the row runs a small load task and refreshes once it completes.

import SwiftUI
import AsyncImageCache

struct ImageRow: View {
    let item: DemoImage
    let maxPixelWidth: CGFloat?
    let store: ImageStore
    let showPlaceholderOnly: Bool
    let reloadToken: UUID

    @State private var isAnimated = false
    @State private var playing = false
    @State private var loadTick = 0   // bumped after the load completes, to refresh the derived views

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(item.title)
                    .font(.subheadline.weight(.semibold))
                Spacer()
                if isAnimated {
                    badge("animated", .orange)
                }
                badge(item.isRemote ? "remote" : "local", item.isRemote ? .blue : .green)
            }

            content
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

            if let size = item.intrinsicSize {
                Text("intrinsic \(Int(size.width)) x \(Int(size.height))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .task(id: "\(item.id)-\(reloadToken)") {
            isAnimated = store.isAnimated(for: item.url)
            // Ensure the image passes through the cache so the derived metadata (animated flag, placeholder)
            // becomes known. Deduplicated with CachedImage's own load, so it is not a second fetch.
            _ = await withCheckedContinuation { (continuation: CheckedContinuation<PlatformImage?, Never>) in
                store.load(ImageRequest(url: item.url, targetWidth: maxPixelWidth)) {
                    continuation.resume(returning: $0)
                }
            }
            isAnimated = store.isAnimated(for: item.url)
            loadTick += 1
        }
    }

    @ViewBuilder
    private var content: some View {
        if showPlaceholderOnly {
            placeholderOnly
        } else if isAnimated {
            animatedContent
        } else {
            cachedImageView
        }
    }

    private var cachedImageView: some View {
        CachedImage(url: item.url,
                    intrinsicSize: item.intrinsicSize,
                    cornerRadius: 14,
                    contentMode: .fill,
                    maxPixelWidth: maxPixelWidth,
                    store: store)
    }

    // For animated sources: CachedImage shows the flattened first frame (the library's default); tapping Play
    // layers the consumer-driven frame player on top. Demonstrates that animation lives in the app, not the cache.
    private var animatedContent: some View {
        ZStack(alignment: .bottomTrailing) {
            if playing {
                AnimatedGIFView(url: item.url, store: store, intrinsicSize: item.intrinsicSize)
            } else {
                cachedImageView
            }
            Button {
                playing.toggle()
            } label: {
                Image(systemName: playing ? "pause.circle.fill" : "play.circle.fill")
                    .font(.title)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.white, .black.opacity(0.4))
            }
            .buttonStyle(.plain)
            .padding(10)
        }
    }

    // The reserved box filled with the cached blurry preview, or a labeled gray box if none exists yet. Reads
    // `loadTick` so it refreshes once the load task has populated the placeholder.
    @ViewBuilder
    private var placeholderOnly: some View {
        let aspect = item.intrinsicSize.map { $0.width / max($0.height, 1) } ?? 4.0 / 3.0
        Color.clear
            .aspectRatio(aspect, contentMode: .fit)
            .overlay {
                if loadTick >= 0, let preview = store.placeholderImage(for: item.url) {
                    previewImage(preview)
                        .resizable()
                        .interpolation(.high)
                } else {
                    ZStack {
                        Rectangle().fill(Color.gray.opacity(0.12))
                        Text("no placeholder yet\nload once first")
                            .multilineTextAlignment(.center)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
    }

    private func previewImage(_ image: PlatformImage) -> Image {
        #if canImport(UIKit)
        return Image(uiImage: image)
        #else
        return Image(nsImage: image)
        #endif
    }

    private func badge(_ text: String, _ color: Color) -> some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color.opacity(0.15), in: Capsule())
    }
}
