import Foundation
import HostflipCore
import HostflipXPC

/// The daemon-backed system hosts write seam of the activation commands: production merges
/// through MergeCoordinator + DaemonClient; tests inject scripted stubs.
protocol HostsMerging: Sendable {
    /// Sends one merge to the daemon and returns the daemon-confirmed hash. Both attempts of an
    /// interrupted retry share the mergeID — the daemon verifies the receipt, so it cannot
    /// mistake a concurrent external write for its own first attempt.
    func merge(_ merged: MergedHosts, mergeID: UUID, isInterruptedRetry: Bool) async throws -> String
}

/// Production merger: the same coordination the app uses (confirmed-hash recording into the
/// manifest only after the daemon's confirmation), minus SMAppService registration — the CLI
/// never registers the daemon or guides approval; an unready daemon is reported with exit
/// code 4 and the user is sent to the Hostflip app instead.
struct DaemonHostsMerger: HostsMerging {
    private let coordinator: MergeCoordinator

    init(workspace: Workspace) {
        coordinator = MergeCoordinator(workspace: workspace, client: DaemonClient())
    }

    func merge(_ merged: MergedHosts, mergeID: UUID, isInterruptedRetry: Bool) async throws -> String {
        try await coordinator.merge(merged, mergeID: mergeID, isInterruptedRetry: isInterruptedRetry)
    }
}

/// `hostflip activate/deactivate/pause/resume`: switches active state through the daemon.
/// The order mirrors the app's switch path: gate on drift, merge the previewed content, and only
/// then commit — by replaying the change on the latest on-disk state under the manifest lock
/// (ADR-0010 ②) and notifying any running GUI (ADR-0010 ③). A command whose target state
/// already holds is an idempotent success that never touches the daemon — but only once the
/// drift gate has passed: under drift the actual hosts content is unknown, so even a no-op must
/// stop with the drift verdict instead of vouching for a state it cannot see.
enum SwitchCommand {
    /// The canonical verbs, encoded into `--json` payloads as their raw strings; an alias
    /// invocation (`on` / `off`) still reports the canonical verb.
    enum ProfileAction: String, Encodable {
        case activate, deactivate
    }

    enum PauseAction: String, Encodable {
        case pause, resume
    }

    struct ProfilePayload: CommandPayload {
        let action: ProfileAction
        let id: String
        let name: String
        /// The containing group's name; absent for a standalone profile.
        let group: String?
        /// False when the profile was already in the requested state and nothing was written.
        let changed: Bool

        var humanText: String {
            let reference = group.map { "\($0)/\(name)" } ?? name
            switch (action, changed) {
            case (.activate, true): return "Activated \(reference)."
            case (.activate, false): return "\(reference) is already active."
            case (.deactivate, true): return "Deactivated \(reference)."
            case (.deactivate, false): return "\(reference) is not active."
            }
        }
    }

    struct PausePayload: CommandPayload {
        let action: PauseAction
        /// False when the pause state already held and nothing was written.
        let changed: Bool

        var humanText: String {
            switch (action, changed) {
            case (.pause, true): return "Paused. The system hosts now carries Base Hosts only."
            case (.pause, false): return "Already paused."
            case (.resume, true): return "Resumed. The active profiles are back in the system hosts."
            case (.resume, false): return "Not paused."
            }
        }
    }

    static func setActive(
        _ active: Bool,
        reference: ProfileReference,
        workspace: Workspace,
        systemHostsURL: URL,
        merger: any HostsMerging,
        postWorkspaceChanged: @Sendable (Workspace) -> Void
    ) async throws -> ProfilePayload {
        let model = try workspace.openReadOnly()
        let match = try ProfileResolver.resolve(reference, in: model)
        let profileID = match.profile.id
        try requireNoDrift(workspace: workspace, systemHostsURL: systemHostsURL)

        func payload(changed: Bool) -> ProfilePayload {
            ProfilePayload(
                action: active ? .activate : .deactivate,
                id: profileID.rawValue,
                name: match.profile.name,
                group: match.groupName,
                changed: changed
            )
        }

        guard model.activeProfileIDs.contains(profileID) != active else {
            return payload(changed: false)
        }
        try await performSwitch(
            // Replayed on the latest on-disk state at commit time; comparing against the target
            // state keeps the replay from flipping by mistake if a peer already switched it.
            change: { model in
                guard model.activeProfileIDs.contains(profileID) != active else { return }
                try model.toggleProfile(profileID)
            },
            on: model,
            workspace: workspace,
            systemHostsURL: systemHostsURL,
            merger: merger,
            postWorkspaceChanged: postWorkspaceChanged
        )
        return payload(changed: true)
    }

