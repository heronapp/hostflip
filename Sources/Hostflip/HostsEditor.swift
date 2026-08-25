import AppKit
import HostflipCore
import SwiftUI

/// Hosts editor wrapping NSTextView (TextKit 2) — the minimal path researched in #7.
/// Highlighting reruns in full and hooks textDidChange — it must not hook didProcessEditing,
/// where attribute changes would merge into the notification range of the current character
/// edit and push the insertion point to the end of the line; it also never touches the
/// layoutManager property, since merely accessing it falls back to TextKit 1.
struct HostsEditor: NSViewRepresentable {
    @Binding var text: String
    var isEditable = true
    /// Identity of the document being shown. A persistent editor instance switches documents in
    /// place (the detail pane reuses one NSScrollView so switching never re-creates the text
    /// system, which would flash a zero-sized editor for a frame); a change of identity resets
    /// the per-document view state: undo stack, selection, scroll position, and the find bar.
    var documentID: AnyHashable = "single-document"

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = HostsTextView.scrollableTextView()
        let textView = scrollView.documentView as! HostsTextView
        textView.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        textView.isEditable = isEditable
        textView.isSelectable = true
        textView.allowsUndo = isEditable // off by default, must be enabled explicitly
        textView.usesFindPanel = true
        textView.isRichText = false
        // Smart substitutions would corrupt hosts text (curly quotes, dash substitution, autocorrect rewriting hostnames)
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.isAutomaticDataDetectionEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.smartInsertDeleteEnabled = false
        textView.textContainerInset = NSSize(width: 4, height: 8)
        // hosts is a line-oriented format; with soft wrapping off, gutter line numbers always match file lines.
        textView.isHorizontallyResizable = true
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.containerSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.delegate = context.coordinator
        textView.string = text
        Self.highlight(textView)
        scrollView.hasHorizontalScroller = true
        scrollView.contentView.postsBoundsChangedNotifications = true
        scrollView.verticalRulerView = HostsLineNumberRulerView(
            scrollView: scrollView,
            textView: textView
        )
        scrollView.hasVerticalRuler = true
        scrollView.rulersVisible = true
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.text = $text
        let textView = scrollView.documentView as! NSTextView
        textView.isEditable = isEditable
        textView.allowsUndo = isEditable
        let documentChanged = context.coordinator.documentID != documentID
        if documentChanged {
            context.coordinator.documentID = documentID
            // The undo stack belongs to the previous document; replaying it into this one
            // would splice the old document's text in.
            context.coordinator.textUndoManager.removeAllActions()
            // TextFinder highlights reference the previous content; drop the bar with them.
            if scrollView.isFindBarVisible {
                scrollView.isFindBarVisible = false
            }
        }
        // Guard against the delegate write-back loop. Compared through the storage's mutable
        // string proxy: `textView.string` would bridge the whole document into a fresh String
        // on every SwiftUI update, which at 200k lines is a few milliseconds each (#94).
        if let storage = textView.textStorage, !storage.mutableString.isEqual(to: text) {
            textView.string = text
            Self.highlight(textView)
            (scrollView.verticalRulerView as? HostsLineNumberRulerView)?.textDidReplace()
        }
        if documentChanged {
            textView.setSelectedRange(NSRange(location: 0, length: 0))
            textView.scroll(.zero)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, documentID: documentID)
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>
        var documentID: AnyHashable
        /// Dedicated undo manager so clearing it on a document switch cannot touch
        /// undo state registered elsewhere in the window (e.g. the name field).
        let textUndoManager = UndoManager()

        init(text: Binding<String>, documentID: AnyHashable) {
            self.text = text
            self.documentID = documentID
        }

        func undoManager(for view: NSTextView) -> UndoManager? {
            textUndoManager
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView, textView.isEditable else { return }
            text.wrappedValue = textView.string
            // Undo restores fragments with their old attributes; this also overwrites the flashed-back old colors
            HostsEditor.highlight(textView)
        }
    }

    /// At hosts scale (a few hundred lines) a full re-highlight per keystroke takes microseconds;
    /// beginEditing/endEditing coalesces it into one layout pass. Attribute-only changes never
    /// enter the undo registration path, so the undo stack stays clean.
    @MainActor
    private static func highlight(_ textView: NSTextView) {
        guard let storage = textView.textStorage else { return }
        storage.beginEditing()
        storage.addAttribute(
            .foregroundColor,
            value: NSColor.labelColor,
            range: NSRange(location: 0, length: storage.length)
        )
        for token in HostsSyntax.tokens(in: storage.string) {
            storage.addAttribute(.foregroundColor, value: color(for: token.kind), range: token.range)
        }
        storage.endEditing()
    }

    private static func color(for kind: HostsTokenKind) -> NSColor {
        switch kind {
        case .comment: .secondaryLabelColor
        case .ipAddress: .systemBlue
        case .hostname: .systemTeal
        }
    }
}

/// Whether an editable hosts editor currently holds keyboard focus (#86). The text view
/// publishes it here; the detail pane forwards it as a focused scene value, which is what
/// the Edit-menu "Toggle Comment" item keys its enabled state on — a `Commands` body does
/// not track `@Observable` reads, and a scene value also goes away with the key window.
@Observable
@MainActor
final class HostsEditorFocus {
    static let shared = HostsEditorFocus()
    private(set) var isEditableEditorFocused = false

