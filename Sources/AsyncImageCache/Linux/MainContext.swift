// Sources/AsyncImageCache/Linux/MainContext.swift
//
// The main thread on Linux is the thread that runs GLib's default main context: the GTK main loop. Completions
// run there (as on Apple's main queue), and so does libsoup, whose session must stay on one thread. A source
// added with g_idle_add_full runs on that thread in any GTK program, whatever else drives the program's main
// queue, so this does not depend on how (or whether) libdispatch's main queue is pumped.

import CAsyncImageCacheGtk

/// A minimal escape hatch for moving a non-Sendable value (a caller's completion closure) across a thread hop.
/// The value is written once and read once; the component ensures no concurrent access, which is why
/// `@unchecked Sendable` is sound here. (The Apple counterpart is in PlatformImage.swift.)
struct UncheckedSendableBox<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) {
        self.value = value
    }
}

enum MainContext {

    private final class Work {
        let run: () -> Void
        init(_ run: @escaping () -> Void) {
            self.run = run
        }
    }

    // Runs the box's closure once, then releases the box; returning 0 (G_SOURCE_REMOVE) removes the source.
    private static let trampoline: @convention(c) (gpointer?) -> gboolean = { data in
        guard let data else {
            return 0
        }
        Unmanaged<Work>.fromOpaque(data).takeRetainedValue().run()
        return 0
    }

    /// Runs `work` on the main context's thread, always later (never inside this call), at default priority
    /// so it is not starved behind idle work such as redraw bookkeeping.
    static func async(_ work: @escaping @Sendable () -> Void) {
        let data = Unmanaged.passRetained(Work(work)).toOpaque()
        g_idle_add_full(G_PRIORITY_DEFAULT, trampoline, data, nil)
    }
}
