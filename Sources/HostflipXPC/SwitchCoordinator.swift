import Foundation
import HostflipCore

/// Minimal coordination interface for the app-side file watcher: suppresses its own
/// file events for the duration of one full merge (including the interrupted retry);
/// reconciliation also carries the live-file hash the user reviewed, and the
/// suppression window opens only while the live file still matches. Afterwards the
/// live file is re-checked against the newly recorded hash.
public protocol ExpectedHostsWriteObserving: Sendable {
    func expectedWriteWillBegin(
        _ targetHash: String,
        replacingObservedHash: String?
    ) async
    func expectedWriteDidEnd(_ targetHash: String) async
}

/// The switch entry point (#19): gating + merge + failure self-healing. On the app
/// side this is the only place that triggers registration and the only path to the
/// system hosts — an unready helper always blocks: no merge is sent, no osascript
/// fallback.
/// The single guidance path distilled from one switch attempt. Consumers render
/// it (banner, alert, CLI) but never re-derive it — the classification and its
/// precedence live in `Outcome.guidance(targetHash:)` alone.
public enum SwitchGuidance: Equatable, Sendable {
    /// Merge completed, with the daemon-confirmed hash.
    case merged(hash: String)
    /// Guide the user to approve (or re-approve) the helper in System Settings.
    case needsApproval
    /// The helper stays unavailable after registering; guide toward reinstalling.
    case unavailable
    /// The daemon rejected the merge because the live file drifted; guide into review.
    case hostsDrift
    /// The atomic replacement of the target content completed, but the subsequent
    /// flush failed. Consumers that track model state treat the switch as landed
    /// (commit and persist it) and surface only the flush failure — the file
    /// already has the target content, and rolling the model back would contradict it.
    case writtenButFlushFailed(HostsWriteError)
    /// Everything else; carries the channel error for the consumer's message.
    case failed(DaemonChannelError)
}

