import Foundation
import HostflipCore
import HostflipXPC

/// The shared daemon write path of every command whose change touches the merged system hosts
/// output: activation switches, and content writes or deletes aimed at an active profile. The
/// order mirrors the app's switch path — gate on drift, merge the previewed content, and only
/// then commit, by replaying the change on the latest on-disk state under the manifest lock
/// (ADR-0010 ②) and notifying any running GUI (ADR-0010 ③).
enum MergeCommitFlow {
    /// The CLI only reports drift (exit code 3), it never reconciles; reconciliation needs the
    /// review flow of the Hostflip app. The daemon re-verifies inside its transaction lock, so
    /// this pre-check is a fast local gate, not the authority. Callers gate before their
    /// idempotent no-op check: under drift the actual hosts content is unknown, so even a no-op
    /// must stop with the drift verdict instead of vouching for a state it cannot see.
    static func requireNoDrift(workspace: Workspace, systemHostsURL: URL) throws {
        guard try !SystemHostsDrift.detect(workspace: workspace, systemHostsURL: systemHostsURL) else {
            throw CLIError.hostsDrift
        }
    }

    /// Merges the model-plus-change preview through the daemon, then commits the change by
    /// replaying it on the latest persisted state and posting the change notification.
    static func run(
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
            // change is a fact, so commit it — recording the baseline hash and the changed
            // state keeps the very next status from misreporting the write as drift — and
            // surface only the flush failure.
            try workspace.recordLastWrittenHash(merged.hash)
            try persist(change, to: workspace)
            postWorkspaceChanged(workspace)
            throw dnsFlushFailure(failure)
        }
        try persist(change, to: workspace)
        postWorkspaceChanged(workspace)
    }

    /// interrupted means launchd is relaunching the daemon on demand and a single retry
    /// recovers; both attempts reuse the mergeID (same discipline as SwitchCoordinator).
    /// Internal rather than private: refresh (#73) merges through this too, but commits its
    /// content before the merge instead of after — a blocked write must not roll it back.
    static func mergeWithOneRetry(
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

    /// The one flush-failure error, shared with refresh (#73) so the landed-write rule — the
    /// change is a fact, record the hash, report only the flush — and its copy live in one place.
    static func dnsFlushFailure(_ failure: HostsWriteError) -> CLIError {
        CLIError(
            code: "dns-flush-failed",
            message: "the system hosts was updated and the change was saved, but the DNS cache flush failed: \(failure.message)",
            exitCode: .failure
        )
    }

    /// Commits the changed state by replaying it on the latest on-disk model (ADR-0010 ②). At
    /// this point the system hosts is already rewritten, so a replay conflict (a peer deleted
    /// the profile mid-flight) is reported instead of silently dropped.
    private static func persist(
        _ change: (inout ActivationModel) throws -> Void,
        to workspace: Workspace
    ) throws {
        guard case .saved = try workspace.save(applying: change) else {
            throw CLIError(
                code: "state-save-conflict",
                message: "the system hosts was updated, but a peer writer changed the workspace so the change could not be saved; check 'hostflip status'",
                exitCode: .failure
            )
        }
    }
}
