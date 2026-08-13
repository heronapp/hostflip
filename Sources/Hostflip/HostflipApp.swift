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
        Group {
            if store.switchFeedback == .merged {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else {
                HostflipGlyph()
                    .frame(width: 18, height: 18)
            }
        }
            .overlay(alignment: .topTrailing) {
                if store.hasHostsDrift {
                    Circle()
                        .fill(.red)
                        .frame(width: 6, height: 6)
                        .offset(x: 2, y: -1)
                }
            }
            .accessibilityLabel(
                store.hasHostsDrift ? "Hostflip, hosts drift detected" : "Hostflip"
            )
            .background {
                MainWindowActionInstaller(
                    applicationDelegate: applicationDelegate
                )
            }
            .task(id: store.switchFeedback) {
                guard store.switchFeedback == .merged else { return }
                MenuBarToast.show(message: store.switchFeedback?.message ?? "")
                do {
                    try await Task.sleep(for: .milliseconds(900))
                } catch {
                    MenuBarToast.hide()
                    return
                }
                MenuBarToast.hide()
                guard store.switchFeedback == .merged else { return }
                store.clearSwitchFeedback()
            }
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

        if hasProfiles {
            Divider()

            ForEach(groupsWithProfiles) { group in
                Menu(group.name) {
                    ForEach(group.profiles) { profile in
                        profileToggle(profile)
                    }
                }
                .disabled(store.isPaused || store.isSwitching || store.hasHostsDrift)
            }

            if !groupsWithProfiles.isEmpty, !store.standaloneProfiles.isEmpty {
                Divider()
            }

            ForEach(store.standaloneProfiles) { profile in
                profileToggle(profile)
            }
        } else {
            Divider()
            Text("No Profiles")
                .foregroundStyle(.secondary)
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
        Toggle(profile.name, isOn: Binding(
            get: { store.isActive(profile.id) },
            set: { active in
                startSwitch { store.setProfileActive(profile.id, active) }
            }
        ))
        .disabled(store.isPaused || store.isSwitching || store.hasHostsDrift)
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

@MainActor
private enum MenuBarToast {
    private static var panel: NSPanel?

    static func show(message: String) {
        hide()

        let content = HStack(spacing: 6) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
            Text(message)
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))

        let hostingView = NSHostingView(rootView: content)
        let contentSize = hostingView.fittingSize
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: contentSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.contentView = hostingView
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle]

        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        if let visibleFrame = screen?.visibleFrame {
            panel.setFrameOrigin(NSPoint(
                x: visibleFrame.maxX - contentSize.width - 12,
                y: visibleFrame.maxY - contentSize.height - 8
            ))
        }

        panel.orderFrontRegardless()
        self.panel = panel
    }

    static func hide() {
        panel?.orderOut(nil)
        panel = nil
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
