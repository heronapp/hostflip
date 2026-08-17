import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// File menu Import…/Export… (#40, ADR-0008): manual entry points using the standard panels.
struct ImportExportCommands: Commands {
    let store: WorkspaceStore

    var body: some Commands {
        CommandGroup(replacing: .importExport) {
            Button("Import…") {
                runImportPanel()
            }
            .disabled(store.model == nil)

            Button("Export…") {
                runExportPanel()
            }
            .disabled(store.model == nil)
        }
    }

    /// One panel for both formats: the reader tells export files and plain hosts text apart.
    @MainActor
    private func runImportPanel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        NSApp.activate()
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        if case .failed(let message) = store.importFiles(at: panel.urls) {
            presentError(title: String(localized: "Import Failed"), message: message)
        }
    }

    @MainActor
    private func runExportPanel() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = defaultExportFileName()
        NSApp.activate()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            guard let data = try store.exportSnapshotData() else { return }
            try data.write(to: url, options: .atomic)
        } catch {
            presentError(
                title: String(localized: "Export Failed"),
                message: String(localized: "Nothing was exported: \(String(describing: error))")
            )
        }
    }

    private func defaultExportFileName() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return "hostflip-\(formatter.string(from: .now)).json"
    }

    @MainActor
    private func presentError(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: String(localized: "OK"))
        alert.runModal()
    }
}
