// Tests/AsyncImageCacheTests/PortableValueTests.swift
//
// The platform-independent value types (ImageRequest, ImagePlaceholder, ImageColor). These tests run on every
// platform the package builds for, Linux included; the engine tests live in the Apple-only files beside them.

import XCTest
@testable import AsyncImageCache

final class PortableValueTests: XCTestCase {

    // The variant key quantizes transforms to whole pixels, so sub-pixel-apart requests share one cached
    // variant (no wasted decodes) and the key carries no fractional tail.
    func testVariantKeyQuantizesToWholePixels() {
        let url = URL(string: "https://example.test/i.png")!
        let a = ImageRequest(url: url, targetWidth: 342.4, cornerRadius: 9.6)
        let b = ImageRequest(url: url, targetWidth: 342.2, cornerRadius: 10.1)
        XCTAssertEqual(a.variantKey, b.variantKey, "sub-pixel widths/radii should collapse to one variant")
        // The width/radius carry no fractional tail (342.4 would have produced "|w=342.4|").
        XCTAssertTrue(a.variantKey.contains("|w=342|"), a.variantKey)
        XCTAssertTrue(a.variantKey.hasSuffix("|r=10"), a.variantKey)
        XCTAssertEqual(ImageRequest(url: url).variantKey, "\(url.absoluteString)|w=nil|r=0")
    }

    // A width that rounds to zero still asks for one pixel, and a negative radius means no rounding.
    func testQuantizationClampsToValidPixels() {
        let url = URL(string: "https://example.test/i.png")!
        let request = ImageRequest(url: url, targetWidth: 0.2, cornerRadius: -3)
        XCTAssertEqual(request.quantizedTargetWidth, 1)
        XCTAssertEqual(request.quantizedCornerRadius, 0)
    }

    // The dominant color is the per-channel average of the cells; an empty grid is fully transparent.
    func testDominantColorAveragesCells() {
        let cells = [
            ImageColor(red: 0, green: 100, blue: 200, alpha: 255),
            ImageColor(red: 100, green: 200, blue: 0, alpha: 255),
            ImageColor(red: 50, green: 0, blue: 100, alpha: 127),
            ImageColor(red: 250, green: 100, blue: 100, alpha: 1),
        ]
        let average = ImagePlaceholder(dimension: 2, cells: cells).dominantColor
        XCTAssertEqual(average, ImageColor(red: 100, green: 100, blue: 100, alpha: 159))
        XCTAssertEqual(ImagePlaceholder(dimension: 0, cells: []).dominantColor,
                       ImageColor(red: 0, green: 0, blue: 0, alpha: 0))
    }

    // Sizes can come from a document: Int() traps on what does not fit, on NaN and on an infinity.
    func testAnImageRequestTakesAnySize() throws {
        let url = try XCTUnwrap(URL(string: "https://example.com/a.png"))
        XCTAssertEqual(ImageRequest(url: url, targetWidth: 840.4).quantizedTargetWidth, 840)
        XCTAssertEqual(ImageRequest(url: url, targetWidth: 0).quantizedTargetWidth, 1, "the smallest width, as before")
        XCTAssertEqual(ImageRequest(url: url, targetWidth: -5).quantizedTargetWidth, 1)
        XCTAssertEqual(ImageRequest(url: url, targetWidth: 1e300).quantizedTargetWidth, 1 << 24, "larger than any image: no limit")
        XCTAssertEqual(ImageRequest(url: url, targetWidth: -1e300).quantizedTargetWidth, 1)
        XCTAssertNil(ImageRequest(url: url, targetWidth: .infinity).quantizedTargetWidth, "no limit")
        XCTAssertNil(ImageRequest(url: url, targetWidth: .nan).quantizedTargetWidth)
        XCTAssertEqual(ImageRequest(url: url, cornerRadius: 12.4).quantizedCornerRadius, 12)
        XCTAssertEqual(ImageRequest(url: url, cornerRadius: -3).quantizedCornerRadius, 0)
        XCTAssertEqual(ImageRequest(url: url, cornerRadius: 1e300).quantizedCornerRadius, 1 << 24)
        XCTAssertEqual(ImageRequest(url: url, cornerRadius: .nan).quantizedCornerRadius, 0)
        XCTAssertEqual(ImageRequest(url: url, cornerRadius: .infinity).quantizedCornerRadius, 0)
    }

    // The store keeps waiting completions in a table keyed by the request, so a request must equal itself.
    func testARequestWithNaNEqualsItself() throws {
        let url = try XCTUnwrap(URL(string: "https://example.com/a.png"))
        for request in [ImageRequest(url: url, targetWidth: .nan), ImageRequest(url: url, cornerRadius: .nan)] {
            XCTAssertEqual(request, request)
            XCTAssertTrue(Set([request]).contains(request))
        }
    }
}
