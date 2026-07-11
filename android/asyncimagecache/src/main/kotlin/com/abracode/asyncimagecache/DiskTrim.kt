// DiskTrim.kt
//
// The eviction-order computation for the on-disk byte budget, extracted from DiskCache as a pure function so it
// is JVM-testable without touching the filesystem. Mirrors the Swift `trimIfNeeded` logic exactly: if the
// directory is over budget, evict oldest-by-modification-date first, stopping the moment the running total is
// back at or under the limit. No android.* import.

package com.abracode.asyncimagecache

/** One cached file for trim accounting: an opaque id, its byte size, and its last-modified time (ms). */
internal data class TrimEntry<out T>(
    val id: T,
    val size: Long,
    val lastModified: Long,
)

internal object DiskTrim {

    /**
     * The ids to evict, in eviction order (oldest first), to bring the total at or under `byteLimit`. Returns an
     * empty list when the total already fits. A non-positive limit is treated as 0 (evict everything), matching
     * the Swift `max(0, byteLimit)` clamp.
     *
     * The stopping rule matches the reference precisely: after removing each oldest entry the running total is
     * re-checked, and eviction stops as soon as `total <= byteLimit`, so no more than necessary is evicted.
     */
    fun <T> filesToEvict(entries: List<TrimEntry<T>>, byteLimit: Long): List<T> {
        val limit = maxOf(0L, byteLimit)
        var total = 0L
        for (entry in entries) {
            total += entry.size
        }
        if (total <= limit) {
            return emptyList()
        }
        val evicted = ArrayList<T>()
        for (entry in entries.sortedBy { it.lastModified }) {
            evicted.add(entry.id)
            total -= entry.size
            if (total <= limit) {
                break
            }
        }
        return evicted
    }
}
