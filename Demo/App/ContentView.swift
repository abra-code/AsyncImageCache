// Demo/App/ContentView.swift
//
// A scrolling LazyVStack of CachedImage rows. Controls at the top let you:
//   - cap the decoded width (to watch the off-main downscale),
//   - switch the cache budget between the RAM-scaled default and a deliberately TINY 2 MB budget, so you can
//     watch variants evict and reload as you scroll (and the placeholder reappear on the reload),
//   - "show placeholders only", which renders the cached blurry preview statically instead of the full image,
//     so you can actually SEE the placeholder grid for everything that has been loaded once,
//   - clear the memory or the whole (memory + disk) cache.
//
// Note on placeholders: the preview is DERIVED from the decoded pixels, so a never-before-seen remote image
// has no preview yet and shows flat gray. It appears once the image has loaded once (then it survives
// relaunch via the on-disk xattr). The tiny budget + "show placeholders only" make it easy to observe.

import SwiftUI
import AsyncImageCache

struct ContentView: View {
    @State private var includeRemote = true
    @State private var capDecodedWidth = false
    @State private var showPlaceholdersOnly = false
    @State private var useTinyBudget = false
    // Bumped on "clear" so the rows' identity changes and they reload from a cold cache.
    @State private var reloadToken = UUID()

    private let local = DemoCatalog.localImages()
    private let remote = DemoCatalog.remoteImages()

    // The RAM-scaled shared store, and a deliberately tiny one that shares the SAME disk directory (name
    // "default") so switching budgets does not re-download - only the in-memory eviction behavior changes.
    private let defaultStore = ImageStore.shared
    private let tinyStore = ImageStore(name: "default", memoryCountLimit: 3, memoryByteLimit: 2 * 1024 * 1024)

    private var activeStore: ImageStore { useTinyBudget ? tinyStore : defaultStore }
    private var maxPixelWidth: CGFloat? { capDecodedWidth ? 400 : nil }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 20) {
                controls

                sectionHeader("Local (generated at build, loaded from disk)")
                ForEach(local) { item in
                    row(item)
                }

                if includeRemote {
                    sectionHeader("Remote (picsum.photos, fetched + cached)")
                    ForEach(remote) { item in
                        row(item)
                    }
                }
            }
            .padding()
        }
    }

    private func row(_ item: DemoImage) -> some View {
        ImageRow(item: item,
                 maxPixelWidth: maxPixelWidth,
                 store: activeStore,
                 showPlaceholderOnly: showPlaceholdersOnly,
                 reloadToken: reloadToken)
            // Re-identify on any change that alters what the row should show, so it re-runs its load task.
            .id("\(item.id)-\(reloadToken)-\(useTinyBudget)-\(showPlaceholdersOnly)-\(capDecodedWidth)")
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("AsyncImageCache demo")
                .font(.title2.weight(.bold))
            Text("Off-main decode + downscale, placeholder preview, zero-reflow layout, two-tier cache.")
                .font(.footnote)
                .foregroundStyle(.secondary)

            Toggle("Include remote images", isOn: $includeRemote)
            Toggle("Cap decoded width to 400 px (downscale off-main)", isOn: $capDecodedWidth)
            Toggle("Tiny memory budget (2 MB - watch eviction + reload)", isOn: $useTinyBudget)
            Toggle("Show placeholders only (static blurry preview)", isOn: $showPlaceholdersOnly)

            HStack(spacing: 12) {
                Button("Clear memory") {
                    defaultStore.clearMemory()
                    tinyStore.clearMemory()
                    reloadToken = UUID()
                }
                Button("Clear memory + disk", role: .destructive) {
                    defaultStore.removeAll()   // shares the disk dir with tinyStore
                    tinyStore.clearMemory()
                    reloadToken = UUID()
                }
            }
            .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func sectionHeader(_ text: String) -> some View {
        Text(text)
            .font(.headline)
            .padding(.top, 4)
    }
}

#Preview {
    ContentView()
}
