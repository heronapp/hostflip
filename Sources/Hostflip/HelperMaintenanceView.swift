import HostflipXPC
import SwiftUI

private struct HelperStatusPresentation {
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
        case .notRegistered:
            title = "Helper Not Installed"
            description = "Switch a profile to install the helper. macOS may ask you to approve it."
            color = .secondary
            canRemove = false
            canOpenApprovalSettings = false
        case .notFound:
            title = "Helper Unavailable"
            description = "The helper is unavailable. Move hostflip to Applications or reinstall the app."
            color = .red
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

/// User-facing maintenance panel: the entry point for both helper management and update checks.
struct HelperMaintenanceView: View {
    let store: WorkspaceStore
    let maintenanceStore: MaintenanceStore
    let onDismiss: (() -> Void)?
    @Environment(\.dismiss) private var dismiss
    @State private var isConfirmingRemoval = false

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
        let helperPresentation = HelperStatusPresentation(maintenanceStore.helperStatus)
        VStack(alignment: .leading, spacing: 14) {
            Text("Maintenance")
                .font(.headline)

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
                                close()
                                store.openApprovalSettings()
                            }
                        }
                        Spacer()
                        if maintenanceStore.isRemovingHelper {
                            ProgressView()
                                .controlSize(.small)
                        }
                        if helperPresentation.canRemove {
                            Button(removalButtonTitle, role: .destructive) {
                                isConfirmingRemoval = true
                            }
                            .disabled(maintenanceStore.isRemovingHelper)
                        }
                    }
                    .controlSize(.small)
                }
            }

            Divider()

            HStack(spacing: 10) {
                Label("Updates", systemImage: "arrow.triangle.2.circlepath")
                    .font(.subheadline.weight(.semibold))
                Text("v\(maintenanceStore.currentVersion)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if maintenanceStore.isCheckingForUpdates {
                    ProgressView()
                        .controlSize(.small)
                }
                Button("Check for Updates") {
                    Task { await maintenanceStore.checkForUpdates() }
                }
                .controlSize(.small)
                .disabled(maintenanceStore.isCheckingForUpdates)
            }

            if let feedback = maintenanceStore.feedback {
                let feedbackPresentation = feedback.presentation
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(feedbackPresentation.title)
                            .fontWeight(.semibold)
                        Text(feedbackPresentation.message)
                    }
                } icon: {
                    Image(
                        systemName: feedbackPresentation.isFailure
                            ? "xmark.octagon.fill"
                            : "checkmark.circle.fill"
                    )
                }
                .font(.callout)
                .foregroundStyle(feedbackPresentation.isFailure ? .red : .green)
            }
        }
        .padding(16)
        .frame(width: 380)
        .task { await maintenanceStore.refreshHelperStatus() }
        .confirmationDialog(
            "Deactivate and Remove Helper?",
            isPresented: $isConfirmingRemoval,
            titleVisibility: .visible
        ) {
            Button("Deactivate and Remove", role: .destructive) {
                Task { await maintenanceStore.removeHelper() }
            }
        } message: {
            Text("hostflip will remove its privileged helper. Your profiles and base hosts will stay in the workspace. The helper will be requested again on your next switch.")
        }
    }

    private var removalButtonTitle: String {
        if case .helperRemovalFailed = maintenanceStore.feedback {
            return "Retry Remove Helper…"
        }
        return "Deactivate and Remove Helper…"
    }

    private func close() {
        if let onDismiss {
            onDismiss()
        } else {
            dismiss()
        }
    }
}
