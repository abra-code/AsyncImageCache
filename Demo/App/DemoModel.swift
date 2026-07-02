// Demo/App/DemoModel.swift
//
// The demo's image catalog: LOCAL images generated into the bundle at build time (see Scripts and project.yml)
// and REMOTE images from picsum.photos. Both carry a known intrinsic size so CachedImage can reserve the exact
// box up front (zero reflow on hydration) - for locals the size is parsed from the "<name>-<w>x<h>.jpg"
// filename the generator writes; for remotes it is the size requested from the service.

import Foundation
import CoreGraphics

struct DemoImage: Identifiable {
    let id: String
    let title: String
    let url: URL
    let intrinsicSize: CGSize?
    let isRemote: Bool
}

enum DemoCatalog {

    /// The build-time-generated JPEGs, discovered in the app bundle by the generator's filename convention.
    static func localImages() -> [DemoImage] {
        guard let resourceURL = Bundle.main.resourceURL else {
            return []
        }
        // The generator's output is copied in as a folder reference ("GeneratedResources/"); fall back to a
        // flat bundle layout just in case the resources were flattened.
        let searchDirs = [resourceURL.appendingPathComponent("GeneratedResources", isDirectory: true),
                          resourceURL]
        let fileURLs = searchDirs.flatMap { dir in
            (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        }
        return fileURLs
            .filter { ["jpg", "gif"].contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .map { url in
                let stem = url.deletingPathExtension().lastPathComponent
                return DemoImage(id: "local-\(stem)",
                                 title: stem,
                                 url: url,
                                 intrinsicSize: parseSize(fromStem: stem),
                                 isRemote: false)
            }
    }

    /// Remote images at known sizes, so the reserved box is exact even before the bytes arrive.
    static func remoteImages() -> [DemoImage] {
        let specs: [(seed: String, width: Int, height: Int)] = [
            ("aic-meadow", 1200, 800),
            ("aic-canyon", 1000, 1500),
            ("aic-harbor", 1600, 900),
            ("aic-street", 900, 900),
            ("aic-peaks", 1400, 1050),
            ("aic-market", 800, 1200),
        ]
        return specs.map { spec in
            let url = URL(string: "https://picsum.photos/seed/\(spec.seed)/\(spec.width)/\(spec.height)")!
            return DemoImage(id: "remote-\(spec.seed)",
                             title: "\(spec.seed) \(spec.width)x\(spec.height)",
                             url: url,
                             intrinsicSize: CGSize(width: spec.width, height: spec.height),
                             isRemote: true)
        }
    }

    // "sunrise-2400x1600" -> 2400 x 1600
    private static func parseSize(fromStem stem: String) -> CGSize? {
        guard let dash = stem.lastIndex(of: "-") else {
            return nil
        }
        let dims = stem[stem.index(after: dash)...].split(separator: "x")
        guard dims.count == 2, let w = Int(dims[0]), let h = Int(dims[1]), w > 0, h > 0 else {
            return nil
        }
        return CGSize(width: w, height: h)
    }
}
