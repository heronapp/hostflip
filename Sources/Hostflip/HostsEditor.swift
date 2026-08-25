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
        // Soft wrapping stays on (the scrollableTextView default): with widthTracksTextView off,
        // TextKit 2 lays out the whole document up front instead of the viewport — seconds and a
        // 4x per-scroll cost on a 90k-line Remote Profile (#94). The gutter maps wrapped rows
        // back to file lines through the layout fragments.
        textView.delegate = context.coordinator
        textView.string = text
        Self.highlight(textView)
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

/// Never reads NSTextView.layoutManager, to avoid downgrading the main editor from TextKit 2;
/// it walks the TextKit 2 layout fragments of the visible rows instead. A fragment is one
/// paragraph, i.e. one file line, so a wrapped line gets its number on its first row only.
@MainActor
final class HostsLineNumberRulerView: NSRulerView {
    private weak var textView: NSTextView?
    /// UTF-16 offsets at which each file line starts. Cached: the draw runs on every scroll
    /// tick, and deriving this there would copy and scan the whole document per frame (#94).
    /// Recomputed only when characters change — observed on the storage rather than through
    /// NSText.didChangeNotification, which undo does not post. Read-only in didProcessEditing:
    /// the attribute-merging hazard noted at the top of the file only concerns mutating the
    /// storage from there.
    private(set) var lineStarts: [Int] = [0]
    var lineCount: Int { lineStarts.count }
    /// 1-based numbers of structurally incomplete lines (#87), rebuilt with `lineStarts`.
    /// The gutter only warns — saving and merging are untouched; the CLI's `write` is the
    /// one that refuses such content.
    private(set) var incompleteLines: Set<Int> = []
    static let incompleteLineTooltip = String(
        localized: "This line has a single field; every entry needs an IP address and at least one hostname."
    )

    init(scrollView: NSScrollView, textView: NSTextView) {
        self.textView = textView
        super.init(scrollView: scrollView, orientation: .verticalRuler)
        clientView = textView
        ruleThickness = 40
        rebuildLineStarts()
        addToolTip(bounds, owner: self, userData: nil)

        let center = NotificationCenter.default
        center.addObserver(
            self,
            selector: #selector(storageDidProcessEditing(_:)),
            name: NSTextStorage.didProcessEditingNotification,
            object: textView.textStorage
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

    @objc private func storageDidProcessEditing(_ notification: Notification) {
        guard let storage = notification.object as? NSTextStorage,
              storage.editedMask.contains(.editedCharacters) else { return } // highlighting only
        rebuildLineStarts()
        needsDisplay = true
    }

    @objc private func invalidateRuler(_ notification: Notification) {
        needsDisplay = true
    }

    /// Finds newlines on the storage's mutable string proxy — UTF-16 search, no String bridge.
    private func rebuildLineStarts() {
        guard let storage = textView?.textStorage else { return }
        let string = storage.mutableString
        var starts = [0]
        var searchRange = NSRange(location: 0, length: string.length)
        while true {
            let found = string.range(of: "\n", options: [.literal], range: searchRange)
            if found.location == NSNotFound { break }
            starts.append(NSMaxRange(found))
            searchRange = NSRange(
                location: NSMaxRange(found),
                length: string.length - NSMaxRange(found)
            )
        }
        lineStarts = starts
        // Bridges the document once per character edit — the same order of work as the
        // highlighting pass, and large Remote Profiles are read-only, so this runs on load only.
        incompleteLines = Set(HostsSyntax.incompleteLines(in: string as String))

        // Sized here, not in draw: changing the thickness re-tiles the scroll view, and doing
        // that mid-draw left the clip view scrolled sideways by the width difference.
        // Digits right-aligned, plus a marker column on the left (#87).
        let digits = max(2, String(lineCount).count)
        let desiredThickness = max(40, CGFloat(digits * 7 + 24))
        if ruleThickness != desiredThickness {
            ruleThickness = desiredThickness
            if let clipView = scrollView?.contentView {
                clipView.scroll(to: NSPoint(x: 0, y: clipView.bounds.origin.y))
            }
        }
    }

    /// 1-based number of the file line containing the UTF-16 offset.
    func lineNumber(at offset: Int) -> Int {
        var low = 0, high = lineStarts.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if lineStarts[mid] <= offset { low = mid } else { high = mid - 1 }
        }
        return low + 1
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        removeAllToolTips()
        addToolTip(bounds, owner: self, userData: nil)
    }

    /// NSViewToolTipOwner: the tooltip is served per row, only markers explain themselves.
    @objc func view(
        _ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint, userData: UnsafeMutableRawPointer?
    ) -> String {
        guard let textView, let labels = labels(in: textView.visibleRect) else { return "" }
        let y = convert(point, to: textView).y
        guard let label = labels.first(where: { $0.y <= y && y < $0.y + $0.height }),
              incompleteLines.contains(label.line)
        else { return "" }
        return Self.incompleteLineTooltip
    }

    override func draw(_ dirtyRect: NSRect) {
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: bounds).addClip()
        defer { NSGraphicsContext.restoreGraphicsState() }

        NSColor.textBackgroundColor.setFill()
        bounds.fill()
        drawHashMarksAndLabels(in: bounds)
    }

