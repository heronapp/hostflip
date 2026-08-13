import AppKit
import SwiftUI

/// The hostflip menu bar icon: two host posts and a flippable crossbar.
/// Renders as a monochrome template by default. All state is baked into the
/// image because the status bar strips per-view foreground colors, view-level
/// `.opacity`, and overlay content from the label: dimming lowers the drawing
/// alpha, and the drift alert draws a red dot in a non-template image whose
/// glyph uses the dynamic label color instead.
struct HostflipGlyph: View {
    var alpha: CGFloat = 1
    var showsAlertDot = false

    var body: some View {
        Image(nsImage: Self.makeImage(alpha: alpha, alertDot: showsAlertDot))
            .renderingMode(showsAlertDot ? .original : .template)
            .resizable()
            .aspectRatio(1, contentMode: .fit)
            .accessibilityHidden(true)
    }

    static func makeImage(alpha: CGFloat = 1, alertDot: Bool = false) -> NSImage {
        let color = (alertDot ? NSColor.labelColor : .black).withAlphaComponent(alpha)
        let image = NSImage(
            size: NSSize(width: 18, height: 18),
            flipped: true
        ) { _ in
            color.setStroke()

            let posts = NSBezierPath()
            posts.lineWidth = 2.5
            posts.lineCapStyle = .round
            posts.move(to: NSPoint(x: 4.3, y: 3.7))
            posts.line(to: NSPoint(x: 4.3, y: 14.3))
            posts.move(to: NSPoint(x: 13.7, y: 3.7))
            posts.line(to: NSPoint(x: 13.7, y: 14.3))
            posts.stroke()

            let crossbar = NSBezierPath()
            crossbar.lineWidth = 2
            crossbar.lineCapStyle = .round
            crossbar.move(to: NSPoint(x: 6.2, y: 10.15))
            crossbar.line(to: NSPoint(x: 11.8, y: 8.85))
            crossbar.stroke()

            color.setFill()
            NSBezierPath(
                ovalIn: NSRect(x: 7.85, y: 8.35, width: 2.3, height: 2.3)
            ).fill()

            if alertDot {
                NSColor.systemRed.setFill()
                NSBezierPath(
                    ovalIn: NSRect(x: 12, y: 0, width: 6, height: 6)
                ).fill()
            }
            return true
        }
        image.isTemplate = !alertDot
        return image
    }
}
