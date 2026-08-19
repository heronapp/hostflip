import AppKit
import HostflipCore

/// The one SwitchHosts import flow (#74/#75, ADR-0013), shared by the File menu entry and
/// the first-launch suggestion: discovery chain first, a manual folder picker as the
/// fallback, then the import summary or failure alert.
@MainActor
enum SwitchHostsImportFlow {
    static func run(store: WorkspaceStore) {
        NSApp.activate()
        if let directory = SwitchHostsDiscovery.discoverDataDirectory() {
            importAndPresent(store: store, directory: directory)
        } else if let directory = runFolderPanel() {
            importAndPresent(store: store, directory: directory)
        }
    }

    /// The first-launch one-time suggestion (#75): offered when SwitchHosts data is
    /// discoverable, then never again — accepting, declining, and the shown alert itself
    /// all burn the single offer; the File menu stays as the durable entry point.
    static func offerSuggestionIfNeeded(
        store: WorkspaceStore,
        suggestion: SwitchHostsImportSuggestion = SwitchHostsImportSuggestion()
    ) {
        guard store.model != nil,
              !suggestion.wasOffered,
              let directory = SwitchHostsDiscovery.discoverDataDirectory()
        else { return }
        suggestion.markOffered()

        let alert = NSAlert()
        alert.messageText = String(localized: "Import from SwitchHosts?")
        alert.informativeText = String(localized: "hostflip found existing SwitchHosts data on this Mac. Imported profiles arrive inactive, so nothing changes until you activate them. This suggestion appears only once; the File menu keeps an import entry.")
        alert.alertStyle = .informational
        alert.addButton(withTitle: String(localized: "Import"))
        alert.addButton(withTitle: String(localized: "Don’t Import"))
        NSApp.activate()
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        importAndPresent(store: store, directory: directory)
    }

    private static func importAndPresent(store: WorkspaceStore, directory: URL) {
        switch store.importSwitchHosts(at: directory) {
        case .imported(let summary):
            presentSummary(summary)
        case .failed(let message):
            presentFailure(store: store, message: message)
        }
    }

    /// The manual pick lands on either the data directory itself or a wrapper holding a
    /// `SwitchHosts.data/` store — the reader resolves both.
    private static func runFolderPanel() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.message = String(localized: "Select your SwitchHosts data folder")
        panel.prompt = String(localized: "Import")
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }

    private static func presentSummary(_ summary: SwitchHostsImportSummary) {
        let alert = NSAlert()
        alert.messageText = String(localized: "SwitchHosts Import Complete")
        alert.informativeText = SwitchHostsImportPresentation.paragraphs(for: summary)
            .joined(separator: "\n\n")
        alert.alertStyle = .informational
        alert.addButton(withTitle: String(localized: "OK"))
        alert.runModal()
    }

    /// Failure keeps the flow alive: a corrupt or stale marker in a discovered directory
    /// must not strand the user without the manual pick, so every failure alert offers
    /// choosing another folder and retrying through the same path.
    private static func presentFailure(store: WorkspaceStore, message: String) {
        let alert = NSAlert()
        alert.messageText = String(localized: "Import Failed")
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: String(localized: "Choose Folder…"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        guard alert.runModal() == .alertFirstButtonReturn,
              let directory = runFolderPanel() else { return }
        importAndPresent(store: store, directory: directory)
    }
}
