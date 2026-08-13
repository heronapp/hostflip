import Foundation
import HostflipXPC
import Observation

enum MaintenanceFeedback: Equatable {
    case helperRemoved
    case helperRemovalFailed(String)

    struct Presentation {
        let title: String
        let message: String
        let isFailure: Bool
    }

    var presentation: Presentation {
        switch self {
        case .helperRemoved:
            Presentation(
                title: "Helper Removed",
                message: "The helper was deactivated and removed. Your profiles were not changed.",
                isFailure: false
            )
        case .helperRemovalFailed(let message):
            Presentation(title: "Could Not Remove Helper", message: message, isFailure: true)
        }
    }
}

/// State behind the main window's maintenance entry point: only orchestrates helper management, never touches workspace data. Update checks are Sparkle's (SPUUpdater).
@MainActor
@Observable
final class MaintenanceStore {
    private(set) var helperStatus: DaemonRegistrationStatus?
    private(set) var feedback: MaintenanceFeedback?
    private(set) var isRemovingHelper = false

    private let loadHelperStatus: @Sendable () async -> DaemonRegistrationStatus
    private let unregisterHelper: @Sendable () async throws -> Void
    private let wait: @Sendable (Duration) async -> Void
    @ObservationIgnored private var approvalPollTask: Task<Void, Never>?

    /// The wait closure is an injection seam so tests can skip the real poll interval.
    init(
        helperStatus: @escaping @Sendable () async -> DaemonRegistrationStatus,
        unregisterHelper: @escaping @Sendable () async throws -> Void,
        wait: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) }
    ) {
        loadHelperStatus = helperStatus
        self.unregisterHelper = unregisterHelper
        self.wait = wait
    }

    func refreshHelperStatus() async {
        helperStatus = await loadHelperStatus()
        updateApprovalPolling()
    }

    /// SMAppService offers no status-change notification, so while approval is pending
    /// the store polls: the toggle flipped in System Settings unblocks the UI without
    /// the user having to switch back to the app first. The loop is bounded — it only
    /// runs while the status stays `requiresApproval` and stops itself on any other
    /// answer.
    private func updateApprovalPolling() {
        guard helperStatus == .requiresApproval else {
            approvalPollTask?.cancel()
            approvalPollTask = nil
            return
        }
        guard approvalPollTask == nil else { return }
        approvalPollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.wait(.seconds(2))
                if Task.isCancelled { return }
                self.helperStatus = await self.loadHelperStatus()
                if self.helperStatus != .requiresApproval {
                    self.approvalPollTask = nil
                    return
                }
            }
        }
    }

    func removeHelper() async {
        guard !isRemovingHelper else { return }
        isRemovingHelper = true
        feedback = nil
        defer { isRemovingHelper = false }

        do {
            try await unregisterHelper()
            helperStatus = await loadHelperStatus()
            feedback = .helperRemoved
        } catch {
            helperStatus = await loadHelperStatus()
            feedback = .helperRemovalFailed(
                "Could not remove the helper. Try again. Your profiles were not changed. \(error.localizedDescription)"
            )
        }
        updateApprovalPolling()
    }

}
