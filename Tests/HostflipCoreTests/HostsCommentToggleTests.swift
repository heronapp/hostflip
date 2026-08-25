import XCTest
@testable import HostflipCore

/// Toggle Comment (#86): line-wise comment/uncomment over the lines intersecting a UTF-16
/// selection. All non-blank target lines commented → uncomment them all; otherwise comment
/// every non-blank line (mixed selections become fully commented). Blank lines are skipped.
final class HostsCommentToggleTests: XCTestCase {
    private func toggle(_ text: String, _ location: Int, _ length: Int = 0) -> HostsCommentToggle? {
        HostsSyntax.toggleComment(in: text, range: NSRange(location: location, length: length))
    }

    func testCommentsTheCaretLineAndKeepsTheCaretOnIt() throws {
        let edit = try XCTUnwrap(toggle("127.0.0.1 local.dev\n1.2.3.4 b", 5))
        XCTAssertEqual(edit.text, "# 127.0.0.1 local.dev\n1.2.3.4 b")
        XCTAssertEqual(edit.selection, NSRange(location: 7, length: 0))
    }

    func testUncommentsTheCaretLineRemovingHashAndOneSpace() throws {
        let edit = try XCTUnwrap(toggle("# 127.0.0.1 local.dev", 7))
        XCTAssertEqual(edit.text, "127.0.0.1 local.dev")
        XCTAssertEqual(edit.selection, NSRange(location: 5, length: 0))
    }

    func testHashWithoutSpaceUncommentsToo() throws {
        XCTAssertEqual(toggle("#foo", 0)?.text, "foo")
        XCTAssertEqual(toggle("# foo", 0)?.text, "foo")
        XCTAssertEqual(toggle("#  foo", 0)?.text, " foo")
        // The marker alone goes; a combining mark right after it stays with the text.
        XCTAssertEqual(toggle("#\u{301}foo", 0)?.text, "\u{301}foo")
    }

    func testIndentationIsPreservedBothWays() throws {
        XCTAssertEqual(toggle("  1.2.3.4 a", 0)?.text, "  # 1.2.3.4 a")
        XCTAssertEqual(toggle("\t# foo", 0)?.text, "\tfoo")
    }

    func testTrailingCommentIsNotTouched() throws {
        XCTAssertEqual(toggle("1.2.3.4 a # dev", 0)?.text, "# 1.2.3.4 a # dev")
        XCTAssertEqual(toggle("# 1.2.3.4 a # dev", 0)?.text, "1.2.3.4 a # dev")
    }

    func testAllCommentedSelectionUncommentsEveryLine() throws {
        let text = "# a\n#b\n\n  # c\n"
        let edit = try XCTUnwrap(toggle(text, 0, (text as NSString).length))
        XCTAssertEqual(edit.text, "a\nb\n\n  c\n")
        XCTAssertEqual(edit.selection, NSRange(location: 0, length: 8))
    }

    func testMixedSelectionCommentsEveryNonBlankLine() throws {
        let text = "# a\nb\n   \nc"
        let edit = try XCTUnwrap(toggle(text, 0, (text as NSString).length))
        XCTAssertEqual(edit.text, "# # a\n# b\n   \n# c")
        XCTAssertEqual(edit.selection, NSRange(location: 0, length: 17))
    }

    func testPartialSelectionCoversEveryIntersectingLine() throws {
        // "a\nb\nc": selecting from inside line 1 to inside line 2 targets both, not line 3.
        let edit = try XCTUnwrap(toggle("a\nb\nc", 1, 2))
        XCTAssertEqual(edit.text, "# a\n# b\nc")
        XCTAssertEqual(edit.selection, NSRange(location: 0, length: 7))
    }

    func testSelectionEndingAtLineStartExcludesThatLine() throws {
        let edit = try XCTUnwrap(toggle("a\nb\nc", 0, 2))
        XCTAssertEqual(edit.text, "# a\nb\nc")
        XCTAssertEqual(edit.selection, NSRange(location: 0, length: 3))
    }

    func testBlankOnlyTargetsAreANoOp() {
        XCTAssertNil(toggle("", 0))
        XCTAssertNil(toggle("   \n\t\n", 0, 6))
        XCTAssertNil(toggle("a\n\nb", 2))
    }

    func testCaretBeforeTheInsertionPointStaysPut() throws {
        let edit = try XCTUnwrap(toggle("  a", 1))
        XCTAssertEqual(edit.text, "  # a")
        XCTAssertEqual(edit.selection, NSRange(location: 1, length: 0))
    }

    func testEditedRangeAndReplacementDescribeTheTouchedLines() throws {
        let edit = try XCTUnwrap(toggle("x\na\nb\ny", 2, 3))
        XCTAssertEqual(edit.editedRange, NSRange(location: 2, length: 4))
        XCTAssertEqual(edit.replacement, "# a\n# b\n")
        XCTAssertEqual(edit.text, "x\n# a\n# b\ny")
    }
}

extension HostsCommentToggleTests {
    func testSelectionKeepsAFullySelectedTrailingBlankLine() throws {
        let edit = try XCTUnwrap(toggle("a\n\nb", 0, 3))
        XCTAssertEqual(edit.text, "# a\n\nb")
        XCTAssertEqual(edit.selection, NSRange(location: 0, length: 4))
    }

    func testUnicodeWhitespaceCountsAsBlankAndIndentation() throws {
        XCTAssertNil(toggle("\u{00A0}\u{3000}", 0))
        XCTAssertEqual(toggle("\u{3000}a", 0)?.text, "\u{3000}# a")
        XCTAssertEqual(toggle("\u{3000}# a", 0)?.text, "\u{3000}a")
    }

    func testVerticalTabIsNotALineBreak() throws {
        let edit = try XCTUnwrap(toggle("a\u{000B}b\nc", 0, 2))
        XCTAssertEqual(edit.text, "# a\u{000B}b\nc")
        XCTAssertEqual(edit.selection, NSRange(location: 0, length: 5))
    }
}
