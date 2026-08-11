import Foundation
import HostflipCore
import XCTest
@testable import Hostflip

final class HostsDriftComparisonTests: XCTestCase {
    func testDiffRowsDescribeRemovedAndAddedLinesWithSourceLineNumbers() {
        let comparison = HostsDriftComparison(
            expectedContent: "127.0.0.1 localhost\n10.0.0.1 old.local\n",
            actualData: Data("127.0.0.1 localhost\n10.0.0.2 new.local\n".utf8)
        )

        XCTAssertEqual(comparison.diffRows, [
            HostsDriftDiffRow(kind: .removed, lineNumber: 2, text: "10.0.0.1 old.local"),
            HostsDriftDiffRow(kind: .added, lineNumber: 2, text: "10.0.0.2 new.local"),
        ])
        XCTAssertEqual(comparison.diffSummary, HostsDriftDiffSummary(additions: 1, removals: 1))
    }

    func testGeneratedHostflipMarkersAreDetectedAnywhereInSystemHosts() {
        // Both the current fence and the pre-0.1.2 top banner count as
        // generated output, wherever they appear in the file.
        for marker in [MergedHosts.appendedBlockBegin, MergedHosts.legacyGeneratedBanner] {
            let comparison = HostsDriftComparison(
                expectedContent: "",
                actualData: Data(("# external prefix\n" + marker + "\n").utf8)
            )
            XCTAssertTrue(comparison.containsGeneratedHostflipOutput, marker)
        }
    }

    func testInvalidUTF8HasNoAdoptableActualContent() {
        let comparison = HostsDriftComparison(
            expectedContent: "",
            actualData: Data([0xFF])
        )

        XCTAssertNil(comparison.actualContent)
    }
}
