// DownloadLimitTest.kt - JVM unit tests for the capped body read behind ImageStore.downloadByteLimit.

package com.abracode.asyncimagecache

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertNull
import org.junit.Test
import java.io.ByteArrayInputStream
import java.io.InputStream

class DownloadLimitTest {

    private val body = ByteArray(200_000) { (it % 251).toByte() }

    @Test
    fun aBodyAtTheLimitIsReadWhole() {
        assertArrayEquals(body, ImageStore.readAtMost(ByteArrayInputStream(body), body.size.toLong()))
        assertArrayEquals(body, ImageStore.readAtMost(ByteArrayInputStream(body), Long.MAX_VALUE))
    }

    // A declared length only sizes the buffer: a wrong one changes nothing.
    @Test
    fun theDeclaredLengthOnlySizesTheBuffer() {
        for (expected in listOf(-1L, 1L, 10L, body.size.toLong(), body.size * 2L)) {
            assertArrayEquals("$expected", body, ImageStore.readAtMost(ByteArrayInputStream(body), body.size.toLong(), expected))
        }
        assertNull(ImageStore.readAtMost(ByteArrayInputStream(body), body.size - 1L, body.size - 1L))
    }

    @Test
    fun aBodyOneBytePastTheLimitIsRefused() {
        assertNull(ImageStore.readAtMost(ByteArrayInputStream(body), body.size - 1L))
        assertNull(ImageStore.readAtMost(ByteArrayInputStream(body), 0L))
    }

    @Test
    fun anEmptyBodyIsEmpty() {
        assertArrayEquals(ByteArray(0), ImageStore.readAtMost(ByteArrayInputStream(ByteArray(0)), 0L))
    }

    // A body that never ends stops at the limit, not when memory runs out.
    @Test(timeout = 5000)
    fun anEndlessBodyIsRefused() {
        val endless = object : InputStream() {
            override fun read(): Int = 0
            override fun read(b: ByteArray, off: Int, len: Int): Int = len
        }
        assertNull(ImageStore.readAtMost(endless, 1L shl 20))
    }
}
