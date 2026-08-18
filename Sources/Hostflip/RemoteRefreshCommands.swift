import HostflipCore
import SwiftUI

/// File menu "Refresh All Remote Profiles" (#70, ADR-0012): the bulk manual refresh entry;
/// per-profile Refresh Now lives in the sidebar row menus. Outcomes surface passively through
/// the row and menu bar status markers — the command itself shows no result dialog.
struct RemoteRefreshCommands: Commands {
    let store: WorkspaceStore

    var body: some Commands {
        CommandGroup(after: .importExport) {
            Divider()
            Button("Refresh All Remote Profiles") {
                Task { await store.refreshAllRemoteProfiles() }
            }
            .disabled(store.remoteProfiles.isEmpty || !store.refreshingProfileIDs.isEmpty)
        }
    }
}
