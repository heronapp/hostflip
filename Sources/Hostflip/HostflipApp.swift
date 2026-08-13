import AppKit
import HostflipCore
import HostflipXPC
import Sparkle
import SwiftUI

/// Menu bar quick switching (#23) + main window (#20).
struct HostflipApp: App {
    @NSApplicationDelegateAdaptor(ApplicationLifecycleDelegate.self)
    private var applicationDelegate

    private let store: WorkspaceStore
    private let maintenanceStore: MaintenanceStore
    private let dockIconStore: DockIconVisibilityStore
    private let launchAtLoginStore = LaunchAtLoginStore()
    /// Sparkle owns the whole update pipeline (scheduled checks, download, install, relaunch); see ADR-0007.
    private let updaterController: SPUStandardUpdaterController

    init() {
        let dockIconStore = DockIconVisibilityStore()
        let registrar = DaemonRegistrar()
        let store = WorkspaceStore(registrar: registrar)
        let maintenanceStore = MaintenanceStore(
            helperStatus: { await registrar.refreshStatus() },
            unregisterHelper: { try await registrar.unregister() }
        )
        updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        store.loadIfNeeded()
        self.store = store
        self.maintenanceStore = maintenanceStore
        self.dockIconStore = dockIconStore
        // Recheck the actual registration status on every launch and re-register as needed (self-heal on version change, #19)
        Task { [registrar, maintenanceStore] in
            _ = await registrar.healOnLaunch()
            await maintenanceStore.refreshHelperStatus()
        }
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarContent(store: store, applicationDelegate: applicationDelegate)
        } label: {
            MenuBarLabel(
                store: store,
                applicationDelegate: applicationDelegate
            )
        }
        .menuBarExtraStyle(.menu)

        Window("hostflip", id: "main") {
            MainWindowView(store: store, maintenanceStore: maintenanceStore)
                .onAppear {
                    dockIconStore.mainWindowDidOpen()
                }
                .onDisappear {
                    dockIconStore.mainWindowDidClose()
                }
        }
        .defaultSize(width: 820, height: 560)
        .commands {
            ImportExportCommands(store: store)
        }

        Settings {
            ApplicationSettingsView(
                store: store,
                maintenanceStore: maintenanceStore,
                dockIconStore: dockIconStore,
                launchAtLoginStore: launchAtLoginStore,
                updater: updaterController.updater
            )
        }
    }
}

private struct MenuBarLabel: View {
    let store: WorkspaceStore
    let applicationDelegate: ApplicationLifecycleDelegate

    var body: some View {
        HostflipGlyph(
            alpha: store.isPaused ? 0.45 : 1,
            showsAlertDot: store.hasHostsDrift
        )
            .frame(width: 18, height: 18)
            .accessibilityLabel(accessibilityLabelText)
            .background {
                MainWindowActionInstaller(
                    applicationDelegate: applicationDelegate
                )
            }
    }

    private var accessibilityLabelText: String {
        var label = "Hostflip"
        if store.isPaused { label += ", paused" }
        if store.hasHostsDrift { label += ", hosts drift detected" }
        return label
    }
}

private struct MenuBarContent: View {
    let store: WorkspaceStore
    let applicationDelegate: ApplicationLifecycleDelegate
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Toggle("Enable hostflip", isOn: Binding(
            get: { !store.isPaused },
            set: { enabled in
                startSwitch { store.setPaused(!enabled) }
            }
        ))
        .disabled(store.model == nil || store.isSwitching || store.hasHostsDrift)

        if store.hasHostsDrift {
            Button("Hosts file changed externally — Review…") {
                applicationDelegate.requestMainWindow()
            }
        }

        if hasProfiles {
            Divider()

            ForEach(store.standaloneProfiles) { profile in
                profileToggle(profile)
            }

            if !groupsWithProfiles.isEmpty, !store.standaloneProfiles.isEmpty {
                Divider()
            }

            ForEach(groupsWithProfiles) { group in
                Menu {
                    ForEach(group.profiles) { profile in
                        profileToggle(profile)
                    }
                } label: {
                    Text(menuItemTitle(group.name))
                }
                .badge(activeProfileName(in: group).map(Text.init))
                .disabled(store.isPaused || store.isSwitching || store.hasHostsDrift)
            }
        } else {
            Divider()
            Button("No profiles yet — create one…") {
                applicationDelegate.requestMainWindow()
            }
        }

        Divider()

        Button("Open hostflip…") {
            applicationDelegate.requestMainWindow()
        }

        Button("Settings…") {
            openSettings()
            NSApp.activate()
        }
        .keyboardShortcut(",", modifiers: .command)

        Divider()

        Button("Quit hostflip") {
            NSApp.terminate(nil)
        }
        .keyboardShortcut("q", modifiers: .command)
    }

    private func profileToggle(_ profile: Profile) -> some View {
        Toggle(isOn: Binding(
            get: { store.isActive(profile.id) },
            set: { active in
                startSwitch { store.setProfileActive(profile.id, active) }
            }
        )) {
            Text(menuItemTitle(profile.name))
        }
        .disabled(store.isPaused || store.isSwitching || store.hasHostsDrift)
    }

    /// Modern macOS no longer dims disabled menu rows with custom labels, so
    /// paused rows gray themselves out through the attributed title instead.
    private func menuItemTitle(_ name: String) -> AttributedString {
        var title = AttributedString(name)
        if store.isPaused {
            title.foregroundColor = .secondary
        }
        return title
    }

    private func activeProfileName(in group: HostflipCore.Group) -> String? {
        group.profiles.first { store.isActive($0.id) }?.name
    }

    private var groupsWithProfiles: [HostflipCore.Group] {
        store.groups.filter { !$0.profiles.isEmpty }
    }

    private var hasProfiles: Bool {
        !groupsWithProfiles.isEmpty || !store.standaloneProfiles.isEmpty
    }

    /// After a menu click, waits for the shared switch path to conclude; on failure, immediately presents the same copy as the main window.
    private func startSwitch(_ action: () -> Void) {
        action()
        guard let switchTask = store.switchTask else {
            if let feedback = store.switchFeedback, feedback != .merged {
                present(feedback)
            }
            return
        }
        Task { @MainActor in
            await switchTask.value
            await Task.yield()
            guard let feedback = store.switchFeedback, feedback != .merged else { return }
            present(feedback)
        }
    }

    private func present(_ feedback: SwitchFeedback) {
        let alert = NSAlert()
        alert.messageText = feedback.title
        alert.informativeText = feedback.message
        alert.alertStyle = feedback.isFailure ? .critical : .warning

        if feedback == .needsApproval {
            alert.addButton(withTitle: "Open System Settings…")
            alert.addButton(withTitle: "Later")
        } else {
            alert.addButton(withTitle: "OK")
        }

        NSApp.activate()
        let response = alert.runModal()
        if feedback == .needsApproval, response == .alertFirstButtonReturn {
            store.openApprovalSettings()
        }
    }
}

private extension SwitchFeedback {
    var isFailure: Bool {
        if case .failed = self {
            true
        } else {
            false
        }
    }
}
