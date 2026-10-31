// DiskCacheHoldsTest.kt - JVM unit tests for which images the disk tier keeps: everything but local file: and
// content: images, which are their own copies (a copy would go on showing the old picture after an edit).

package com.abracode.asyncimagecache

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class DiskCacheHoldsTest {

    @Test
    fun remoteAndDataImagesAreKept() {
        assertTrue(DiskCache.holds("https://example.test/a.png"))
        assertTrue(DiskCache.holds("http://example.test/a.png"))
        assertTrue(DiskCache.holds("data:image/png;base64,AAAA"))
    }

    @Test
    fun localImagesAreNotKept() {
        assertFalse(DiskCache.holds("file:///sdcard/a.png"))
        assertFalse(DiskCache.holds("FILE:///sdcard/a.png"))
        assertFalse(DiskCache.holds("content://media/external/images/1"))
    }
}
