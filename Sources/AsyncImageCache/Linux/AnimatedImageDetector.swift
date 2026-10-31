// Sources/AsyncImageCache/Linux/AnimatedImageDetector.swift
//
// Whether transport bytes hold a multi-frame (animated) image. The Apple engine asks ImageIO for the frame count
// (CGImageSourceGetCount > 1); Linux has no equally cheap decoder-level count (GdkPixbufAnimation decodes the
// frames), so this sniffs the container header, as the Android port does (AnimatedImageDetector.kt, the same
// walkers). It is cheaper than a decode, gives the same observable result, and is covered by the shared fixtures.
//
// Detected containers: animated GIF (more than one image descriptor), APNG (an `acTL` chunk before `IDAT`), and
// animated WebP (a `VP8X` chunk with the ANIM flag, or an `ANIM` chunk). Everything else - static GIF/PNG/WebP,
// JPEG, HEIC - reports false. All walkers are bounds-checked and stop (returning what they know) on malformed
// input.

enum AnimatedImageDetector {

    static func isAnimated(_ d: UnsafeRawBufferPointer) -> Bool {
        return isAnimatedGif(d) || isAnimatedPng(d) || isAnimatedWebp(d)
    }

    // MARK: - GIF: walk the block stream and stop the moment a second image descriptor (0x2C) appears.

    private static func isAnimatedGif(_ d: UnsafeRawBufferPointer) -> Bool {
        guard d.count >= 13, startsWith(d, Array("GIF8".utf8)), d[4] == 0x37 || d[4] == 0x39, d[5] == 0x61 else {
            return false
        }
        // The Logical Screen Descriptor is 7 bytes (offsets 6...12); its packed field is at offset 10.
        let packed = Int(d[10])
        var i = 13
        if packed & 0x80 != 0 {
            i += 3 * (1 << ((packed & 0x07) + 1))   // skip the Global Color Table
        }
        var frames = 0
        while i < d.count {
            switch d[i] {
            case 0x2C:   // Image Descriptor
                frames += 1
                if frames > 1 {
                    return true
                }
                guard i + 10 <= d.count else {
                    return false
                }
                let imagePacked = Int(d[i + 9])
                i += 10
                if imagePacked & 0x80 != 0 {
                    i += 3 * (1 << ((imagePacked & 0x07) + 1))   // skip the Local Color Table
                }
                guard i < d.count else {
                    return false
                }
                i += 1   // LZW minimum code size
                guard let next = skipGifSubBlocks(d, from: i) else {
                    return false
                }
                i = next
            case 0x21:   // Extension: 0x21 + label, then sub-blocks
                guard let next = skipGifSubBlocks(d, from: i + 2) else {
                    return false
                }
                i = next
            default:     // 0x3B (Trailer) or unrecognized: no second frame found
                return false
            }
        }
        return false
    }

    // Skip a run of GIF sub-blocks (each: 1 length byte + that many data bytes), ending at a 0 length byte.
    // Returns the offset just past the terminator, or nil if the stream runs out first.
    private static func skipGifSubBlocks(_ d: UnsafeRawBufferPointer, from start: Int) -> Int? {
        var i = start
        while i < d.count {
            let length = Int(d[i])
            i += 1
            if length == 0 {
                return i
            }
            i += length
        }
        return nil
    }

    // MARK: - APNG: an `acTL` (animation control) chunk that appears BEFORE the first `IDAT`.

    private static let pngSignature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]

    private static func isAnimatedPng(_ d: UnsafeRawBufferPointer) -> Bool {
        guard startsWith(d, pngSignature) else {
            return false
        }
        var i = 8
        while i + 8 <= d.count {
            let length = readUInt32BigEndian(d, at: i)
            switch fourCC(d, at: i + 4) {
            case "acTL":
                return true
            case "IDAT":
                return false   // acTL must precede the image data
            default:
                i += 12 + length   // length + type + data + CRC
            }
        }
        return false
    }

    // MARK: - WebP: a `VP8X` chunk with the ANIM flag set (bit 1), or a standalone `ANIM` chunk.

    private static func isAnimatedWebp(_ d: UnsafeRawBufferPointer) -> Bool {
        guard d.count >= 16, startsWith(d, Array("RIFF".utf8)), fourCC(d, at: 8) == "WEBP" else {
            return false
        }
        var i = 12
        while i + 8 <= d.count {
            let size = readUInt32LittleEndian(d, at: i + 4)
            switch fourCC(d, at: i) {
            case "ANIM":
                return true
            case "VP8X":
                if i + 8 < d.count, d[i + 8] & 0x02 != 0 {
                    return true
                }
            default:
                break
            }
            i += 8 + size + (size & 1)   // RIFF chunks are padded to an even byte boundary
        }
        return false
    }

    // MARK: - Byte helpers (offsets are Int, 64-bit: a 32-bit length added to one cannot overflow)

    private static func startsWith(_ d: UnsafeRawBufferPointer, _ prefix: [UInt8]) -> Bool {
        guard d.count >= prefix.count else {
            return false
        }
        for (index, byte) in prefix.enumerated() where d[index] != byte {
            return false
        }
        return true
    }

    private static func fourCC(_ d: UnsafeRawBufferPointer, at offset: Int) -> String {
        guard offset + 4 <= d.count else {
            return ""
        }
        return String(decoding: d[offset..<(offset + 4)], as: UTF8.self)
    }

    private static func readUInt32BigEndian(_ d: UnsafeRawBufferPointer, at o: Int) -> Int {
        return Int(d[o]) << 24 | Int(d[o + 1]) << 16 | Int(d[o + 2]) << 8 | Int(d[o + 3])
    }

    private static func readUInt32LittleEndian(_ d: UnsafeRawBufferPointer, at o: Int) -> Int {
        return Int(d[o]) | Int(d[o + 1]) << 8 | Int(d[o + 2]) << 16 | Int(d[o + 3]) << 24
    }
}
