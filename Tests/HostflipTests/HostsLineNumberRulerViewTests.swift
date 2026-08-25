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

extension HostsLineNumberRulerViewTests {
    /// Lays the editor out in a window so the viewport controller has run.
    private func makeLaidOutRuler(_ text: String, width: CGFloat) -> HostsLineNumberRulerView {
        let (scrollView, textView, ruler) = makeRuler("")
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: width, height: 300),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.contentView = scrollView
        scrollView.hasVerticalRuler = true
        scrollView.rulersVisible = true
        textView.string = text
        window.contentView?.layoutSubtreeIfNeeded()
        textView.display()
        return ruler
    }

    func testLabelsNumberOnlyTheFirstRowOfAWrappedLine() throws {
        let long = String(repeating: "x", count: 400)
        let ruler = makeLaidOutRuler("a\n\(long)\nb", width: 300)
        let labels = try XCTUnwrap(ruler.labels(in: NSRect(x: 0, y: 0, width: 300, height: 300)))
        XCTAssertEqual(labels.map(\.line), [1, 2, 3])
        // Line 3 sits below every wrapped row of line 2, more than one row further down.
        XCTAssertGreaterThan(labels[2].y - labels[1].y, labels[1].height * 1.5)
    }

    func testLabelsIncludeTheTrailingEmptyLine() throws {
        let ruler = makeLaidOutRuler("a\nb\n", width: 300)
        let labels = try XCTUnwrap(ruler.labels(in: NSRect(x: 0, y: 0, width: 300, height: 300)))
        XCTAssertEqual(labels.map(\.line), [1, 2, 3])
        XCTAssertEqual(labels[2].y - labels[1].y, labels[1].height, accuracy: 0.5)
    }

    func testEmptyDocumentStillShowsLineOne() throws {
        let ruler = makeLaidOutRuler("", width: 300)
        let labels = try XCTUnwrap(ruler.labels(in: NSRect(x: 0, y: 0, width: 300, height: 300)))
        XCTAssertEqual(labels.map(\.line), [1])
    }
}

extension HostsLineNumberRulerViewTests {
    func testIncompleteLinesFollowEdits() {
        let (_, textView, ruler) = makeRuler("127.0.0.1\n# note\n1.1.1.1 a")
        XCTAssertEqual(ruler.incompleteLines, [1])
        textView.insertText(" app.test", replacementRange: NSRange(location: 9, length: 0))
        XCTAssertEqual(ruler.incompleteLines, [])
        textView.insertText("\nstray", replacementRange: NSRange(location: (textView.string as NSString).length, length: 0))
        XCTAssertEqual(ruler.incompleteLines, [4])
        textView.string = "fresh document"
        XCTAssertEqual(ruler.incompleteLines, [])
    }

    func testTooltipIsServedOnlyOnFlaggedRows() throws {
        let ruler = makeLaidOutRuler("1.1.1.1 a\n127.0.0.1\n", width: 300)
        let textView = try XCTUnwrap(ruler.clientView as? NSTextView)
        let labels = try XCTUnwrap(ruler.labels(in: textView.visibleRect))
        func tooltip(onLine line: Int) -> String {
            let label = labels.first { $0.line == line }!
            let point = ruler.convert(NSPoint(x: 0, y: label.y + label.height / 2), from: textView)
            return ruler.view(ruler, stringForToolTip: 0, point: point, userData: nil)
        }
        XCTAssertEqual(tooltip(onLine: 1), "")
        XCTAssertEqual(tooltip(onLine: 2), HostsLineNumberRulerView.incompleteLineTooltip)
        XCTAssertEqual(tooltip(onLine: 3), "")
    }
}