    /// While paused only Base Hosts is written, but every profile's active state is kept; on
    /// resume the kept state rejoins the merge.
    static func setPaused(
        _ paused: Bool,
        workspace: Workspace,
        systemHostsURL: URL,
        merger: any HostsMerging,
        postWorkspaceChanged: @Sendable (Workspace) -> Void
    ) async throws -> PausePayload {
        let model = try workspace.openReadOnly()
        try requireNoDrift(workspace: workspace, systemHostsURL: systemHostsURL)
        guard model.isPaused != paused else {
            return PausePayload(action: paused ? .pause : .resume, changed: false)
        }
        try await performSwitch(
            change: { $0.setPaused(paused) },
            on: model,
            workspace: workspace,
            systemHostsURL: systemHostsURL,
            merger: merger,
            postWorkspaceChanged: postWorkspaceChanged
        )
        return PausePayload(action: paused ? .pause : .resume, changed: true)
    }

    // MARK: - Shared switch path

    private static func performSwitch(
        change: @escaping @Sendable (inout ActivationModel) throws -> Void,
        on model: ActivationModel,
        workspace: Workspace,
        systemHostsURL: URL,
        merger: any HostsMerging,
        postWorkspaceChanged: @Sendable (Workspace) -> Void
    ) async throws {
        var preview = model
        try change(&preview)
        let merged = preview.mergedHosts
        do {
            _ = try await mergeWithOneRetry(merged, via: merger)
        } catch let DaemonChannelError.mergeWriteFailed(failure)
            where failure.writtenHash == merged.hash {
            // The atomic replacement physically landed and only a later flush stage failed: the
            // switch is a fact, so commit it — recording the baseline hash and the switched
            // state keeps the very next status from misreporting the write as drift — and
            // surface only the flush failure.
            try workspace.recordLastWrittenHash(merged.hash)
            try persist(change, to: workspace)
            postWorkspaceChanged(workspace)
            throw CLIError(
                code: "dns-flush-failed",
                message: "the system hosts was updated and the switch was saved, but the DNS cache flush failed: \(failure.message)",
                exitCode: .failure
            )
        }
        try persist(change, to: workspace)
        postWorkspaceChanged(workspace)
    }

    /// The CLI only reports drift (exit code 3), it never reconciles; reconciliation needs the
    /// review flow of the Hostflip app. The daemon re-verifies inside its transaction lock, so
    /// this pre-check is a fast local gate, not the authority.
    private static func requireNoDrift(workspace: Workspace, systemHostsURL: URL) throws {
        guard try !SystemHostsDrift.detect(workspace: workspace, systemHostsURL: systemHostsURL) else {
            throw CLIError.hostsDrift
        }
    }

    /// interrupted means launchd is relaunching the daemon on demand and a single retry
    /// recovers; both attempts reuse the mergeID (same discipline as SwitchCoordinator).
    private static func mergeWithOneRetry(
        _ merged: MergedHosts,
        via merger: any HostsMerging
    ) async throws -> String {
        let mergeID = UUID()
        do {
            return try await merger.merge(merged, mergeID: mergeID, isInterruptedRetry: false)
        } catch let error as DaemonChannelError where error.isRetryable {
            return try await merger.merge(merged, mergeID: mergeID, isInterruptedRetry: true)
        }
    }

    /// Commits the switched state by replaying it on the latest on-disk model (ADR-0010 ②). At
    /// this point the system hosts is already rewritten, so a replay conflict (a peer deleted
    /// the profile mid-flight) is reported instead of silently dropped.
    private static func persist(
        _ change: (inout ActivationModel) throws -> Void,
        to workspace: Workspace
    ) throws {
        guard case .saved = try workspace.save(applying: change) else {
            throw CLIError(
                code: "state-save-conflict",
                message: "the system hosts was updated, but a peer writer changed the workspace so the switched state could not be saved; check 'hostflip status'",
                exitCode: .failure
            )
        }
    }
}
