// AnimatedImageDetectorTest.kt - JVM tests for the container-header sniffing, using minimal hand-built GIF /
// APNG / WebP byte streams. This is the trickiest parity logic (it replaces Swift's decoder frame count), so it
// is exercised directly on the JVM; the instrumented suite and Stage F fixtures then confirm it against real
// platform-encoded images.

package com.abracode.asyncimagecache

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class AnimatedImageDetectorTest {

    // --- GIF ---

    private fun gif(frames: Int): ByteArray {
        val out = ArrayList<Byte>()
        "GIF89a".forEach { out.add(it.code.toByte()) }
        // Logical Screen Descriptor: 1x1, no global color table.
        out.addAll(listOf(1, 0, 1, 0, 0, 0, 0).map { it.toByte() })
        repeat(frames) {
            out.add(0x2C.toByte())                                   // image separator
            out.addAll(listOf(0, 0, 0, 0, 1, 0, 1, 0, 0).map { it.toByte() })  // descriptor (no LCT)
            out.add(0x02.toByte())                                   // LZW minimum code size
            out.add(0x00.toByte())                                   // empty sub-block terminator
        }
        out.add(0x3B.toByte())                                       // trailer
        return out.toByteArray()
    }

    @Test fun staticGifIsNotAnimated() = assertFalse(AnimatedImageDetector.isAnimated(gif(frames = 1)))

    @Test fun animatedGifIsAnimated() {
        assertTrue(AnimatedImageDetector.isAnimated(gif(frames = 2)))
        assertTrue(AnimatedImageDetector.isAnimated(gif(frames = 5)))
    }

    // --- PNG / APNG ---

    private fun chunk(type: String, data: ByteArray): ByteArray {
        val len = data.size
        val out = ArrayList<Byte>()
        out.add(((len ushr 24) and 0xFF).toByte())
        out.add(((len ushr 16) and 0xFF).toByte())
        out.add(((len ushr 8) and 0xFF).toByte())
        out.add((len and 0xFF).toByte())
        type.forEach { out.add(it.code.toByte()) }
        data.forEach { out.add(it) }
        repeat(4) { out.add(0) }   // CRC (ignored by the sniffer)
        return out.toByteArray()
    }

    private fun png(animated: Boolean): ByteArray {
        val out = ArrayList<Byte>()
        listOf(0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A).forEach { out.add(it.toByte()) }
        out.addAll(chunk("IHDR", ByteArray(13)).toList())
        if (animated) out.addAll(chunk("acTL", ByteArray(8)).toList())
        out.addAll(chunk("IDAT", ByteArray(0)).toList())
        return out.toByteArray()
    }

    @Test fun staticPngIsNotAnimated() = assertFalse(AnimatedImageDetector.isAnimated(png(animated = false)))

    @Test fun apngIsAnimated() = assertTrue(AnimatedImageDetector.isAnimated(png(animated = true)))

    @Test fun acTlAfterIdatIsNotAnimated() {
        // An `acTL` that appears AFTER `IDAT` must not count (the sniffer stops at IDAT). Not a real APNG, but
        // guards the ordering rule.
        val out = ArrayList<Byte>()
        listOf(0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A).forEach { out.add(it.toByte()) }
        out.addAll(chunk("IHDR", ByteArray(13)).toList())
        out.addAll(chunk("IDAT", ByteArray(0)).toList())
        out.addAll(chunk("acTL", ByteArray(8)).toList())
        assertFalse(AnimatedImageDetector.isAnimated(out.toByteArray()))
    }

    // --- WebP ---

    private fun riffChunk(fourCC: String, data: ByteArray): ByteArray {
        val out = ArrayList<Byte>()
        fourCC.forEach { out.add(it.code.toByte()) }
        val len = data.size
        out.add((len and 0xFF).toByte())
        out.add(((len ushr 8) and 0xFF).toByte())
        out.add(((len ushr 16) and 0xFF).toByte())
        out.add(((len ushr 24) and 0xFF).toByte())
        data.forEach { out.add(it) }
        if (len and 1 == 1) out.add(0)   // pad to even
        return out.toByteArray()
    }

    private fun webp(chunks: ByteArray): ByteArray {
        val out = ArrayList<Byte>()
        "RIFF".forEach { out.add(it.code.toByte()) }
        val riffSize = 4 + chunks.size
        out.add((riffSize and 0xFF).toByte())
        out.add(((riffSize ushr 8) and 0xFF).toByte())
        out.add(((riffSize ushr 16) and 0xFF).toByte())
        out.add(((riffSize ushr 24) and 0xFF).toByte())
        "WEBP".forEach { out.add(it.code.toByte()) }
        chunks.forEach { out.add(it) }
        return out.toByteArray()
    }

    @Test fun animatedWebpViaVp8xFlag() {
        val vp8xData = ByteArray(10).also { it[0] = 0x02 }   // flags byte: ANIM bit set
        assertTrue(AnimatedImageDetector.isAnimated(webp(riffChunk("VP8X", vp8xData))))
    }

    @Test fun animatedWebpViaAnimChunk() {
        val vp8xData = ByteArray(10)                          // flags = 0, but an ANIM chunk follows
        val chunks = riffChunk("VP8X", vp8xData) + riffChunk("ANIM", ByteArray(6))
        assertTrue(AnimatedImageDetector.isAnimated(webp(chunks)))
    }

    @Test fun staticWebpIsNotAnimated() {
        // A simple lossy WebP: a single "VP8 " chunk, no VP8X/ANIM.
        assertFalse(AnimatedImageDetector.isAnimated(webp(riffChunk("VP8 ", ByteArray(16)))))
    }

    @Test fun staticWebpWithVp8xNoAnimFlag() {
        val vp8xData = ByteArray(10)   // flags = 0
        assertFalse(AnimatedImageDetector.isAnimated(webp(riffChunk("VP8X", vp8xData))))
    }

    // --- Non-container / junk ---

    @Test fun jpegAndJunkAreNotAnimated() {
        assertFalse(AnimatedImageDetector.isAnimated(byteArrayOf(0xFF.toByte(), 0xD8.toByte(), 0xFF.toByte())))
        assertFalse(AnimatedImageDetector.isAnimated(ByteArray(0)))
        assertFalse(AnimatedImageDetector.isAnimated(byteArrayOf(1, 2, 3, 4, 5)))
    }
}
