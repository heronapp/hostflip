import AppKit
import XCTest
@testable import Hostflip

/// The line-number ruler caches its line count (#94): scrolling must never rescan the document.
@MainActor
final class HostsLineNumberRulerViewTests: XCTestCase {
    @MainActor
    private final class UndoDelegate: NSObject, NSTextViewDelegate {
        let undoManager: UndoManager
        init(undoManager: UndoManager) { self.undoManager = undoManager }
        func undoManager(for view: NSTextView) -> UndoManager? { undoManager }
    }

    private func makeRuler(_ text: String) -> (NSScrollView, HostsTextView, HostsLineNumberRulerView) {
        let scrollView = HostsTextView.scrollableTextView()
        let textView = scrollView.documentView as! HostsTextView
        textView.string = text
        let ruler = HostsLineNumberRulerView(scrollView: scrollView, textView: textView)
        scrollView.verticalRulerView = ruler
        scrollView.contentView.postsBoundsChangedNotifications = true
        return (scrollView, textView, ruler)
    }

    func testCountsLinesLikeTheEditorDisplaysThem() {
        XCTAssertEqual(makeRuler("").2.lineCount, 1)
        XCTAssertEqual(makeRuler("a\nb").2.lineCount, 2)
        XCTAssertEqual(makeRuler("a\nb\n").2.lineCount, 3)
    }

    /// The bounds observer only marks the ruler dirty; it never touches the storage.
    func testBoundsChangeObserverDoesNotRecount() {
        let (scrollView, textView, ruler) = makeRuler("a\nb")
        // Deafen the ruler to edits, then mutate: a recount on the scroll path would see 4 lines.
        NotificationCenter.default.removeObserver(
            ruler, name: NSTextStorage.didProcessEditingNotification, object: nil
        )
        textView.textStorage?.mutableString.setString("x\ny\na\nb")
        NotificationCenter.default.post(
            name: NSView.boundsDidChangeNotification, object: scrollView.contentView
        )
        XCTAssertEqual(ruler.lineCount, 2)
    }

    func testEditsUndoToggleCommentAndDocumentSwapsRecount() {
        let (_, textView, ruler) = makeRuler("a\nb")
        let undoManager = UndoManager()
        let delegate = UndoDelegate(undoManager: undoManager)
        textView.delegate = delegate
        textView.allowsUndo = true

        textView.insertText("c\n", replacementRange: NSRange(location: 0, length: 0))
        XCTAssertEqual(ruler.lineCount, 3)
        textView.breakUndoCoalescing()
        undoManager.undo()
        XCTAssertEqual(textView.string, "a\nb")
        XCTAssertEqual(ruler.lineCount, 2)

        textView.setSelectedRange(NSRange(location: 0, length: 3))
        textView.toggleComment(nil)
        XCTAssertEqual(textView.string, "# a\n# b")
        XCTAssertEqual(ruler.lineCount, 2)
        textView.insertText("\n", replacementRange: NSRange(location: 0, length: 0))
        XCTAssertEqual(ruler.lineCount, 3)

        textView.string = "one" // a document switch assigns the string without an edit notification
        XCTAssertEqual(ruler.lineCount, 1)
    }
}

extension HostsLineNumberRulerViewTests {
    func testLineNumberAtOffsetFollowsLineStarts() {
        let (_, _, ruler) = makeRuler("ab\ncd\n\nef")
        XCTAssertEqual(ruler.lineStarts, [0, 3, 6, 7])
        XCTAssertEqual(ruler.lineNumber(at: 0), 1)
        XCTAssertEqual(ruler.lineNumber(at: 2), 1)
        XCTAssertEqual(ruler.lineNumber(at: 3), 2)
        XCTAssertEqual(ruler.lineNumber(at: 6), 3)
        XCTAssertEqual(ruler.lineNumber(at: 7), 4)
        XCTAssertEqual(ruler.lineNumber(at: 9), 4)
    }
}
