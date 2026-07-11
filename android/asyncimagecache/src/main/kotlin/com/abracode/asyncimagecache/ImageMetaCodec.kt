// ImageMetaCodec.kt
//
// The sidecar-metadata codec. Android app storage has no dependable extended attributes, so the Swift package's
// three xattrs (pixel size, animated flag, placeholder grid) are combined into one small versioned binary blob
// written to a `<hash>.meta` file alongside the cached bytes (see DiskCache, Stage D). The per-field PAYLOADS
// mirror the Swift xattr payloads exactly - two Int32 for the size, one byte for the animated flag, a dimension
// byte plus N*N*4 RGBA for the grid - so the on-disk semantics match the reference.
//
// Presence is tri-state, exactly as the independent xattrs were: a field can be present (known) or absent
// (triggering the header fallback in DiskCache). This file is pure logic - no android.* import, JVM-testable.
//
// Layout (little-endian):
//   [0]      magic   = 0xAC
//   [1]      version = 0x01
//   [2]      flags   = bit0 hasSize | bit1 animatedKnown | bit2 animatedValue | bit3 hasPlaceholder
//   if hasSize:        int32 width, int32 height              (8 bytes)
//   if hasPlaceholder: uint8 dimension, then dimension*dimension*4 RGBA bytes

package com.abracode.asyncimagecache

/** A decode-free natural pixel size. Pure value type so the codec and disk tier stay JVM-testable. */
internal data class PixelSize(val width: Int, val height: Int)

/**
 * The combined per-file metadata. Each field is nullable to preserve the Swift "attribute absent" semantics:
 * a null `pixelSize`/`animated` means "unknown" (DiskCache falls back to reading the image header and repairs
 * the meta), and a null `placeholder` means no grid was stored.
 */
internal data class ImageMeta(
    val pixelSize: PixelSize?,
    val animated: Boolean?,
    val placeholder: ImagePlaceholder?,
)

internal object ImageMetaCodec {

    private const val MAGIC = 0xAC.toByte()
    private const val VERSION = 0x01.toByte()

    private const val FLAG_HAS_SIZE = 0x01
    private const val FLAG_ANIMATED_KNOWN = 0x02
    private const val FLAG_ANIMATED_VALUE = 0x04
    private const val FLAG_HAS_PLACEHOLDER = 0x08

    private const val HEADER_SIZE = 3

    /** Serialize a metadata record. Invalid sub-fields are simply omitted, mirroring the Swift write guards. */
    fun encode(meta: ImageMeta): ByteArray {
        var flags = 0
        val body = ArrayList<Byte>(HEADER_SIZE + 8)

        // Size: only when both dimensions are positive (mirrors Swift writePixelSize `size.width/height > 0`).
        val size = meta.pixelSize
        if (size != null && size.width > 0 && size.height > 0) {
            flags = flags or FLAG_HAS_SIZE
            appendInt32(body, size.width)
            appendInt32(body, size.height)
        }

        // Placeholder: only a well-formed grid within the clamp (mirrors Swift writePlaceholder guard).
        val placeholder = meta.placeholder
        if (placeholder != null &&
            placeholder.dimension in 1..ImagePlaceholderConfig.MAX_GRID_DIMENSION &&
            placeholder.cells.size == placeholder.dimension * placeholder.dimension
        ) {
            flags = flags or FLAG_HAS_PLACEHOLDER
            body.add(placeholder.dimension.toByte())
            for (c in placeholder.cells) {
                body.add(c.red.toByte()); body.add(c.green.toByte())
                body.add(c.blue.toByte()); body.add(c.alpha.toByte())
            }
        }

        // Animated: stored purely in flags. Written even when false, so a reader can tell "known not animated"
        // from "unknown" (absent), which is what triggers the header-count fallback in DiskCache.
        val animated = meta.animated
        if (animated != null) {
            flags = flags or FLAG_ANIMATED_KNOWN
            if (animated) flags = flags or FLAG_ANIMATED_VALUE
        }

        val out = ByteArray(HEADER_SIZE + body.size)
        out[0] = MAGIC
        out[1] = VERSION
        out[2] = flags.toByte()
        for (i in body.indices) {
            out[HEADER_SIZE + i] = body[i]
        }
        return out
    }

    /**
     * Parse a metadata blob, or null if the header is missing/unrecognized. Individual fields are validated
     * defensively: a corrupt or truncated field is dropped (returned as absent) rather than misread, and a
     * placeholder outside the security clamp is rejected while the size/animated fields are still returned.
     */
    fun decode(bytes: ByteArray): ImageMeta? {
        if (bytes.size < HEADER_SIZE || bytes[0] != MAGIC || bytes[1] != VERSION) {
            return null
        }
        val flags = bytes[2].toInt() and 0xFF
        var offset = HEADER_SIZE

        var pixelSize: PixelSize? = null
        if (flags and FLAG_HAS_SIZE != 0) {
            if (offset + 8 > bytes.size) {
                return null   // declared but truncated: the record is corrupt.
            }
            val width = readInt32(bytes, offset)
            val height = readInt32(bytes, offset + 4)
            offset += 8
            if (width > 0 && height > 0) {
                pixelSize = PixelSize(width, height)
            }
        }

        var placeholder: ImagePlaceholder? = null
        if (flags and FLAG_HAS_PLACEHOLDER != 0) {
            placeholder = decodePlaceholder(bytes, offset)
        }

        val animated: Boolean? = if (flags and FLAG_ANIMATED_KNOWN != 0) {
            flags and FLAG_ANIMATED_VALUE != 0
        } else {
            null
        }

        return ImageMeta(pixelSize = pixelSize, animated = animated, placeholder = placeholder)
    }

    private fun decodePlaceholder(bytes: ByteArray, start: Int): ImagePlaceholder? {
        if (start >= bytes.size) {
            return null
        }
        val dimension = bytes[start].toInt() and 0xFF
        if (dimension < 1 || dimension > ImagePlaceholderConfig.MAX_GRID_DIMENSION) {
            return null
        }
        val cellCount = dimension * dimension
        val payloadStart = start + 1
        if (payloadStart + cellCount * 4 > bytes.size) {
            return null
        }
        val cells = ArrayList<ImageColor>(cellCount)
        var o = payloadStart
        repeat(cellCount) {
            cells.add(
                ImageColor(
                    red = bytes[o].toInt() and 0xFF,
                    green = bytes[o + 1].toInt() and 0xFF,
                    blue = bytes[o + 2].toInt() and 0xFF,
                    alpha = bytes[o + 3].toInt() and 0xFF,
                )
            )
            o += 4
        }
        return ImagePlaceholder(dimension = dimension, cells = cells)
    }

    private fun appendInt32(out: MutableList<Byte>, value: Int) {
        out.add((value and 0xFF).toByte())
        out.add(((value ushr 8) and 0xFF).toByte())
        out.add(((value ushr 16) and 0xFF).toByte())
        out.add(((value ushr 24) and 0xFF).toByte())
    }

    private fun readInt32(bytes: ByteArray, offset: Int): Int {
        return (bytes[offset].toInt() and 0xFF) or
            ((bytes[offset + 1].toInt() and 0xFF) shl 8) or
            ((bytes[offset + 2].toInt() and 0xFF) shl 16) or
            ((bytes[offset + 3].toInt() and 0xFF) shl 24)
    }
}
