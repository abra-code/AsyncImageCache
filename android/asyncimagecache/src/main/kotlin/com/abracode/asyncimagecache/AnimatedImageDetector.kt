// AnimatedImageDetector.kt
//
// Whether transport bytes hold a multi-frame (animated) image. The Swift package asks ImageIO for the frame
// count (CGImageSourceGetCount > 1); Android has no equally cheap decoder-level count, so this is a deliberate
// divergence (section 8 of the porting plan): container-header sniffing. It is cheaper than a decode, gives the
// same observable result, and - being pure byte logic with no android.* import - is fully JVM-testable and
// covered by the cross-platform fixtures.
//
// Detected containers: animated GIF (>1 image descriptor), APNG (an `acTL` chunk before `IDAT`), and animated
// WebP (a `VP8X` chunk with the ANIM flag, or an `ANIM` chunk). Everything else - static GIF/PNG/WebP, JPEG,
// HEIC - reports false. All walkers are bounds-checked and bail out (returning what they know) on malformed
// input rather than throwing.

package com.abracode.asyncimagecache

internal object AnimatedImageDetector {

    fun isAnimated(data: ByteArray): Boolean {
        return isAnimatedGif(data) || isAnimatedPng(data) || isAnimatedWebp(data)
    }

    // --- GIF: walk the block stream and stop the moment a second image descriptor (0x2C) appears. ---

    private fun isAnimatedGif(d: ByteArray): Boolean {
        if (d.size < 13) return false
        // Signature "GIF87a" or "GIF89a".
        if (d[0] != 'G'.b || d[1] != 'I'.b || d[2] != 'F'.b || d[3] != '8'.b ||
            (d[4] != '7'.b && d[4] != '9'.b) || d[5] != 'a'.b
        ) {
            return false
        }
        // Logical Screen Descriptor is 7 bytes (offset 6..12); its packed field is at offset 10.
        val packed = d[10].toInt() and 0xFF
        var i = 13
        if (packed and 0x80 != 0) {
            i += 3 * (1 shl ((packed and 0x07) + 1))   // skip the Global Color Table
        }
        var frames = 0
        while (i < d.size) {
            when (d[i].toInt() and 0xFF) {
                0x2C -> {   // Image Descriptor
                    frames++
                    if (frames > 1) return true
                    if (i + 10 > d.size) return false
                    val imgPacked = d[i + 9].toInt() and 0xFF
                    i += 10
                    if (imgPacked and 0x80 != 0) {
                        i += 3 * (1 shl ((imgPacked and 0x07) + 1))   // skip the Local Color Table
                    }
                    if (i >= d.size) return false
                    i += 1   // LZW minimum code size
                    i = skipGifSubBlocks(d, i)
                    if (i < 0) return false
                }
                0x21 -> {   // Extension: 0x21 + label, then sub-blocks
                    i += 2
                    i = skipGifSubBlocks(d, i)
                    if (i < 0) return false
                }
                0x3B -> return false   // Trailer: no second frame found
                else -> return false   // Unrecognized: stop scanning
            }
        }
        return false
    }

    // Skip a run of GIF sub-blocks (each: 1 length byte + that many data bytes), ending at a 0 length byte.
    // Returns the offset just past the terminator, or -1 if the stream runs out first.
    private fun skipGifSubBlocks(d: ByteArray, start: Int): Int {
        var i = start
        while (i < d.size) {
            val len = d[i].toInt() and 0xFF
            i += 1
            if (len == 0) {
                return i
            }
            i += len
        }
        return -1
    }

    // --- APNG: an `acTL` (animation control) chunk that appears BEFORE the first `IDAT`. ---

    private val PNG_SIGNATURE = byteArrayOf(
        0x89.toByte(), 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,
    )

    private fun isAnimatedPng(d: ByteArray): Boolean {
        if (d.size < 8 || !startsWith(d, PNG_SIGNATURE)) {
            return false
        }
        var i = 8
        while (i + 8 <= d.size) {
            val length = readUInt32BE(d, i)
            if (length < 0) return false
            val type = fourCC(d, i + 4)
            when (type) {
                "acTL" -> return true
                "IDAT" -> return false   // acTL must precede the image data
            }
            val next = i.toLong() + 8L + length + 4L   // length + type + data + CRC
            if (next > Int.MAX_VALUE) return false
            i = next.toInt()
        }
        return false
    }

    // --- WebP: a `VP8X` chunk with the ANIM flag set (bit 1), or a standalone `ANIM` chunk. ---

    private fun isAnimatedWebp(d: ByteArray): Boolean {
        if (d.size < 16) return false
        if (d[0] != 'R'.b || d[1] != 'I'.b || d[2] != 'F'.b || d[3] != 'F'.b) return false
        if (d[8] != 'W'.b || d[9] != 'E'.b || d[10] != 'B'.b || d[11] != 'P'.b) return false
        var i = 12
        while (i + 8 <= d.size) {
            val fourCC = fourCC(d, i)
            val size = readUInt32LE(d, i + 4)
            if (size < 0) return false
            when (fourCC) {
                "ANIM" -> return true
                "VP8X" -> {
                    if (i + 8 < d.size && (d[i + 8].toInt() and 0x02) != 0) {
                        return true
                    }
                }
            }
            // RIFF chunks are padded to an even byte boundary.
            val padded = size + (size and 1L)
            val next = i.toLong() + 8L + padded
            if (next > Int.MAX_VALUE) return false
            i = next.toInt()
        }
        return false
    }

    // --- Small byte helpers ---

    private val Char.b: Byte get() = code.toByte()

    private fun startsWith(d: ByteArray, prefix: ByteArray): Boolean {
        if (d.size < prefix.size) return false
        for (i in prefix.indices) {
            if (d[i] != prefix[i]) return false
        }
        return true
    }

    private fun fourCC(d: ByteArray, offset: Int): String {
        if (offset + 4 > d.size) return ""
        return String(charArrayOf(
            (d[offset].toInt() and 0xFF).toChar(),
            (d[offset + 1].toInt() and 0xFF).toChar(),
            (d[offset + 2].toInt() and 0xFF).toChar(),
            (d[offset + 3].toInt() and 0xFF).toChar(),
        ))
    }

    private fun readUInt32BE(d: ByteArray, o: Int): Long {
        return ((d[o].toLong() and 0xFF) shl 24) or
            ((d[o + 1].toLong() and 0xFF) shl 16) or
            ((d[o + 2].toLong() and 0xFF) shl 8) or
            (d[o + 3].toLong() and 0xFF)
    }

    private fun readUInt32LE(d: ByteArray, o: Int): Long {
        return (d[o].toLong() and 0xFF) or
            ((d[o + 1].toLong() and 0xFF) shl 8) or
            ((d[o + 2].toLong() and 0xFF) shl 16) or
            ((d[o + 3].toLong() and 0xFF) shl 24)
    }
}
