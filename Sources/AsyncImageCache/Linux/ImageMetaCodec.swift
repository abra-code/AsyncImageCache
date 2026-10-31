// Sources/AsyncImageCache/Linux/ImageMetaCodec.swift
//
// The sidecar-metadata codec. The Apple disk cache keeps three extended attributes on each cached file (pixel
// size, animated flag, placeholder grid); Linux cache folders are not dependable for them (user extended
// attributes are missing on NFS home folders and some other filesystems, and need a "user." name), so they are
// combined into one small versioned blob in a `<hash>.meta` file beside the bytes - the Android port's format,
// byte for byte (ImageMetaCodec.kt). The field payloads mirror the Apple attributes.
//
// Presence is tri-state, as the separate attributes are: a field is present (known) or absent (which triggers
// the header fallback in DiskCache).
//
// Layout (little-endian):
//   [0]      magic   = 0xAC
//   [1]      version = 0x01
//   [2]      flags   = bit0 hasSize | bit1 animatedKnown | bit2 animatedValue | bit3 hasPlaceholder
//   if hasSize:        int32 width, int32 height              (8 bytes)
//   if hasPlaceholder: uint8 dimension, then dimension*dimension*4 RGBA bytes

/// The combined per-file metadata; a nil field is unknown.
struct ImageMeta: Equatable {
    var pixelSize: (width: Int, height: Int)?
    var animated: Bool?
    var placeholder: ImagePlaceholder?

    static func == (a: ImageMeta, b: ImageMeta) -> Bool {
        return a.pixelSize?.width == b.pixelSize?.width && a.pixelSize?.height == b.pixelSize?.height
            && a.animated == b.animated && a.placeholder == b.placeholder
    }
}

enum ImageMetaCodec {

    private static let magic: UInt8 = 0xAC
    private static let version: UInt8 = 0x01

    private static let hasSize: UInt8 = 0x01
    private static let animatedKnown: UInt8 = 0x02
    private static let animatedValue: UInt8 = 0x04
    private static let hasPlaceholder: UInt8 = 0x08

    private static let headerSize = 3

    /// The record's bytes. Invalid fields are left out, as the Apple attribute writes skip them.
    static func encode(_ meta: ImageMeta) -> [UInt8] {
        var flags: UInt8 = 0
        var body: [UInt8] = []

        // Size: only when both dimensions are positive and fit an Int32.
        if let size = meta.pixelSize, size.width > 0, size.height > 0,
           size.width <= Int(Int32.max), size.height <= Int(Int32.max) {
            flags |= hasSize
            appendInt32(&body, size.width)
            appendInt32(&body, size.height)
        }

        // Placeholder: only a well-formed grid within the clamp.
        if let placeholder = meta.placeholder, (1...ImagePlaceholderConfig.maxGridDimension).contains(placeholder.dimension),
           placeholder.cells.count == placeholder.dimension * placeholder.dimension {
            flags |= hasPlaceholder
            body.append(UInt8(placeholder.dimension))
            for c in placeholder.cells {
                body.append(c.red); body.append(c.green); body.append(c.blue); body.append(c.alpha)
            }
        }

        // Animated: in the flags only, written even when false, so "known not animated" differs from unknown.
        if let animated = meta.animated {
            flags |= animatedKnown
            if animated {
                flags |= animatedValue
            }
        }

        return [magic, version, flags] + body
    }

    /// The record, or nil when the header is missing or unrecognized, or a declared size is cut short. A corrupt
    /// placeholder is dropped (returned as absent) while the other fields are still returned.
    static func decode(_ bytes: [UInt8]) -> ImageMeta? {
        guard bytes.count >= headerSize, bytes[0] == magic, bytes[1] == version else {
            return nil
        }
        let flags = bytes[2]
        var offset = headerSize
        var meta = ImageMeta()

        if flags & hasSize != 0 {
            guard offset + 8 <= bytes.count else {
                return nil
            }
            let width = readInt32(bytes, offset)
            let height = readInt32(bytes, offset + 4)
            offset += 8
            if width > 0, height > 0 {
                meta.pixelSize = (width, height)
            }
        }
        if flags & hasPlaceholder != 0 {
            meta.placeholder = decodePlaceholder(bytes, from: offset)
        }
        if flags & animatedKnown != 0 {
            meta.animated = flags & animatedValue != 0
        }
        return meta
    }

    private static func decodePlaceholder(_ bytes: [UInt8], from start: Int) -> ImagePlaceholder? {
        guard start < bytes.count else {
            return nil
        }
        let dimension = Int(bytes[start])
        guard (1...ImagePlaceholderConfig.maxGridDimension).contains(dimension) else {
            return nil
        }
        let cellCount = dimension * dimension
        let payload = start + 1
        guard payload + cellCount * 4 <= bytes.count else {
            return nil
        }
        var cells: [ImageColor] = []
        cells.reserveCapacity(cellCount)
        for i in 0..<cellCount {
            let o = payload + i * 4
            cells.append(ImageColor(red: bytes[o], green: bytes[o + 1], blue: bytes[o + 2], alpha: bytes[o + 3]))
        }
        return ImagePlaceholder(dimension: dimension, cells: cells)
    }

    private static func appendInt32(_ out: inout [UInt8], _ value: Int) {
        let v = UInt32(truncatingIfNeeded: value)
        out.append(UInt8(v & 0xFF)); out.append(UInt8(v >> 8 & 0xFF))
        out.append(UInt8(v >> 16 & 0xFF)); out.append(UInt8(v >> 24 & 0xFF))
    }

    private static func readInt32(_ bytes: [UInt8], _ o: Int) -> Int {
        let v = UInt32(bytes[o]) | UInt32(bytes[o + 1]) << 8 | UInt32(bytes[o + 2]) << 16 | UInt32(bytes[o + 3]) << 24
        return Int(Int32(bitPattern: v))
    }
}
