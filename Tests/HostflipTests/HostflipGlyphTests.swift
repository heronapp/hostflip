import AppKit
import XCTest
@testable import Hostflip

@MainActor
final class HostflipGlyphTests: XCTestCase {
    func testTemplateImageContainsVisiblePixels() throws {
        let image = HostflipGlyph.makeImage()

        XCTAssertEqual(image.size, NSSize(width: 18, height: 18))
        XCTAssertTrue(image.isTemplate)

        var proposedRect = NSRect(origin: .zero, size: image.size)
        let cgImage = try XCTUnwrap(
            image.cgImage(forProposedRect: &proposedRect, context: nil, hints: nil)
        )
        let data = try XCTUnwrap(cgImage.dataProvider?.data)
        let bytes = try XCTUnwrap(CFDataGetBytePtr(data))
        let containsVisiblePixels = (0..<CFDataGetLength(data)).contains {
            bytes[$0] != 0
        }

        XCTAssertTrue(containsVisiblePixels)
    }

    func testTintedImageOptsOutOfTemplateRendering() {
        let image = HostflipGlyph.makeImage(tint: .systemBlue)

        XCTAssertEqual(image.size, NSSize(width: 18, height: 18))
        XCTAssertFalse(image.isTemplate)
    }

    func testDimmedImageStaysTemplate() {
        let image = HostflipGlyph.makeImage(alpha: 0.45)

        XCTAssertTrue(image.isTemplate)
    }
}
