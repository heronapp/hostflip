import AppKit
import XCTest
@testable import Hostflip

/// Toggle Comment on the editor's text view (#86): one undoable step through the regular
/// text-change path.
@MainActor
final class HostsTextViewTests: XCTestCase {
    @MainActor
    private final class Delegate: NSObject, NSTextViewDelegate {
        let undoManager = UndoManager()
        var changes = 0

        func undoManager(for view: NSTextView) -> UndoManager? { undoManager }
        func textDidChange(_ notification: Notification) { changes += 1 }
    }

    private func makeTextView(_ text: String, delegate: Delegate) -> HostsTextView {
        let textView = HostsTextView.scrollableTextView().documentView as! HostsTextView
        textView.allowsUndo = true
        textView.delegate = delegate
        textView.string = text
        return textView
    }

    func testToggleIsOneUndoStepAndNotifiesTheDelegate() {
        let delegate = Delegate()
        let textView = makeTextView("a\nb\nc", delegate: delegate)
        textView.setSelectedRange(NSRange(location: 0, length: 3))

        textView.toggleComment(nil)
        XCTAssertEqual(textView.string, "# a\n# b\nc")
        XCTAssertEqual(textView.selectedRange(), NSRange(location: 0, length: 7))
        XCTAssertEqual(delegate.changes, 1)

        delegate.undoManager.undo()
        XCTAssertEqual(textView.string, "a\nb\nc")
        delegate.undoManager.redo()
        XCTAssertEqual(textView.string, "# a\n# b\nc")
    }

    func testReadOnlyViewIgnoresTheAction() {
        let delegate = Delegate()
        let textView = makeTextView("a", delegate: delegate)
        textView.isEditable = false
        textView.toggleComment(nil)
        XCTAssertEqual(textView.string, "a")
        XCTAssertEqual(delegate.changes, 0)
    }
}
