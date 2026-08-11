import HostflipCore
import HostflipXPC

/// WorkspaceStore's two paths to the system hosts (a real switch / a follow-up merge once authorized);
/// the production implementation is SwitchCoordinator, tests inject stubs to isolate XPC.
protocol SwitchCoordinating: Sendable {
    func performSwitch(_ merged: MergedHosts) async throws -> SwitchCoordinator.Outcome
    func mergeIfAuthorized(_ merged: MergedHosts) async throws -> SwitchCoordinator.Outcome?
    func reconcile(
        _ merged: MergedHosts,
        observedCurrentHash: String
    ) async throws -> SwitchCoordinator.Outcome
}

extension SwitchCoordinator: SwitchCoordinating {}
