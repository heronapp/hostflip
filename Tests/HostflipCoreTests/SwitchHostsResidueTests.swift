import XCTest
@testable import HostflipCore

/// The SwitchHosts block removal applied at first capture (#81).
final class SwitchHostsResidueTests: XCTestCase {
    func testContentWithoutAMarkerIsReturnedUnchanged() {
        let content = "127.0.0.1 localhost\n# a comment with no marker\n10.0.0.1 api.example.com"
        XCTAssertEqual(SwitchHostsResidue.stripped(from: content), content)
    }

    func testEverythingFromTheMarkerOnIsDroppedAndTrailingBlankLinesCollapse() {
        let content = "127.0.0.1 localhost\n255.255.255.255 broadcasthost\n\n\n# --- SWITCHHOSTS_CONTENT_START ---\n\n10.0.0.1 api.example.com\n"
        XCTAssertEqual(
            SwitchHostsResidue.stripped(from: content),
            "127.0.0.1 localhost\n255.255.255.255 broadcasthost\n"
        )
    }

    func testAMarkerOnTheFirstLineLeavesAnEmptyBaseline() {
        XCTAssertEqual(SwitchHostsResidue.stripped(from: "# --- SWITCHHOSTS_CONTENT_START ---\n\n10.0.0.1 api.example.com\n"), "")
        XCTAssertEqual(SwitchHostsResidue.stripped(from: "\n\n# --- SWITCHHOSTS_CONTENT_START ---\n"), "")
    }

    func testTheFirstMarkerWins() {
        let content = "127.0.0.1 localhost\n# --- SWITCHHOSTS_CONTENT_START ---\n1.1.1.1 one\n# --- SWITCHHOSTS_CONTENT_START ---\n2.2.2.2 two\n"
        XCTAssertEqual(SwitchHostsResidue.stripped(from: content), "127.0.0.1 localhost\n")
    }

    func testCRLFContentStripsTheSameWayAsLF() {
        let crlf = "127.0.0.1 localhost\r\n\r\n# --- SWITCHHOSTS_CONTENT_START ---\r\n\r\n10.0.0.1 api.example.com\r\n"
        XCTAssertEqual(SwitchHostsResidue.stripped(from: crlf), "127.0.0.1 localhost\n")
    }
}
