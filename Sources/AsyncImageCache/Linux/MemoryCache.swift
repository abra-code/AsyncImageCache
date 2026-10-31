// Sources/AsyncImageCache/Linux/MemoryCache.swift
//
// The in-memory tier on Linux, in place of NSCache (not in FoundationEssentials): a least-recently-used map
// with a count limit and a cost limit, either of which evicts. Thread-safe through Synchronization's Mutex.
// NSCache also purges under system memory pressure; Linux has no such signal for a process, so the limits are
// the whole bound here. An entry whose own cost is over the cost limit is not kept (NSCache does not keep one
// either).

import Synchronization

final class MemoryCache<Value: Sendable>: Sendable {

    // A doubly linked list threaded through the entries by key: head = most recently used.
    private struct Entry {
        var value: Value
        var cost: Int
        var newer: String?
        var older: String?
    }

    private struct State {
        var entries: [String: Entry] = [:]
        var newest: String?
        var oldest: String?
        var totalCost = 0
        var countLimit: Int
        var costLimit: Int

        mutating func unlink(_ key: String) -> Entry? {
            guard let entry = entries.removeValue(forKey: key) else {
                return nil
            }
            if let newer = entry.newer {
                entries[newer]?.older = entry.older
            } else {
                newest = entry.older
            }
            if let older = entry.older {
                entries[older]?.newer = entry.newer
            } else {
                oldest = entry.newer
            }
            totalCost -= entry.cost
            return entry
        }

        mutating func linkAsNewest(_ key: String, _ value: Value, cost: Int) {
            entries[key] = Entry(value: value, cost: cost, newer: nil, older: newest)
            if let previous = newest {
                entries[previous]?.newer = key
            } else {
                oldest = key
            }
            newest = key
            totalCost += cost
        }

        mutating func evictOverLimits() {
            while let key = oldest, entries.count > countLimit || totalCost > costLimit {
                _ = unlink(key)
            }
        }
    }

    private let state: Mutex<State>

    /// `countLimit` and `costLimit` of 0 mean no limit, as NSCache's do.
    init(countLimit: Int = 0, costLimit: Int = 0) {
        state = Mutex(State(countLimit: countLimit > 0 ? countLimit : Int.max,
                            costLimit: costLimit > 0 ? costLimit : Int.max))
    }

    var costLimit: Int {
        state.withLock { $0.costLimit == Int.max ? 0 : $0.costLimit }
    }

    /// The value for `key`, which becomes the most recently used; nil on a miss.
    func object(forKey key: String) -> Value? {
        state.withLock { state in
            guard let entry = state.unlink(key) else {
                return nil
            }
            state.linkAsNewest(key, entry.value, cost: entry.cost)
            return entry.value
        }
    }

    func setObject(_ value: Value, forKey key: String, cost: Int = 0) {
        state.withLock { state in
            _ = state.unlink(key)
            let cost = max(0, cost)
            guard cost <= state.costLimit else {
                return
            }
            state.linkAsNewest(key, value, cost: cost)
            state.evictOverLimits()
        }
    }

    func removeAllObjects() {
        state.withLock { state in
            state.entries = [:]
            state.newest = nil
            state.oldest = nil
            state.totalCost = 0
        }
    }

    var count: Int {
        state.withLock { $0.entries.count }
    }
}
