// Sources/AsyncImageCache/ImageRequest.swift
//
// A ready-to-draw image variant is identified by the full request: the source URL plus the presentation
// transforms (width cap + corner radius). Two requests for the same URL but different `targetWidth` are
// distinct variants that share one on-disk original.

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
#if canImport(CoreGraphics)
import CoreGraphics

/// The type of the request's lengths: CGFloat on Apple platforms (layout math is CGFloat there), Double on
/// Linux, which has no CoreGraphics. A distinct name, so it never competes with another module's CGFloat.
public typealias ImageLength = CGFloat
#else
public typealias ImageLength = Double
#endif

public struct ImageRequest: Hashable, Sendable {
    public let url: URL
    /// Cap width in pixels; the height scales proportionally. `nil` keeps the natural size. Taken as ImageLength
    /// (CGFloat on Apple platforms, where layout math is CGFloat) for caller convenience, but QUANTIZED to whole
    /// pixels for caching - see below.
    public let targetWidth: ImageLength?
    /// Corner radius in pixels; `0` = no rounding. Also quantized to whole pixels for the variant key.
    public let cornerRadius: ImageLength

    public init(url: URL, targetWidth: ImageLength? = nil, cornerRadius: ImageLength = 0) {
        self.url = url
        // NaN reads as "not set". It never equals itself, so a request holding it could not find its own entry in
        // the store's in-flight table, and its completion would never run.
        self.targetWidth = targetWidth?.isNaN == true ? nil : targetWidth
        self.cornerRadius = cornerRadius.isNaN ? 0 : cornerRadius
    }

    // The transforms QUANTIZED to whole pixels. Fractional widths from layout (e.g. 342.6667) would
    // otherwise mint a distinct cache variant per sub-pixel value - wasted decodes + memory, and a bloated
    // key. The store scales to these same values, so the cached bitmap matches its key exactly.
    var quantizedTargetWidth: Int? {
        targetWidth.flatMap(Self.wholePixels).map { max(1, $0) }
    }
    var quantizedCornerRadius: Int {
        max(0, Self.wholePixels(cornerRadius) ?? 0)
    }

    // A length as whole pixels; nil for NaN or an infinity. Lengths can come from a document, and Int() traps on those
    // and on what does not fit. The cap is larger than any image, so it still means "no limit".
    private static func wholePixels(_ length: ImageLength) -> Int? {
        guard length.isFinite else {
            return nil
        }
        let largest = ImageLength(1 << 24)
        return Int(min(max(length.rounded(), -largest), largest))
    }

    /// A stable string key for the exact ready-to-draw variant (used as the in-memory cache key).
    var variantKey: String {
        let width = quantizedTargetWidth.map(String.init) ?? "nil"
        return "\(url.absoluteString)|w=\(width)|r=\(quantizedCornerRadius)"
    }
}
