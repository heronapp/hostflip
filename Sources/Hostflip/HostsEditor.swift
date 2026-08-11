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

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        let textView = scrollView.documentView as! NSTextView
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
        if textView.string != text { // guard against the delegate write-back loop
            textView.string = text
            Self.highlight(textView)
            scrollView.verticalRulerView?.needsDisplay = true
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>

        init(text: Binding<String>) {
            self.text = text
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

/// Never reads NSTextView.layoutManager, to avoid downgrading the main editor from TextKit 2.
/// The editor does not soft-wrap, so a fixed line-height font can locate visible logical lines directly.
@MainActor
private final class HostsLineNumberRulerView: NSRulerView {
    private weak var textView: NSTextView?

    init(scrollView: NSScrollView, textView: NSTextView) {
        self.textView = textView
        super.init(scrollView: scrollView, orientation: .verticalRuler)
        clientView = textView
        ruleThickness = 40

        let center = NotificationCenter.default
        center.addObserver(
            self,
            selector: #selector(invalidateRuler(_:)),
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

    @objc private func invalidateRuler(_ notification: Notification) {
        needsDisplay = true
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

        let lineCount = textView.string.reduce(into: 1) { count, character in
            if character == "\n" { count += 1 }
        }
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
