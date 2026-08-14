import HostflipXPC
import Sparkle
import SwiftUI

struct ApplicationSettingsView: View {
    let store: WorkspaceStore
    let maintenanceStore: MaintenanceStore
    let dockIconStore: DockIconVisibilityStore
    let launchAtLoginStore: LaunchAtLoginStore
    let updater: SPUUpdater

    // All four tabs share the classic settings-form look of Apple's own app
    // settings windows (right-aligned label column, controls left-aligned,
    // captions under their controls) — the app-settings convention, distinct
    // from the System Settings grouped cards. Top-aligned so switching tabs
    // never jumps; growth goes in as new rows — e.g. a future appearance
    // picker joins General.
    var body: some View {
        TabView {
            GeneralSettingsView(
                dockIconStore: dockIconStore,
                launchAtLoginStore: launchAtLoginStore
            )
            .frame(width: 500, height: 170, alignment: .top)
            .tabItem {
                Label("General", systemImage: "gearshape")
            }

            // Second home of helper management alongside the toolbar popover (#41):
            // Settings is where users expect to find privileged-component removal,
            // e.g. before uninstalling. The extra height leaves room for feedback.
            HelperSettingsPane(store: store, maintenanceStore: maintenanceStore)
                .frame(width: 500, height: 180, alignment: .topLeading)
                .tabItem {
                    Label("Helper", systemImage: "gearshape.2")
                }

            CLIInstallSection()
                .frame(width: 500, height: 260, alignment: .topLeading)
                .tabItem {
                    Label("Command Line", systemImage: "terminal")
                }

            UpdatesSettingsView(updater: updater)
                .frame(width: 500, height: 150, alignment: .top)
                .tabItem {
                    Label("Updates", systemImage: "arrow.triangle.2.circlepath")
                }
        }
    }
}

/// Everyday preferences; future rows (an appearance picker, say) join as more rows.
private struct GeneralSettingsView: View {
    let dockIconStore: DockIconVisibilityStore
    let launchAtLoginStore: LaunchAtLoginStore

    var body: some View {
        Form {
            Picker(
                "Show Dock Icon",
                selection: Binding(
                    get: { dockIconStore.policy },
                    set: { dockIconStore.setPolicy($0) }
                )
            ) {
                ForEach(DockIconVisibilityPolicy.allCases, id: \.rawValue) { policy in
                    Text(policy.title).tag(policy)
                }
            }
            Text("The menu bar icon is always shown.")
                .font(.callout)
                .foregroundStyle(.secondary)

            Toggle("Launch at Login", isOn: Binding(
                get: { launchAtLoginStore.isEnabled },
                set: { launchAtLoginStore.setEnabled($0) }
            ))
            Text("hostflip starts silently in the menu bar when you log in.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(20)
    }
}

/// The discoverable home of update checking (#34); Sparkle owns the persisted
/// automatic-check preference, this view only mirrors it.
private struct UpdatesSettingsView: View {
    let updater: SPUUpdater
    @State private var automaticallyChecksForUpdates: Bool

    init(updater: SPUUpdater) {
        self.updater = updater
        automaticallyChecksForUpdates = updater.automaticallyChecksForUpdates
    }

    var body: some View {
        Form {
            LabeledContent("Current Version") {
                Text("v\(HostflipBuild.version)")
                    .foregroundStyle(.secondary)
            }

            Toggle("Automatically check for updates", isOn: $automaticallyChecksForUpdates)
                .onChange(of: automaticallyChecksForUpdates) { _, newValue in
                    updater.automaticallyChecksForUpdates = newValue
                }

            CheckForUpdatesButton(updater: updater)
        }
        .padding(20)
    }
}

/// Sparkle drives the whole check-and-install flow with its own UI; this button only forwards the
/// click and mirrors `canCheckForUpdates` (false while a check or install is already in flight).
struct CheckForUpdatesButton: View {
    @ObservedObject private var viewModel: CheckForUpdatesViewModel
    private let updater: SPUUpdater

    init(updater: SPUUpdater) {
        self.updater = updater
        viewModel = CheckForUpdatesViewModel(updater: updater)
    }

    var body: some View {
        Button("Check for Updates") {
            updater.checkForUpdates()
        }
        .disabled(!viewModel.canCheckForUpdates)
    }
}

@MainActor
final class CheckForUpdatesViewModel: ObservableObject {
    @Published var canCheckForUpdates = false

    init(updater: SPUUpdater) {
        updater.publisher(for: \.canCheckForUpdates)
            .assign(to: &$canCheckForUpdates)
    }
}
