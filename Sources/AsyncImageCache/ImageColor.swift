// Sources/AsyncImageCache/ImageColor.swift
//
// A plain sRGB RGBA color (8 bits/channel), used for the persisted dominant-color placeholder. Deliberately
// UI-framework-free (no SwiftUI / UIKit / AppKit color type) so it can be computed off-main, packed into a
// 4-byte extended attribute, and handed to any renderer; CachedImage turns it into a SwiftUI Color.

import Foundation

public struct ImageColor: Sendable, Equatable {
    public let red: UInt8
    public let green: UInt8
    public let blue: UInt8
    public let alpha: UInt8

    public init(red: UInt8, green: UInt8, blue: UInt8, alpha: UInt8) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }
}
