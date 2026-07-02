// Demo/App/GIFPlayer.swift
//
// A small SwiftUI animated-GIF player, demonstrating the "playback is a consumer concern" design: the library
// caches + hands back the ORIGINAL transport bytes (store.cachedOriginalBytes) and tells you the source is
// animated (store.isAnimated); the app decodes the frames + per-frame delays with CGImageSource and steps
// through them. This is the same CGImageSource/timer pattern you would drive with a CADisplayLink in a
// production UIKit view; a Timer in .common mode keeps it simple and still animates during scrolling.
//
// Note the division of labor: CachedImage still shows the flattened FIRST frame (off-main, cached, box
// reserved). Only when the user taps Play does the app layer this frame-stepping player on top - the cache
// never decodes or stores every frame.

import SwiftUI
import CoreGraphics
import ImageIO
import AsyncImageCache

// CGImage is not Sendable; the demo owns the guarantee that the decoded frames are produced once off-main and
// then only touched on the main actor, so carry them across the hop in an unchecked-Sendable box.
private struct DecodedGIF: @unchecked Sendable {
    let frames: [CGImage]
    let delays: [Double]
}

@MainActor
final class GIFPlaybackController: ObservableObject {
    @Published private(set) var currentFrame: CGImage?
    @Published private(set) var frameCount = 0

    private var frames: [CGImage] = []
    private var delays: [Double] = []
    private var index = 0
    private var timer: Timer?
    private var didLoad = false

    /// Decode the frames off-main (once), then start stepping. Idempotent.
    func loadIfNeeded(data: Data) {
        guard !didLoad else {
            return
        }
        didLoad = true
        Task { [weak self] in
            let decoded = await Task.detached { GIFPlaybackController.decode(data) }.value
            guard let self else {
                return
            }
            self.frames = decoded.frames
            self.delays = decoded.delays
            self.frameCount = decoded.frames.count
            self.currentFrame = decoded.frames.first
            self.scheduleNext()
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func scheduleNext() {
        timer?.invalidate()
        guard frames.count > 1 else {
            return
        }
        let delay = max(0.02, delays[index])
        // .common mode so playback continues while the user scrolls the list (default mode pauses in tracking).
        let next = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.advance() }
        }
        RunLoop.main.add(next, forMode: .common)
        timer = next
    }

    private func advance() {
        guard frames.count > 1 else {
            return
        }
        index = (index + 1) % frames.count
        currentFrame = frames[index]
        scheduleNext()
    }

    nonisolated private static func decode(_ data: Data) -> DecodedGIF {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            return DecodedGIF(frames: [], delays: [])
        }
        let count = CGImageSourceGetCount(source)
        var frames: [CGImage] = []
        var delays: [Double] = []
        for i in 0..<count {
            guard let frame = CGImageSourceCreateImageAtIndex(source, i, nil) else {
                continue
            }
            frames.append(frame)
            delays.append(frameDelay(source, i))
        }
        return DecodedGIF(frames: frames, delays: delays)
    }

    // Per-frame delay from the GIF metadata; prefer the unclamped value, and floor tiny/zero delays the way
    // browsers do (a 0 s frame would otherwise spin the timer).
    nonisolated private static func frameDelay(_ source: CGImageSource, _ index: Int) -> Double {
        guard let props = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any],
              let gif = props[kCGImagePropertyGIFDictionary] as? [CFString: Any] else {
            return 0.1
        }
        if let unclamped = gif[kCGImagePropertyGIFUnclampedDelayTime] as? Double, unclamped > 0 {
            return unclamped
        }
        if let clamped = gif[kCGImagePropertyGIFDelayTime] as? Double, clamped > 0 {
            return clamped
        }
        return 0.1
    }
}

/// Plays the animated source at `url`, sourcing its bytes from the cache (store.cachedOriginalBytes), loading
/// through the store first if needed. Reserves the box from `intrinsicSize` so swapping in/out of playback
/// does not reflow the row.
struct AnimatedGIFView: View {
    let url: URL
    let store: ImageStore
    let intrinsicSize: CGSize?

    @StateObject private var controller = GIFPlaybackController()

    private var aspect: CGFloat {
        intrinsicSize.map { $0.width / max($0.height, 1) } ?? 1
    }

    var body: some View {
        Color.clear
            .aspectRatio(aspect, contentMode: .fit)
            .overlay {
                if let frame = controller.currentFrame {
                    Image(decorative: frame, scale: 1)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    Rectangle().fill(Color.gray.opacity(0.12))
                }
            }
            .task {
                // The intended consumer pattern: ask the cache for the source bytes; load through the store if
                // they are not resident (e.g. evicted under the tiny budget), then fall back to the file.
                var bytes = store.cachedOriginalBytes(for: url)?.data
                if bytes == nil {
                    _ = await withCheckedContinuation { (c: CheckedContinuation<PlatformImage?, Never>) in
                        store.load(ImageRequest(url: url)) { c.resume(returning: $0) }
                    }
                    bytes = store.cachedOriginalBytes(for: url)?.data ?? (try? Data(contentsOf: url))
                }
                if let bytes {
                    controller.loadIfNeeded(data: bytes)
                }
            }
            .onDisappear {
                controller.stop()
            }
    }
}
