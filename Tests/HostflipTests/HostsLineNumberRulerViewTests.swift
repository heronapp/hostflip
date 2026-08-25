import AppKit
import XCTest
@testable import Hostflip

/// The line-number ruler caches its line count (#94): scrolling must never rescan the document.
@MainActor
final class HostsLineNumberRulerViewTests: XCTestCase {
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

    func testBoundsChangeDoesNotRecount() {
        let (scrollView, textView, ruler) = makeRuler("a\nb")
        // Mutate the storage behind the ruler's back: a recount on scroll would see 4 lines.
        textView.textStorage?.replaceCharacters(in: NSRange(location: 0, length: 0), with: "x\ny\n")
        NotificationCenter.default.post(
            name: NSView.boundsDidChangeNotification, object: scrollView.contentView
        )
        XCTAssertEqual(ruler.lineCount, 2)
    }

    func testEditsAndDocumentSwapsRecount() {
        let (_, textView, ruler) = makeRuler("a\nb")
        textView.insertText("c\n", replacementRange: NSRange(location: 0, length: 0))
        XCTAssertEqual(ruler.lineCount, 3)

        textView.string = "one"
        ruler.textDidReplace()
        XCTAssertEqual(ruler.lineCount, 1)
    }
}
