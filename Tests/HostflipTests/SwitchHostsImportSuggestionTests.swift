import Foundation
import XCTest
@testable import Hostflip

/// The one-shot first-launch suggestion flag (#75): offered at most once, ever.
final class SwitchHostsImportSuggestionTests: XCTestCase {
    func testStartsUnoffered() {
        var stored = false
        let suggestion = SwitchHostsImportSuggestion(
            loadOffered: { stored },
            saveOffered: { stored = true }
        )

        XCTAssertFalse(suggestion.wasOffered)
    }

    func testMarkingPersistsAndSticks() {
        var stored = false
        let suggestion = SwitchHostsImportSuggestion(
            loadOffered: { stored },
            saveOffered: { stored = true }
        )

        suggestion.markOffered()

        XCTAssertTrue(stored)
        XCTAssertTrue(suggestion.wasOffered)
    }
}
