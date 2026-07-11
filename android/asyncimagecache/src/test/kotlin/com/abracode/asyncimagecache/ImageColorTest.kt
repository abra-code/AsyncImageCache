// ImageColorTest.kt - JVM unit tests for the RGBA8 value class: channel packing, ARGB interop, equality.

package com.abracode.asyncimagecache

import org.junit.Assert.assertEquals
import org.junit.Test

class ImageColorTest {

    @Test
    fun channelsRoundTrip() {
        val c = ImageColor(red = 10, green = 20, blue = 30, alpha = 40)
        assertEquals(10, c.red)
        assertEquals(20, c.green)
        assertEquals(30, c.blue)
        assertEquals(40, c.alpha)
    }

    @Test
    fun fullChannelsRoundTrip() {
        val c = ImageColor(red = 255, green = 0, blue = 128, alpha = 255)
        assertEquals(255, c.red)
        assertEquals(0, c.green)
        assertEquals(128, c.blue)
        assertEquals(255, c.alpha)
    }

    @Test
    fun argbPacksInAndroidOrder() {
        val c = ImageColor(red = 0x12, green = 0x34, blue = 0x56, alpha = 0x78)
        assertEquals(0x78123456.toInt(), c.argb)
    }

    @Test
    fun equalityFollowsChannels() {
        assertEquals(ImageColor(1, 2, 3, 4), ImageColor(1, 2, 3, 4))
    }
}