    fileprivate func setEditableEditorFocused(_ focused: Bool) {
        if isEditableEditorFocused != focused {
            isEditableEditorFocused = focused
        }
    }
}

extension FocusedValues {
    @Entry var isHostsEditorEditable: Bool?
}

/// The hosts editor's text view: carries the editor-level actions that the Edit menu
/// dispatches down the responder chain (#86).
final class HostsTextView: NSTextView {
    override var isEditable: Bool {
        didSet {
            // Flipped from updateNSView on an in-place document switch; publish outside the
            // SwiftUI update pass, and only if focus has not moved on in the meantime.
            guard window?.firstResponder === self else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self, window?.firstResponder === self else { return }
                HostsEditorFocus.shared.setEditableEditorFocused(isEditable)
            }
        }
    }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted {
            HostsEditorFocus.shared.setEditableEditorFocused(isEditable)
        }
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned {
            HostsEditorFocus.shared.setEditableEditorFocused(false)
        }
        return resigned
    }

    /// Comments or uncomments the selected lines (the caret's line for an empty selection)
    /// as one undoable edit that goes through the regular text-change path, so the profile
    /// saves and merges exactly like a typed edit — including the held Remote Header
    /// conversion (ADR-0012).
    @objc func toggleComment(_ sender: Any?) {
        guard isEditable,
              let edit = HostsSyntax.toggleComment(in: string, range: selectedRange()),
              shouldChangeText(in: edit.editedRange, replacementString: edit.replacement)
        else { return }
        textStorage?.replaceCharacters(in: edit.editedRange, with: edit.replacement)
        didChangeText()
        setSelectedRange(edit.selection)
        scrollRangeToVisible(edit.selection)
    }
}

/// Never reads NSTextView.layoutManager, to avoid downgrading the main editor from TextKit 2.
/// The editor does not soft-wrap, so a fixed line-height font can locate visible logical lines directly.
@MainActor
final class HostsLineNumberRulerView: NSRulerView {
    private weak var textView: NSTextView?
    /// Cached: the draw runs on every scroll tick, and deriving the count there would copy and
    /// scan the whole document per frame (#94). Recomputed only when the text changes.
    private(set) var lineCount = 1

    init(scrollView: NSScrollView, textView: NSTextView) {
        self.textView = textView
        super.init(scrollView: scrollView, orientation: .verticalRuler)
        clientView = textView
        ruleThickness = 40
        recountLines()

        let center = NotificationCenter.default
        center.addObserver(
            self,
            selector: #selector(textDidChange(_:)),
            name: NSText.didChangeNotification,
            object: textView
        )
        center.addObserver(
            self,
            selector: #selector(invalidateRuler(_:)),
            name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView
        )
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// For text swapped in without an edit notification (a document switch).
    func textDidReplace() {
        recountLines()
        needsDisplay = true
    }

    @objc private func textDidChange(_ notification: Notification) {
        recountLines()
        needsDisplay = true
    }

    @objc private func invalidateRuler(_ notification: Notification) {
        needsDisplay = true
    }

    /// Counts newlines on the storage's mutable string proxy — UTF-16 search, no String bridge.
    private func recountLines() {
        guard let storage = textView?.textStorage else { return }
        let string = storage.mutableString
        var count = 1
        var searchRange = NSRange(location: 0, length: string.length)
        while true {
            let found = string.range(of: "\n", options: [.literal], range: searchRange)
            if found.location == NSNotFound { break }
            count += 1
            searchRange = NSRange(
                location: NSMaxRange(found),
                length: string.length - NSMaxRange(found)
            )
        }
        lineCount = count
    }

    override func draw(_ dirtyRect: NSRect) {
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: bounds).addClip()
        defer { NSGraphicsContext.restoreGraphicsState() }

        NSColor.textBackgroundColor.setFill()
        bounds.fill()
        drawHashMarksAndLabels(in: bounds)
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let textView, let font = textView.font else { return }

        let digits = max(2, String(lineCount).count)
        let desiredThickness = max(40, CGFloat(digits * 8 + 16))
        if ruleThickness != desiredThickness {
            ruleThickness = desiredThickness
        }

        let lineHeight = ceil(font.ascender - font.descender + font.leading)
        let inset = textView.textContainerInset.height
        let visibleRect = textView.visibleRect
        let firstLine = max(0, Int(floor((visibleRect.minY - inset) / lineHeight)))
        let lastLine = min(
            lineCount - 1,
            Int(ceil((visibleRect.maxY - inset) / lineHeight))
        )
        guard firstLine <= lastLine else { return }

        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = .right
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular),
            .foregroundColor: NSColor.tertiaryLabelColor,
            .paragraphStyle: paragraphStyle,
        ]

        for lineIndex in firstLine...lastLine {
            let point = convert(
                NSPoint(x: 0, y: inset + CGFloat(lineIndex) * lineHeight),
                from: textView
            )
            let labelRect = NSRect(
                x: 4,
                y: point.y,
                width: bounds.width - 10,
                height: lineHeight
            )
            String(lineIndex + 1).draw(in: labelRect, withAttributes: attributes)
        }

    }
}
