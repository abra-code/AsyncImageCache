// Sources/AsyncImageCache/ImagePlaceholder.swift
//
// A tiny N x N grid of average colors - a cheap, dependency-free "blurhash-ish" preview shown while an image
// loads. It is computed once off-main, persisted in an extended attribute, and rendered by upscaling the NxN
// grid with bilinear interpolation (a soft gradient). Row 0 is the TOP of the image.

import Foundation

/// Internal, tweakable configuration for the placeholder grid. NOT part of the public API - callers get a
/// finished placeholder, not the knobs.
enum ImagePlaceholderConfig {
    /// The N of the N x N grid. 6 is a soft, clearly-a-placeholder preview; the cost is flat across sizes, so
    /// this is a purely aesthetic/storage tradeoff (N*N*4 bytes on disk).
    static let gridDimension = 6

    /// Upper bound on a grid dimension accepted when READING a stored attribute. A security clamp: a corrupt
    /// or foreign xattr cannot describe an oversized grid, and the payload length must be N*N*4.
    static let maxGridDimension = 16

    /// The largest placeholder payload we will read: maxN*maxN RGBA cells (dimension is derived from length).
    static var maxPayloadBytes: Int { maxGridDimension * maxGridDimension * 4 }
}

/// An N x N grid of average colors (row-major, row 0 = top of the image).
public struct ImagePlaceholder: Sendable, Equatable {
    public let dimension: Int
    public let cells: [ImageColor]

    public init(dimension: Int, cells: [ImageColor]) {
        self.dimension = dimension
        self.cells = cells
    }

    /// The average of all cells - a single dominant tint for consumers that just want one color.
    public var dominantColor: ImageColor {
        guard !cells.isEmpty else {
            return ImageColor(red: 0, green: 0, blue: 0, alpha: 0)
        }
        var r = 0, g = 0, b = 0, a = 0
        for c in cells {
            r += Int(c.red); g += Int(c.green); b += Int(c.blue); a += Int(c.alpha)
        }
        let n = cells.count
        return ImageColor(red: UInt8(r / n), green: UInt8(g / n), blue: UInt8(b / n), alpha: UInt8(a / n))
    }
}
