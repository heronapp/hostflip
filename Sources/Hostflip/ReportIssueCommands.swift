import AppKit
import SwiftUI

/// Help menu "Report an Issue…" and "Copy Diagnostic Report" (#90). Both are read-only and
/// need neither the helper nor an unpaused app; the report never leaves the machine unless
/// the user pastes it.
struct ReportIssueCommands: Commands {
    let store: WorkspaceStore
    let maintenanceStore: MaintenanceStore

    var body: some Commands {
        CommandGroup(after: .help) {
            Divider()
            Button("Report an Issue…") {
                ProblemReporting.openNewIssue(store: store, maintenanceStore: maintenanceStore)
            }
            Button("Copy Diagnostic Report") {
                ProblemReporting.copyReport(store: store, maintenanceStore: maintenanceStore)
                // A menu action has no surface of its own; a short floating notice beats a
                // modal alert for a clipboard write.
                TransientNotice.show(String(localized: "Diagnostic report copied"))
            }
        }
    }
}

@MainActor
enum ProblemReporting {
    static func openNewIssue(store: WorkspaceStore, maintenanceStore: MaintenanceStore) {
        let snapshot = DiagnosticSnapshot.current(store: store, maintenanceStore: maintenanceStore)
        NSWorkspace.shared.open(DiagnosticReport.issueURL(for: snapshot))
    }

    static func copyReport(store: WorkspaceStore, maintenanceStore: MaintenanceStore) {
        let snapshot = DiagnosticSnapshot.current(store: store, maintenanceStore: maintenanceStore)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(DiagnosticReport.text(for: snapshot), forType: .string)
    }
}

/// A small non-activating panel that fades out on its own — feedback for actions fired from
/// the menu bar, where there may not even be a key window to attach a sheet to.
@MainActor
enum TransientNotice {
    private static var panel: NSPanel?

    static func show(_ message: String, for duration: Duration = .seconds(1.5)) {
        panel?.close()
        let label = NSTextField(labelWithString: message)
        label.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .medium)
        label.alignment = .center
        let content = NSVisualEffectView()
        content.material = .hudWindow
        content.blendingMode = .behindWindow
        content.state = .active
        content.wantsLayer = true
        content.layer?.cornerRadius = 10
        content.addSubview(label)
        label.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 18),
            label.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -18),
            label.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
            label.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12),
        ])
        let panel = NSPanel(
            contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.contentView = content
        panel.setContentSize(content.fittingSize)
        if let screen = NSScreen.main {
            let frame = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(
                x: frame.midX - panel.frame.width / 2,
                y: frame.maxY - panel.frame.height - 40
            ))
        }
        panel.orderFrontRegardless()
        self.panel = panel
        Task {
            try? await Task.sleep(for: duration)
            guard self.panel === panel else { return }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.25
                panel.animator().alphaValue = 0
            } completionHandler: {
                panel.close()
                if self.panel === panel { self.panel = nil }
            }
        }
    }
}
