import HostflipXPC
import Sparkle
import SwiftUI

struct ApplicationSettingsView: View {
    let dockIconStore: DockIconVisibilityStore
    let launchAtLoginStore: LaunchAtLoginStore
    let updater: SPUUpdater

    var body: some View {
        TabView {
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
            .tabItem {
                Label("General", systemImage: "gearshape")
            }

            UpdatesSettingsView(updater: updater)
                .padding(20)
                .tabItem {
                    Label("Updates", systemImage: "arrow.triangle.2.circlepath")
                }
        }
        .frame(width: 460, height: 190)
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
