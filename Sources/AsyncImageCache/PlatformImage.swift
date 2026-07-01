// Sources/AsyncImageCache/PlatformImage.swift
//
// Cross-platform image alias + small concurrency helpers. `PlatformImage` is UIImage on UIKit platforms
// (iOS / iPadOS / visionOS) and NSImage on AppKit (macOS). NSImage is NOT Sendable while UIImage is, so a
// decoded image that must cross a thread boundary to the main-thread completion is carried inside an
// `UncheckedSendableBox` - the whole component owns the guarantee that the value is only touched on one side
// at a time (produce off-main, hand off, deliver on-main).

import Foundation
import CoreGraphics

#if canImport(UIKit)
import UIKit
public typealias PlatformImage = UIImage
#elseif canImport(AppKit)
import AppKit
public typealias PlatformImage = NSImage
#endif

/// A minimal escape hatch for moving a non-Sendable value (an NSImage, or a caller's completion closure)
/// across a `DispatchQueue.main.async` hop. The value is written once and read once; the component ensures
/// no concurrent access, which is why `@unchecked Sendable` is sound here.
struct UncheckedSendableBox<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) {
        self.value = value
    }
}