public actor SwitchCoordinator {
    /// The channel-level verdict of one switch; errors outside the channel (such as a manifest recording failure) are rethrown as-is.
    public enum Outcome: Equatable, Sendable {
        /// Merge completed, with the daemon-confirmed hash.
        case merged(hash: String)
        /// Helper not ready (needsApproval / unavailable); the system hosts were untouched.
        case blocked(DaemonReadiness)
        /// The channel call failed; carries the actual registration status re-checked after the error, from which the caller picks a guidance path.
        case channelFailed(DaemonChannelError, statusAfterError: DaemonRegistrationStatus)

        /// Classifies this outcome into the one guidance path consumers act on.
        /// Precedence, most specific first: an explicit drift rejection beats the
        /// post-error status re-check; a replacement that physically landed on
        /// `targetHash` beats it too (the write is a fact); only then does a
        /// revoked approval turn any remaining error into `.needsApproval`
        /// (ADR-0002: guide to re-approve instead of reporting a one-off failure).
        public func guidance(targetHash: String) -> SwitchGuidance {
            switch self {
            case .merged(let hash):
                return .merged(hash: hash)
            case .blocked(.unavailable):
                return .unavailable
            case .blocked:
                return .needsApproval
            case .channelFailed(.mergeRejected(.hostsDrift), _):
                return .hostsDrift
            case .channelFailed(.mergeWriteFailed(let failure), _)
                where failure.writtenHash == targetHash:
                return .writtenButFlushFailed(failure)
            case .channelFailed(_, statusAfterError: .requiresApproval):
                return .needsApproval
            case .channelFailed(let error, _):
                return .failed(error)
            }
        }
    }

    private let registrar: DaemonRegistrar
    private let merge: @Sendable (MergedHosts, String?, UUID, Bool) async throws -> String
    private let expectedWriteObserver: (any ExpectedHostsWriteObserving)?

    /// Production initializer: merges via MergeCoordinator (see its docs for the hash recording order constraints).
    public init(
        registrar: DaemonRegistrar,
        coordinator: MergeCoordinator,
        expectedWriteObserver: (any ExpectedHostsWriteObserving)? = nil
    ) {
        self.init(
            registrar: registrar,
            mergeWithExpectedCurrentHash: {
                try await coordinator.merge(
                    $0,
                    expectedCurrentHash: $1,
                    mergeID: $2,
                    isInterruptedRetry: $3
                )
            },
            expectedWriteObserver: expectedWriteObserver
        )
    }

    /// merge is the sending seam; isolated tests inject replies through it.
    init(
        registrar: DaemonRegistrar,
        merge: @escaping @Sendable (MergedHosts, UUID, Bool) async throws -> String,
        expectedWriteObserver: (any ExpectedHostsWriteObserving)? = nil
    ) {
        self.registrar = registrar
        self.merge = { merged, _, mergeID, isInterruptedRetry in
            try await merge(merged, mergeID, isInterruptedRetry)
        }
        self.expectedWriteObserver = expectedWriteObserver
    }

    init(
        registrar: DaemonRegistrar,
        mergeWithExpectedCurrentHash merge: @escaping @Sendable (
            MergedHosts,
            String?,
            UUID,
            Bool
        ) async throws -> String,
        expectedWriteObserver: (any ExpectedHostsWriteObserving)? = nil
    ) {
        self.registrar = registrar
        self.merge = merge
        self.expectedWriteObserver = expectedWriteObserver
    }

    public func performSwitch(_ merged: MergedHosts) async throws -> Outcome {
        let readiness = await registrar.ensureReadyForSwitch()
        guard readiness == .ready else { return .blocked(readiness) }
        return try await mergeReportingChannelOutcome(merged)
    }

    /// Follow-up merge after an edit is saved (#20): sent only when the helper is
    /// already approved; every other status returns nil and never registers —
    /// authorization is still lazily triggered only by an actual switch, and the
    /// content is already saved locally, waiting to be written on the next switch.
    public func mergeIfAuthorized(_ merged: MergedHosts) async throws -> Outcome? {
        guard await registrar.refreshStatus() == .enabled else { return nil }
        return try await mergeReportingChannelOutcome(merged)
    }

    /// After the user has reviewed the drifted live file, performs one
    /// compare-and-swap style reconciliation keyed on that live-file hash; if the
    /// daemon finds the live file changed again it still rejects, never overwriting
    /// unreviewed new modifications.
    public func reconcile(
        _ merged: MergedHosts,
        observedCurrentHash: String
    ) async throws -> Outcome {
        let readiness = await registrar.ensureReadyForSwitch()
        guard readiness == .ready else { return .blocked(readiness) }
        return try await mergeReportingChannelOutcome(
            merged,
            expectedCurrentHash: observedCurrentHash
        )
    }

    /// Shared merge path once gating passes. After an XPC error, re-checks the actual
    /// registration status (self-healing): the user may have disabled the daemon.
    private func mergeReportingChannelOutcome(
        _ merged: MergedHosts,
        expectedCurrentHash: String? = nil
    ) async throws -> Outcome {
        await expectedWriteObserver?.expectedWriteWillBegin(
            merged.hash,
            replacingObservedHash: expectedCurrentHash
        )
        do {
            let hash = try await mergeWithOneRetry(
                merged,
                expectedCurrentHash: expectedCurrentHash
            )
            await expectedWriteObserver?.expectedWriteDidEnd(merged.hash)
            return .merged(hash: hash)
        } catch let error as DaemonChannelError {
            await expectedWriteObserver?.expectedWriteDidEnd(merged.hash)
            return .channelFailed(error, statusAfterError: await registrar.refreshStatus())
        } catch {
            await expectedWriteObserver?.expectedWriteDidEnd(merged.hash)
            throw error
        }
    }

    /// interrupted means launchd is relaunching the daemon on demand, and a single
    /// retry recovers. Both attempts reuse the mergeID; the daemon interprets equal
    /// content as "the first request already landed" only when the target file carries
    /// the same receipt, so it cannot adopt a concurrent external modification.
    private func mergeWithOneRetry(
        _ merged: MergedHosts,
        expectedCurrentHash: String?
    ) async throws -> String {
        let mergeID = UUID()
        do {
            return try await merge(merged, expectedCurrentHash, mergeID, false)
        } catch let error as DaemonChannelError where error.isRetryable {
            return try await merge(merged, expectedCurrentHash, mergeID, true)
        }
    }
}
