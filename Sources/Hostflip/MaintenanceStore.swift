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

    let currentVersion: String
    private let loadHelperStatus: @Sendable () async -> DaemonRegistrationStatus
    private let unregisterHelper: @Sendable () async throws -> Void

    init(
        currentVersion: String,
        helperStatus: @escaping @Sendable () async -> DaemonRegistrationStatus,
        unregisterHelper: @escaping @Sendable () async throws -> Void
    ) {
        self.currentVersion = currentVersion
        loadHelperStatus = helperStatus
        self.unregisterHelper = unregisterHelper
    }

    func refreshHelperStatus() async {
        helperStatus = await loadHelperStatus()
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
    }

}
