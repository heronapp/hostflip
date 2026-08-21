import XCTest
@testable import HostflipCore

/// The SwitchHosts block removal applied at first capture (#81).
final class SwitchHostsResidueTests: XCTestCase {
    func testContentWithoutAMarkerIsReturnedUnchanged() {
        let content = "127.0.0.1 localhost\n# a comment with no marker\n10.0.0.1 api.example.com"
        XCTAssertEqual(SwitchHostsResidue.stripped(from: content), content)
    }

    func testTheMarkerInsideALongerLineDoesNotCutTheFile() {
        let comment = "# note: SwitchHosts appends below # --- SWITCHHOSTS_CONTENT_START ---\n10.0.0.1 corp.internal\n"
        XCTAssertEqual(SwitchHostsResidue.stripped(from: comment), comment)
        let indented = "  # --- SWITCHHOSTS_CONTENT_START ---\n10.0.0.1 corp.internal\n"
        XCTAssertEqual(SwitchHostsResidue.stripped(from: indented), indented)
    }

    func testTrailingSpacesAndTabsBeforeTheMarkerCollapseToo() {
        let content = "127.0.0.1 localhost\t \u{00A0}\n\n# --- SWITCHHOSTS_CONTENT_START ---\n10.0.0.1 api.example.com\n"
        XCTAssertEqual(SwitchHostsResidue.stripped(from: content), "127.0.0.1 localhost\n")
    }

    func testEverythingFromTheMarkerOnIsDroppedAndTrailingBlankLinesCollapse() {
        let content = "127.0.0.1 localhost\n255.255.255.255 broadcasthost\n\n\n# --- SWITCHHOSTS_CONTENT_START ---\n\n10.0.0.1 api.example.com\n"
        XCTAssertEqual(
            SwitchHostsResidue.stripped(from: content),
            "127.0.0.1 localhost\n255.255.255.255 broadcasthost\n"
        )
    }

    func testAMarkerWithNothingBeforeItKeepsTheWholeFile() {
        // Append mode never produces an empty head, and an empty Base Hosts would turn a
        // no-profile write into an empty system hosts — the whole file is the safer capture.
        let leading = "# --- SWITCHHOSTS_CONTENT_START ---\n\n10.0.0.1 api.example.com\n"
        XCTAssertEqual(SwitchHostsResidue.stripped(from: leading), leading)
        let whitespaceOnly = "\n\n# --- SWITCHHOSTS_CONTENT_START ---\n"
        XCTAssertEqual(SwitchHostsResidue.stripped(from: whitespaceOnly), whitespaceOnly)
    }

    func testTheFirstMarkerWins() {
        let content = "127.0.0.1 localhost\n# --- SWITCHHOSTS_CONTENT_START ---\n1.1.1.1 one\n# --- SWITCHHOSTS_CONTENT_START ---\n2.2.2.2 two\n"
        XCTAssertEqual(SwitchHostsResidue.stripped(from: content), "127.0.0.1 localhost\n")
    }

    func testCRLFContentKeepsItsLineEnding() {
        let crlf = "127.0.0.1 localhost\r\n10.0.0.2 db.local\r\n\r\n# --- SWITCHHOSTS_CONTENT_START ---\r\n\r\n10.0.0.1 api.example.com\r\n"
        // No mixed endings: the collapsed tail ends the way the head's lines do.
        XCTAssertEqual(SwitchHostsResidue.stripped(from: crlf), "127.0.0.1 localhost\r\n10.0.0.2 db.local\r\n")
    }
}
