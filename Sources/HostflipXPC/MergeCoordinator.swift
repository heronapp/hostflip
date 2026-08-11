import Foundation
import HostflipCore

/// Keeps the daemon-confirmed baseline this process has already received even when
/// recording it to the manifest fails; subsequent pre-write checks consult that
/// baseline first, so a write the daemon itself completed is not misjudged as drift.
public protocol ConfirmedHostsWriteTracking: Sendable {
    func expectedCurrentHash(persistedHash: String) async -> String
    func hostsWriteDidConfirm(_ targetHash: String) async
}

/// App-side merge orchestration: asks the daemon to write to disk, and only records
/// the daemon-confirmed content hash into the manifest after a successful confirmation
/// (#18); any failure is rethrown as-is with the hash untouched, so the comparison
/// baseline for external-modification detection (#24) only reflects confirmed writes.
///
/// The whole send→record chain is serialized as a FIFO task chain: daemon-side write
/// order = enqueue order = record order, and the manifest always reflects the last
/// completed write. An actor alone is not enough — it is reentrant at await points,
/// and a stale reply completing late would overwrite the newer hash.
public actor MergeCoordinator {
    private let workspace: Workspace
    private let send: @Sendable (MergedHosts, String, UUID, Bool) async throws -> String
    private let confirmedWriteTracker: (any ConfirmedHostsWriteTracking)?
    /// Tail of the chain. Successors wait only for ordering; they do not inherit a predecessor's failure.
    private var tail: Task<Void, Never>?

    /// Production initializer: sends via DaemonClient.
    public init(
        workspace: Workspace,
        client: DaemonClient,
        confirmedWriteTracker: (any ConfirmedHostsWriteTracking)? = nil
    ) {
        self.init(
            workspace: workspace,
            send: {
                try await client.merge(
                    $0,
                    expectedCurrentHash: $1,
                    mergeID: $2,
                    isInterruptedRetry: $3
                )
            },
            confirmedWriteTracker: confirmedWriteTracker
        )
    }

    /// send is the sending seam; isolated tests inject replies through it.
    init(
        workspace: Workspace,
        send: @escaping @Sendable (MergedHosts, String, UUID, Bool) async throws -> String,
        confirmedWriteTracker: (any ConfirmedHostsWriteTracking)? = nil
    ) {
        self.workspace = workspace
        self.send = send
        self.confirmedWriteTracker = confirmedWriteTracker
    }

    /// Returns the hash confirmed by the daemon.
    @discardableResult
    public func merge(
        _ merged: MergedHosts,
        expectedCurrentHash observedCurrentHash: String? = nil,
        mergeID: UUID = UUID(),
        isInterruptedRetry: Bool = false
    ) async throws -> String {
        let previous = tail
        let task = Task<String, Error> { [send, workspace, confirmedWriteTracker] in
            await previous?.value
            let expectedCurrentHash: String
            if let observedCurrentHash {
                expectedCurrentHash = observedCurrentHash
            } else {
                let persistedHash = try workspace.expectedSystemHostsHash()
                expectedCurrentHash = await confirmedWriteTracker?
                    .expectedCurrentHash(persistedHash: persistedHash) ?? persistedHash
            }
            let confirmed: String
            do {
                confirmed = try await send(merged, expectedCurrentHash, mergeID, isInterruptedRetry)
            } catch let error as DaemonChannelError {
                if case .mergeWriteFailed(let failure) = error,
                   let writtenHash = failure.writtenHash {
                    await confirmedWriteTracker?.hostsWriteDidConfirm(writtenHash)
                }
                throw error
            }
            await confirmedWriteTracker?.hostsWriteDidConfirm(confirmed)
            try workspace.recordLastWrittenHash(confirmed)
            return confirmed
        }
        tail = Task { _ = try? await task.value }
        return try await task.value
    }
}