    /// One gutter label: a file line number and the text-view-space row it sits on.
    struct Label: Equatable {
        let line: Int
        let y: CGFloat
        let height: CGFloat
    }

    /// The labels for the rows intersecting `visibleRect` (text view coordinates), walking
    /// only what the viewport controller has already laid out: asking for layout from here
    /// (ensuresLayout / textLayoutFragment(for:)) cancels TextKit 2's idle estimation of the
    /// document height, and the view then cannot scroll past the first screen. Returns nil
    /// when nothing is laid out yet (first frame, or a document just swapped in).
    func labels(in visibleRect: NSRect) -> [Label]? {
        guard let textView,
              let layoutManager = textView.textLayoutManager,
              let contentManager = layoutManager.textContentManager,
              let storage = textView.textStorage
        else { return [] }
        let origin = textView.textContainerOrigin

        guard storage.length > 0 else {
            // An empty document has no fragments to walk, but still one line.
            guard let font = textView.font else { return [] }
            return [Label(line: 1, y: origin.y, height: ceil(font.ascender - font.descender + font.leading))]
        }
        guard let viewport = layoutManager.textViewportLayoutController.viewportRange,
              viewport.location.compare(layoutManager.documentRange.endLocation) == .orderedAscending
        else { return nil }

        let documentStart = contentManager.documentRange.location
        var labels: [Label] = []
        var lastFragment: NSTextLayoutFragment?
        layoutManager.enumerateTextLayoutFragments(from: viewport.location, options: []) { fragment in
            let frame = fragment.layoutFragmentFrame
            guard frame.minY + origin.y < visibleRect.maxY,
                  fragment.rangeInElement.location.compare(viewport.endLocation) == .orderedAscending
            else { return false }
            guard frame.maxY + origin.y > visibleRect.minY else { return true }
            let offset = contentManager.offset(from: documentStart, to: fragment.rangeInElement.location)
            // Only the first row of a wrapped line carries the number.
            let firstRowHeight = fragment.textLineFragments.first?.typographicBounds.height ?? frame.height
            labels.append(Label(line: lineNumber(at: offset), y: frame.minY + origin.y, height: firstRowHeight))
            lastFragment = fragment
            return true
        }

        // A trailing newline opens an empty last line; TextKit 2 renders it as an extra line
        // fragment inside the last layout fragment rather than as a fragment of its own.
        if let lastFragment, storage.mutableString.hasSuffix("\n"),
           contentManager.offset(from: documentStart, to: lastFragment.rangeInElement.endLocation) == storage.length,
           let emptyRow = lastFragment.textLineFragments.last?.typographicBounds {
            let y = lastFragment.layoutFragmentFrame.minY + emptyRow.minY + origin.y
            if y < visibleRect.maxY {
                labels.append(Label(line: lineCount, y: y, height: emptyRow.height))
            }
        }
        return labels
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let textView else { return }
        guard let labels = labels(in: textView.visibleRect) else {
            // Come back once the viewport has been laid out; no bounds change may follow.
            DispatchQueue.main.async { [weak self] in self?.needsDisplay = true }
            return
        }
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = .right
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular),
            .foregroundColor: NSColor.tertiaryLabelColor,
            .paragraphStyle: paragraphStyle,
        ]
        let marker = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(
                NSImage.SymbolConfiguration(pointSize: 9, weight: .bold)
                    .applying(.init(paletteColors: [.systemYellow]))
            )
        for label in labels {
            let point = convert(NSPoint(x: 0, y: label.y), from: textView)
            let labelRect = NSRect(x: 4, y: point.y, width: bounds.width - 10, height: label.height)
            String(label.line).draw(in: labelRect, withAttributes: attributes)
            if incompleteLines.contains(label.line), let marker {
                let size = marker.size
                let markerRect = NSRect(
                    x: 3, y: point.y + (label.height - size.height) / 2, width: size.width, height: size.height
                )
                marker.draw(
                    in: markerRect, from: .zero, operation: .sourceOver, fraction: 1,
                    respectFlipped: true, hints: nil
                )
            }
        }
    }
}
