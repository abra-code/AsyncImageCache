// MemoryCache.kt
//
// The in-memory tier. Swift used NSCache, which enforces BOTH a count limit and a byte-cost limit and evicts
// (approximately LRU) when either is exceeded. android.util.LruCache only supports a single size metric, so this
// is a small thread-safe LRU that honors both limits at once - preserving the Swift semantics the store relies
// on (a byte ceiling so a few large decoded bitmaps cannot pin memory, plus a count guard). Access-ordered so
// eviction is true LRU.
//
// Deliberately does NOT recycle evicted bitmaps: an evicted variant may still be referenced by an in-flight
// completion or an active draw, and recycling it would crash the renderer. Reclamation is left to the GC, which
// is exactly how NSCache/ARC behaved in the Swift reference.

package com.abracode.asyncimagecache

import java.util.concurrent.locks.ReentrantLock
import kotlin.concurrent.withLock

internal class MemoryCache<K : Any, V : Any>(
    private val countLimit: Int,
    val byteLimit: Long,
    private val sizeOf: (V) -> Long,
) {
    private val lock = ReentrantLock()
    // accessOrder = true: iteration yields least-recently-accessed first, so trimming evicts the LRU entry.
    private val map = LinkedHashMap<K, V>(16, 0.75f, true)
    private var totalBytes = 0L

    fun get(key: K): V? = lock.withLock { map[key] }

    fun put(key: K, value: V) {
        lock.withLock {
            val previous = map.put(key, value)
            if (previous != null) {
                totalBytes -= sizeOf(previous)
            }
            totalBytes += sizeOf(value)
            trimToLocked(byteLimit, countLimit)
        }
    }

    fun remove(key: K): V? = lock.withLock {
        val removed = map.remove(key)
        if (removed != null) {
            totalBytes -= sizeOf(removed)
        }
        removed
    }

    fun clear() = lock.withLock {
        map.clear()
        totalBytes = 0L
    }

    /** Evict LRU entries until the resident bytes are at or under `targetBytes` - the memory-pressure hook. */
    fun trimToBytes(targetBytes: Long) = lock.withLock {
        trimToLocked(maxOf(0L, targetBytes), countLimit)
    }

    val byteCount: Long get() = lock.withLock { totalBytes }

    private fun trimToLocked(maxBytes: Long, maxCount: Int) {
        val iterator = map.entries.iterator()
        while ((totalBytes > maxBytes || map.size > maxCount) && iterator.hasNext()) {
            val entry = iterator.next()
            iterator.remove()
            totalBytes -= sizeOf(entry.value)
        }
    }
}
