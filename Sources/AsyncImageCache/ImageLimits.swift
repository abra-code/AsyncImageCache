// Sources/AsyncImageCache/ImageLimits.swift
//
// The largest image this package decodes, checked against the size a file declares. A file names its own size, and
// an image can come from anywhere: on Apple platforms NSImage takes SVG and PDF, whose size is any number the file
// says, and rasterizing one traps, raises an exception Swift cannot catch, or runs for many seconds. A small PNG can
// declare enough pixels to exhaust memory on any platform. Well past any photo or panorama.

enum ImageLimits {
    /// The longest side, in pixels.
    static let longestSide: ImageLength = 65536
    /// The most pixels: 16384 x 16384, about 1 GB decoded, and 2 to 4 GB at the peak of loading one.
    static let mostPixels: ImageLength = 268_435_456

    /// Whether an image declaring this size may be decoded. A size of zero is not refused here: whether such an image
    /// is one is for the decoder to judge.
    static func accepts(width: ImageLength, height: ImageLength) -> Bool {
        width <= longestSide && height <= longestSide && width * height <= mostPixels
    }
}
