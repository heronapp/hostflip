import AppKit
import SwiftUI

/// The hostflip menu bar icon: two host posts and a flippable crossbar.
/// Renders as a monochrome template by default; a tint opts out of template
/// mode because the status bar strips per-view foreground colors otherwise.
/// Dimming is baked into the image alpha for the same reason: the status bar
/// also flattens view-level `.opacity`.
struct HostflipGlyph: View {
    var tint: NSColor?
    var alpha: CGFloat = 1

    var body: some View {
        Image(nsImage: Self.makeImage(tint: tint, alpha: alpha))
            .renderingMode(tint == nil ? .template : .original)
            .resizable()
            .aspectRatio(1, contentMode: .fit)
            .accessibilityHidden(true)
    }

    static func makeImage(tint: NSColor? = nil, alpha: CGFloat = 1) -> NSImage {
        let color = (tint ?? .black).withAlphaComponent(alpha)
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
            return true
        }
        image.isTemplate = tint == nil
        return image
    }
}
