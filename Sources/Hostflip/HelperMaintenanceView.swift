import HostflipXPC
import Sparkle
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

/// User-facing maintenance panel: the entry point for both helper management and update checks.
struct HelperMaintenanceView: View {
    let store: WorkspaceStore
    let maintenanceStore: MaintenanceStore
    let updater: SPUUpdater
    let onDismiss: (() -> Void)?
    @Environment(\.dismiss) private var dismiss
    @State private var isConfirmingRemoval = false

    init(
        store: WorkspaceStore,
        maintenanceStore: MaintenanceStore,
        updater: SPUUpdater,
        onDismiss: (() -> Void)? = nil
    ) {
        self.store = store
        self.maintenanceStore = maintenanceStore
        self.updater = updater
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
                CheckForUpdatesButton(updater: updater)
                    .controlSize(.small)
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
            Text("hostflip will remove its privileged helper. Your profiles and base hosts will stay in the workspace. The helper will be requested again on your next switch.\n\nThe system hosts file keeps its current content — entries from active profiles stay in effect. To leave only Base Hosts applied (e.g. before uninstalling), turn off the master switch first.")
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
