import AppKit
import SwiftUI

/// The hostflip menu bar template icon: two host posts and a flippable crossbar.
struct HostflipGlyph: View {
    var body: some View {
        Image(nsImage: Self.makeTemplateImage())
            .renderingMode(.template)
            .resizable()
            .aspectRatio(1, contentMode: .fit)
            .accessibilityHidden(true)
    }

    static func makeTemplateImage() -> NSImage {
        let image = NSImage(
            size: NSSize(width: 18, height: 18),
            flipped: true
        ) { _ in
            NSColor.black.setStroke()

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

            NSColor.black.setFill()
            NSBezierPath(
                ovalIn: NSRect(x: 7.85, y: 8.35, width: 2.3, height: 2.3)
            ).fill()
            return true
        }
        image.isTemplate = true
        return image
    }
}
