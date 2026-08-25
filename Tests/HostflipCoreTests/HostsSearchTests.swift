import XCTest
@testable import HostflipCore

/// Global search (#88): case-insensitive substring matches, one hit per line.
final class HostsSearchTests: XCTestCase {
    func testReportsOneHitPerMatchingLineWithLineAndMatchRanges() {
        let text = "127.0.0.1 api.example.com\n# api notes\n10.0.0.1 db.example.com api\n"
        XCTAssertEqual(HostsSearch.matches(in: text, query: "api"), [
            HostsSearch.Hit(line: 1, lineRange: NSRange(location: 0, length: 25), matchRange: NSRange(location: 10, length: 3)),
            HostsSearch.Hit(line: 2, lineRange: NSRange(location: 26, length: 11), matchRange: NSRange(location: 28, length: 3)),
            HostsSearch.Hit(line: 3, lineRange: NSRange(location: 38, length: 27), matchRange: NSRange(location: 62, length: 3)),
        ])
    }

    func testMatchingIsCaseInsensitiveAndIgnoresSurroundingWhitespaceInTheQuery() {
        XCTAssertEqual(HostsSearch.matches(in: "1.1.1.1 Example.COM", query: " example.com ").map(\.line), [1])
    }

    func testBlankQueryMatchesNothing() {
        XCTAssertEqual(HostsSearch.matches(in: "1.1.1.1 a", query: ""), [])
        XCTAssertEqual(HostsSearch.matches(in: "1.1.1.1 a", query: "   "), [])
    }

    func testLineRangeExcludesTheTerminator() {
        let hits = HostsSearch.matches(in: "a\r\nb\n", query: "b")
        XCTAssertEqual(hits, [HostsSearch.Hit(line: 2, lineRange: NSRange(location: 3, length: 1), matchRange: NSRange(location: 3, length: 1))])
    }
}
