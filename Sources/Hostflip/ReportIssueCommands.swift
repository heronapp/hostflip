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
                // A menu action has no surface of its own for feedback; the settings pane
                // shows its confirmation inline instead.
                let alert = NSAlert()
                alert.messageText = String(localized: "Diagnostic report copied")
                alert.informativeText = String(localized: "Paste it into the issue's Diagnostic report field.")
                alert.runModal()
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
