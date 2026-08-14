import XCTest
@testable import HostflipCore

/// In-line tokenization rules for the three token kinds (comment / IP / hostname), the minimal rules settled by the #7 research:
/// from the first # to the end of the line is a comment; the text before the comment splits on whitespace, with the first field being the IP and the rest hostnames.
final class HostsSyntaxTests: XCTestCase {
    private func token(_ kind: HostsTokenKind, _ location: Int, _ length: Int) -> HostsToken {
        HostsToken(kind: kind, range: NSRange(location: location, length: length))
    }

    func testFirstFieldIsIPAndFollowingFieldsAreHostnames() {
        XCTAssertEqual(HostsSyntax.tokens(in: "127.0.0.1 localhost local.dev"), [
            token(.ipAddress, 0, 9),
            token(.hostname, 10, 9),
            token(.hostname, 20, 9),
        ])
    }

    func testWholeLineCommentSpansToLineEnd() {
        XCTAssertEqual(HostsSyntax.tokens(in: "# hello"), [
            token(.comment, 0, 7),
        ])
    }

    func testTrailingCommentStartsAtHashAndFieldsEndBeforeIt() {
        XCTAssertEqual(HostsSyntax.tokens(in: "1.2.3.4 example.com # dev"), [
            token(.comment, 20, 5),
            token(.ipAddress, 0, 7),
            token(.hostname, 8, 11),
        ])
    }

    func testHashInsideFieldStartsCommentMidLine() {
        XCTAssertEqual(HostsSyntax.tokens(in: "1.2.3.4 foo#bar"), [
            token(.comment, 11, 4),
            token(.ipAddress, 0, 7),
            token(.hostname, 8, 3),
        ])
    }

    func testFieldsSeparatedByTabsAndRepeatedSpaces() {
        XCTAssertEqual(HostsSyntax.tokens(in: "::1\t\tlocalhost  ip6-localhost"), [
            token(.ipAddress, 0, 3),
            token(.hostname, 5, 9),
            token(.hostname, 16, 13),
        ])
    }

    func testLeadingWhitespaceDoesNotChangeFieldRoles() {
        XCTAssertEqual(HostsSyntax.tokens(in: "  1.2.3.4 host"), [
            token(.ipAddress, 2, 7),
            token(.hostname, 10, 4),
        ])
    }

    func testBlankAndWhitespaceOnlyLinesEmitNoTokens() {
        XCTAssertEqual(HostsSyntax.tokens(in: "\n   \n\t\n"), [])
    }

    func testRangesAreUTF16OffsetsAcrossLines() {
        // "🐘" takes 2 UTF-16 units: the first-line comment has length 7, and the second line starts at offset 8
        XCTAssertEqual(HostsSyntax.tokens(in: "# 备注 🐘\n0.0.0.0 ads.example.com\n"), [
            token(.comment, 0, 7),
            token(.ipAddress, 8, 7),
            token(.hostname, 16, 15),
        ])
    }

    func testCarriageReturnLineEndingsDoNotJoinLines() {
        XCTAssertEqual(HostsSyntax.tokens(in: "1.1.1.1 a\r\n2.2.2.2 b"), [
            token(.ipAddress, 0, 7),
            token(.hostname, 8, 1),
            token(.ipAddress, 11, 7),
            token(.hostname, 19, 1),
        ])
    }

    // MARK: - Structural validation

    func testCompleteEntriesCommentsAndBlankLinesAreNotIncomplete() {
        XCTAssertNil(HostsSyntax.firstIncompleteLine(in: """
            # blocklist
            0.0.0.0 ads.example.com tracker.example.com

            1.2.3.4 example.com # staging
            """))
    }

    func testEmptyContentIsNotIncomplete() {
        XCTAssertNil(HostsSyntax.firstIncompleteLine(in: ""))
    }

    func testALoneFieldLineIsIncomplete() {
        XCTAssertEqual(HostsSyntax.firstIncompleteLine(in: "127.0.0.1 localhost\n127.0.0.1\n"), 2)
    }

    func testASingleFieldBeforeAnInlineCommentIsIncomplete() {
        XCTAssertEqual(HostsSyntax.firstIncompleteLine(in: "127.0.0.1 # hostname to be decided"), 1)
    }

    func testTheFirstOfSeveralIncompleteLinesIsReported() {
        XCTAssertEqual(HostsSyntax.firstIncompleteLine(in: "stray\n1.1.1.1 a\nstray again\n"), 1)
    }

    func testFieldValuesAreNotValidated() {
        // Value correctness stays out of scope, matching the tokenizer: two fields make a
        // structurally complete entry regardless of what the fields contain.
        XCTAssertNil(HostsSyntax.firstIncompleteLine(in: "not-an-ip some-host"))
    }
}
