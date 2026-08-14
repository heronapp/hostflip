import HostflipXPC
import SwiftUI

struct HelperStatusPresentation {
    let title: String
    let description: String
    let color: Color
    let canRemove: Bool
    let canOpenApprovalSettings: Bool

    init(_ status: DaemonRegistrationStatus?) {
        switch status {
        case .enabled:
            title = "Helper Ready"
            description = "The helper is approved and ready to update the system hosts file."
            color = .green
            canRemove = true
            canOpenApprovalSettings = false
        case .requiresApproval:
            title = "Helper Approval Required"
            description = "The helper is waiting for approval in System Settings. Switching remains blocked until it is approved."
            color = .orange
            canRemove = true
            canOpenApprovalSettings = true
        case .notRegistered, .notFound:
            // SMAppService reports .notFound for a daemon that was never
            // registered (docs/helper-reregistration-verification.md step 1), so
            // both states are the pristine "not installed yet" condition —
            // registration is lazily triggered by the first switch (ADR-0002).
            // A genuinely broken install (wrong location, policy block) surfaces
            // through switch feedback, not through this passive light.
            title = "Helper Not Installed"
            description = "Switch a profile to install the helper. macOS may ask you to approve it."
            color = .secondary
            canRemove = false
            canOpenApprovalSettings = false
        case nil:
            title = "Checking Helper…"
            description = "Checking the helper registration status…"
            color = .secondary
            canRemove = false
            canOpenApprovalSettings = false
        }
    }
}

/// Persistent status light in the title bar: tells ready, pending approval, unregistered, and unavailable apart without opening the panel.
struct HelperStatusLabel: View {
    let status: DaemonRegistrationStatus?

    var body: some View {
        let presentation = HelperStatusPresentation(status)
        HStack(spacing: 5) {
            Image(systemName: "circle.fill")
                .font(.system(size: 7))
                .foregroundStyle(presentation.color)
            Text(presentation.title)
                .font(.caption)
        }
    }
}

/// User-facing maintenance panel: the entry point for helper management.
/// Update checks moved to Settings > Updates (#34).
struct HelperMaintenanceView: View {
    let store: WorkspaceStore
    let maintenanceStore: MaintenanceStore
    let onDismiss: (() -> Void)?
    @Environment(\.dismiss) private var dismiss

    init(
        store: WorkspaceStore,
        maintenanceStore: MaintenanceStore,
        onDismiss: (() -> Void)? = nil
    ) {
        self.store = store
        self.maintenanceStore = maintenanceStore
        self.onDismiss = onDismiss
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Maintenance")
                .font(.headline)

            HelperMaintenanceSection(
                store: store,
                maintenanceStore: maintenanceStore,
                beforeOpeningSystemSettings: { close() }
            )
        }
        .padding(16)
        .frame(width: 380)
    }

    private func close() {
        if let onDismiss {
            onDismiss()
        } else {
            dismiss()
        }
    }
}

/// Shared body of the helper management UI: status, approval shortcut, removal with
/// confirmation, and operation feedback. Hosted by the toolbar popover and by
/// Settings > Helper (#41); both hand it the same MaintenanceStore instance, so the
/// two entry points can never disagree.
struct HelperMaintenanceSection: View {
    let store: WorkspaceStore
    let maintenanceStore: MaintenanceStore
    /// Runs before jumping to System Settings; the popover closes itself here.
    var beforeOpeningSystemSettings: () -> Void = {}

    var body: some View {
        let helperPresentation = HelperStatusPresentation(maintenanceStore.helperStatus)
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 8) {
                Label("Background Helper", systemImage: "gearshape.2")
                    .font(.subheadline.weight(.semibold))
                HelperStatusLabel(status: maintenanceStore.helperStatus)
                Text(helperPresentation.description)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if helperPresentation.canOpenApprovalSettings || helperPresentation.canRemove {
                    HStack {
                        if helperPresentation.canOpenApprovalSettings {
                            Button("Open System Settings…") {
                                beforeOpeningSystemSettings()
                                store.openApprovalSettings()
                            }
                        }
                        Spacer()
                        if helperPresentation.canRemove {
                            HelperRemovalButton(maintenanceStore: maintenanceStore)
                        }
                    }
                    .controlSize(.small)
                }
            }

            if let feedback = maintenanceStore.feedback {
                MaintenanceFeedbackLabel(feedback: feedback)
            }
        }
        .task { await maintenanceStore.refreshHelperStatus() }
    }
}

/// Settings > Helper: the same status and removal flow as the popover, laid out as a
/// label-less full-width block like the Command Line tab (the tab title already names
/// the pane). Both homes share the store and the controls below, so they can never
/// disagree (#41).
struct HelperSettingsPane: View {
    let store: WorkspaceStore
    let maintenanceStore: MaintenanceStore

    var body: some View {
        let presentation = HelperStatusPresentation(maintenanceStore.helperStatus)
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                HelperStatusLabel(status: maintenanceStore.helperStatus)
                Text(presentation.description)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if presentation.canOpenApprovalSettings {
                Button("Open System Settings…") {
                    store.openApprovalSettings()
                }
            }

            if presentation.canRemove {
                HelperRemovalButton(maintenanceStore: maintenanceStore)
            }

            if let feedback = maintenanceStore.feedback {
                MaintenanceFeedbackLabel(feedback: feedback)
            }
        }
        .padding(20)
        .task { await maintenanceStore.refreshHelperStatus() }
    }
}

/// The destructive removal flow — confirmation dialog, in-flight progress, retry title —
/// shared by the popover and Settings so the two homes can never diverge.
struct HelperRemovalButton: View {
    let maintenanceStore: MaintenanceStore
    @State private var isConfirmingRemoval = false

    var body: some View {
        HStack {
            if maintenanceStore.isRemovingHelper {
                ProgressView()
                    .controlSize(.small)
            }
            Button(title, role: .destructive) {
                isConfirmingRemoval = true
            }
            .disabled(maintenanceStore.isRemovingHelper)
        }
        .confirmationDialog(
            "Deactivate and Remove Helper?",
            isPresented: $isConfirmingRemoval,
            titleVisibility: .visible
        ) {
            Button("Deactivate and Remove", role: .destructive) {
                Task { await maintenanceStore.removeHelper() }
            }
        } message: {
            Text("hostflip will remove its privileged helper. Your profiles and base hosts will stay in the workspace. The helper will be requested again on your next switch.\n\nThe system hosts file keeps its current content — entries from active profiles stay in effect. To leave only Base Hosts applied (e.g. before uninstalling), turn off the master switch first.")
        }
    }

    private var title: String {
        if case .helperRemovalFailed = maintenanceStore.feedback {
            return "Retry Remove Helper…"
        }
        return "Deactivate and Remove Helper…"
    }
}

/// Outcome of the last maintenance operation, rendered identically in both homes.
struct MaintenanceFeedbackLabel: View {
    let feedback: MaintenanceFeedback

    var body: some View {
        let presentation = feedback.presentation
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(presentation.title)
                    .fontWeight(.semibold)
                Text(presentation.message)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } icon: {
            Image(
                systemName: presentation.isFailure
                    ? "xmark.octagon.fill"
                    : "checkmark.circle.fill"
            )
        }
        .font(.callout)
        .foregroundStyle(presentation.isFailure ? .red : .green)
    }
}
