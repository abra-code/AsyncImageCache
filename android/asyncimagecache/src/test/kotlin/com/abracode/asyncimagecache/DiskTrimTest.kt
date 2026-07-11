// DiskTrimTest.kt - JVM unit tests for the eviction-order pure function, ported from the Swift trim logic:
// oldest-by-modification-date evicted first, stopping as soon as the total is back under budget.

package com.abracode.asyncimagecache

import org.junit.Assert.assertEquals
import org.junit.Test

class DiskTrimTest {

    private fun entry(id: String, size: Long, modified: Long) = TrimEntry(id, size, modified)

    @Test
    fun nothingEvictedWhenUnderBudget() {
        val entries = listOf(entry("a", 10, 1), entry("b", 20, 2))
        assertEquals(emptyList<String>(), DiskTrim.filesToEvict(entries, byteLimit = 100))
    }

    @Test
    fun nothingEvictedWhenExactlyAtBudget() {
        val entries = listOf(entry("a", 40, 1), entry("b", 60, 2))
        assertEquals(emptyList<String>(), DiskTrim.filesToEvict(entries, byteLimit = 100))
    }

    @Test
    fun evictsOldestFirstUntilUnderBudget() {
        // Total 120, limit 100 -> must drop 20+ bytes. Oldest is "a" (modified 1, 30 bytes): dropping it brings
        // total to 90 <= 100, so eviction stops after one file.
        val entries = listOf(
            entry("c", 40, 3),
            entry("a", 30, 1),
            entry("b", 50, 2),
        )
        assertEquals(listOf("a"), DiskTrim.filesToEvict(entries, byteLimit = 100))
    }

    @Test
    fun evictsMultipleOldestWhenOneIsNotEnough() {
        // Total 120, limit 40. Oldest first: a(1,30)->90, b(2,50)->40 <= 40 stop. c survives.
        val entries = listOf(
            entry("c", 40, 3),
            entry("b", 50, 2),
            entry("a", 30, 1),
        )
        assertEquals(listOf("a", "b"), DiskTrim.filesToEvict(entries, byteLimit = 40))
    }

    @Test
    fun zeroLimitEvictsEverythingOldestFirst() {
        val entries = listOf(entry("b", 10, 2), entry("a", 10, 1), entry("c", 10, 3))
        assertEquals(listOf("a", "b", "c"), DiskTrim.filesToEvict(entries, byteLimit = 0))
    }

    @Test
    fun negativeLimitTreatedAsZero() {
        val entries = listOf(entry("a", 5, 1))
        assertEquals(listOf("a"), DiskTrim.filesToEvict(entries, byteLimit = -100))
    }

    @Test
    fun emptyInputEvictsNothing() {
        assertEquals(emptyList<String>(), DiskTrim.filesToEvict(emptyList<TrimEntry<String>>(), byteLimit = 10))
    }
}
