// ImagePlaceholderTest.kt - JVM unit tests for the placeholder model: dominant-color averaging and the empty
// guard. Ports the intent of the Swift `dominantColor` behavior (integer average per channel).

package com.abracode.asyncimagecache

import org.junit.Assert.assertEquals
import org.junit.Test

class ImagePlaceholderTest {

    @Test
    fun dominantColorAveragesEveryChannel() {
        val cells = listOf(
            ImageColor(0, 0, 0, 255),
            ImageColor(100, 100, 100, 255),
            ImageColor(200, 200, 200, 255),
        )
        val p = ImagePlaceholder(dimension = 1, cells = cells)
        val d = p.dominantColor
        assertEquals(100, d.red)   // (0 + 100 + 200) / 3 = 100
        assertEquals(100, d.green)
        assertEquals(100, d.blue)
        assertEquals(255, d.alpha)
    }

    @Test
    fun dominantColorUsesIntegerDivision() {
        // (10 + 10 + 5) / 3 = 8 (truncated), matching Swift's `Int` division.
        val cells = listOf(ImageColor(10, 0, 0, 0), ImageColor(10, 0, 0, 0), ImageColor(5, 0, 0, 0))
        assertEquals(8, ImagePlaceholder(1, cells).dominantColor.red)
    }

    @Test
    fun dominantColorOfEmptyGridIsTransparentBlack() {
        val d = ImagePlaceholder(dimension = 0, cells = emptyList()).dominantColor
        assertEquals(ImageColor(0, 0, 0, 0), d)
    }

    @Test
    fun placeholderEqualityFollowsCells() {
        val cells = (0 until 36).map { ImageColor(it, 100, 150, 255) }
        assertEquals(ImagePlaceholder(6, cells), ImagePlaceholder(6, cells))
    }
}
