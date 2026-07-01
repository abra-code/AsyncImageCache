// Sources/AsyncImageCache/ImageRequest.swift
//
// A ready-to-draw image variant is identified by the full request: the source URL plus the presentation
// transforms (width cap + corner radius). Two requests for the same URL but different `targetWidth` are
// distinct variants that share one on-disk original.

import Foundation
import CoreGraphics

public struct ImageRequest: Hashable, Sendable {
    public let url: URL
    /// Cap width in pixels; the height scales proportionally. `nil` keeps the natural size. Taken as CGFloat
    /// for caller convenience (layout math is CGFloat), but QUANTIZED to whole pixels for caching - see below.
    public let targetWidth: CGFloat?
    /// Corner radius in pixels; `0` = no rounding. Also quantized to whole pixels for the variant key.
    public let cornerRadius: CGFloat

    public init(url: URL, targetWidth: CGFloat? = nil, cornerRadius: CGFloat = 0) {
        self.url = url
        self.targetWidth = targetWidth
        self.cornerRadius = cornerRadius
    }

    // The transforms QUANTIZED to whole pixels. Fractional CGFloat widths from layout (e.g. 342.6667) would
    // otherwise mint a distinct cache variant per sub-pixel value - wasted decodes + memory, and a bloated
    // key. The store scales to these same values, so the cached bitmap matches its key exactly.
    var quantizedTargetWidth: Int? {
        targetWidth.map { max(1, Int($0.rounded())) }
    }
    var quantizedCornerRadius: Int {
        max(0, Int(cornerRadius.rounded()))
    }

    /// A stable string key for the exact ready-to-draw variant (used as the in-memory cache key).
    var variantKey: String {
        let width = quantizedTargetWidth.map(String.init) ?? "nil"
        return "\(url.absoluteString)|w=\(width)|r=\(quantizedCornerRadius)"
    }
}
