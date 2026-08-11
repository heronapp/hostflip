import XCTest
@testable import HostflipCore
@testable import HostflipXPC

/// Thread-safe merge call counter.
private final class MergeLog: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func next() -> Int {
        lock.withLock {
            count += 1
            return count
        }
    }

    var calls: Int {
        lock.withLock { count }
    }
}

private final class MergeAttemptLog: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [(UUID, Bool)] = []

    func append(mergeID: UUID, isInterruptedRetry: Bool) {
        lock.withLock { values.append((mergeID, isInterruptedRetry)) }
    }

    var recordedValues: [(UUID, Bool)] {
        lock.withLock { values }
    }
}

private actor ExpectedWriteLog: ExpectedHostsWriteObserving {
    private(set) var events: [String] = []
    private(set) var replacingObservedHashes: [String?] = []

    func expectedWriteWillBegin(
        _ targetHash: String,
        replacingObservedHash: String?
    ) {
        events.append("will")
        replacingObservedHashes.append(replacingObservedHash)
    }

    func expectedWriteDidEnd(_ targetHash: String) {
        events.append("did")
    }

    func recordAttempt() {
        events.append("merge")
    }
}

private actor ReconciliationAttemptLog {
    private(set) var observedHashes: [String?] = []
    private(set) var mergeIDs: [UUID] = []
    private(set) var retryFlags: [Bool] = []

    func append(observedHash: String?, mergeID: UUID, isRetry: Bool) {
        observedHashes.append(observedHash)
        mergeIDs.append(mergeID)
        retryFlags.append(isRetry)
    }
}

/// Injects a closure at the merge seam to simulate channel replies: verifies gating (no send while not ready) and failure recovery
/// (one retry on interrupted, recheck of the actual registration status after a channel error).
final class SwitchCoordinatorTests: XCTestCase {
    private let merged = MergedHosts(content: "127.0.0.1 localhost\n")

    private func makeCoordinator(
        manager: FakeDaemonManager,
        expectedWriteObserver: (any ExpectedHostsWriteObserving)? = nil,
        merge: @escaping @Sendable (MergedHosts, UUID, Bool) async throws -> String
    ) -> SwitchCoordinator {
        let registrar = DaemonRegistrar(
            manager: manager,
            currentBuildVersion: "1",
            recordedVersion: { nil },
            recordVersion: { _ in }
        )
        return SwitchCoordinator(
            registrar: registrar,
            merge: merge,
            expectedWriteObserver: expectedWriteObserver
        )
    }

    func testSwitchBlocksWithoutSendingWhileApprovalPending() async throws {
        let log = MergeLog()
        let coordinator = makeCoordinator(manager: FakeDaemonManager(status: .requiresApproval)) { merged, _, _ in
            _ = log.next()
            return merged.hash
        }

        let outcome = try await coordinator.performSwitch(merged)

        XCTAssertEqual(outcome, .blocked(.needsApproval))
        XCTAssertEqual(log.calls, 0)
    }

    func testFirstSwitchRegistersOnDemandThenMerges() async throws {
        let manager = FakeDaemonManager(status: .notRegistered, afterRegister: .enabled)
        let coordinator = makeCoordinator(manager: manager) { merged, _, _ in merged.hash }

        let outcome = try await coordinator.performSwitch(merged)

        XCTAssertEqual(outcome, .merged(hash: merged.hash))
        XCTAssertEqual(manager.recordedCalls, ["register"])
    }

    func testSwitchRetriesOnceAfterInterruption() async throws {
        let log = MergeLog()
        let coordinator = makeCoordinator(manager: FakeDaemonManager(status: .enabled)) { merged, _, _ in
            if log.next() == 1 { throw DaemonChannelError.interrupted }
            return merged.hash
        }

        let outcome = try await coordinator.performSwitch(merged)

        XCTAssertEqual(outcome, .merged(hash: merged.hash))
        XCTAssertEqual(log.calls, 2)
    }

    func testExpectedWriteWindowSpansInterruptedRetry() async throws {
        let log = ExpectedWriteLog()
        let attempts = MergeLog()
        let coordinator = makeCoordinator(
            manager: FakeDaemonManager(status: .enabled),
            expectedWriteObserver: log
        ) { merged, _, _ in
            await log.recordAttempt()
            if attempts.next() == 1 { throw DaemonChannelError.interrupted }
            return merged.hash
        }

        _ = try await coordinator.performSwitch(merged)

        let events = await log.events
        XCTAssertEqual(events, ["will", "merge", "merge", "did"])
    }

    func testInterruptedRetryReusesMergeIDAndMarksOnlySecondAttempt() async throws {
        let attempts = MergeLog()
        let log = MergeAttemptLog()
        let coordinator = makeCoordinator(manager: FakeDaemonManager(status: .enabled)) { merged, mergeID, retry in
            log.append(mergeID: mergeID, isInterruptedRetry: retry)
            if attempts.next() == 1 { throw DaemonChannelError.interrupted }
            return merged.hash
        }

        _ = try await coordinator.performSwitch(merged)

        let recorded = log.recordedValues
        XCTAssertEqual(recorded.map(\.1), [false, true])
        XCTAssertEqual(recorded.map(\.0), [recorded[0].0, recorded[0].0])
    }

    func testSwitchReportsFailureAfterRepeatedInterruption() async throws {
        let log = MergeLog()
        let coordinator = makeCoordinator(manager: FakeDaemonManager(status: .enabled)) { _, _, _ in
            _ = log.next()
            throw DaemonChannelError.interrupted
        }

        let outcome = try await coordinator.performSwitch(merged)

        XCTAssertEqual(outcome, .channelFailed(.interrupted, statusAfterError: .enabled))
        XCTAssertEqual(log.calls, 2)
    }

    func testSwitchRechecksActualStatusAfterChannelError() async throws {
        // The channel reports unavailable just as the user has disabled the helper in System Settings:
        // the recheck must pick up the actual post-disable status, or the guidance would point the wrong way
        let manager = FakeDaemonManager(status: .enabled)
        let coordinator = makeCoordinator(manager: manager) { _, _, _ in
            manager.setStatus(.requiresApproval)
            throw DaemonChannelError.unavailable
        }

        let outcome = try await coordinator.performSwitch(merged)

        XCTAssertEqual(outcome, .channelFailed(.unavailable, statusAfterError: .requiresApproval))
    }

    func testReconciliationReusesReviewedHashAndMergeIDAcrossInterruptedRetry() async throws {
        let manager = FakeDaemonManager(status: .enabled)
        let registrar = DaemonRegistrar(
            manager: manager,
            currentBuildVersion: "1",
            recordedVersion: { nil },
            recordVersion: { _ in }
        )
        let attempts = MergeLog()
        let log = ReconciliationAttemptLog()
        let expectedWriteLog = ExpectedWriteLog()
        let coordinator = SwitchCoordinator(
            registrar: registrar,
            mergeWithExpectedCurrentHash: { merged, observedHash, mergeID, isRetry in
                await log.append(
                    observedHash: observedHash,
                    mergeID: mergeID,
                    isRetry: isRetry
                )
                if attempts.next() == 1 { throw DaemonChannelError.interrupted }
                return merged.hash
            },
            expectedWriteObserver: expectedWriteLog
        )

        let outcome = try await coordinator.reconcile(
            merged,
            observedCurrentHash: "user-reviewed-actual"
        )

        XCTAssertEqual(outcome, .merged(hash: merged.hash))
        let observedHashes = await log.observedHashes
        let mergeIDs = await log.mergeIDs
        let retryFlags = await log.retryFlags
        XCTAssertEqual(observedHashes, ["user-reviewed-actual", "user-reviewed-actual"])
        XCTAssertEqual(mergeIDs, [mergeIDs[0], mergeIDs[0]])
        XCTAssertEqual(retryFlags, [false, true])
        let replacingObservedHashes = await expectedWriteLog.replacingObservedHashes
        XCTAssertEqual(replacingObservedHashes, ["user-reviewed-actual"])
    }

    // MARK: - mergeIfAuthorized (#20: follow-up merge after saving an edit)

    func testMergeIfAuthorizedSendsWhenHelperEnabled() async throws {
        let manager = FakeDaemonManager(status: .enabled)
        let coordinator = makeCoordinator(manager: manager) { merged, _, _ in merged.hash }

        let outcome = try await coordinator.mergeIfAuthorized(merged)

        XCTAssertEqual(outcome, .merged(hash: merged.hash))
        XCTAssertEqual(manager.recordedCalls, [])
    }

    func testMergeIfAuthorizedSkipsWithoutRegisteringWhenNotRegistered() async throws {
        // Key difference from performSwitch: saving an edit never lazy-registers; authorization is triggered only by an actual switch
        let log = MergeLog()
        let manager = FakeDaemonManager(status: .notRegistered, afterRegister: .enabled)
        let coordinator = makeCoordinator(manager: manager) { merged, _, _ in
            _ = log.next()
            return merged.hash
        }

        let outcome = try await coordinator.mergeIfAuthorized(merged)

        XCTAssertNil(outcome)
        XCTAssertEqual(log.calls, 0)
        XCTAssertEqual(manager.recordedCalls, [])
    }

    func testMergeIfAuthorizedSkipsWhileApprovalPending() async throws {
        let log = MergeLog()
        let coordinator = makeCoordinator(manager: FakeDaemonManager(status: .requiresApproval)) { merged, _, _ in
            _ = log.next()
            return merged.hash
        }

        let outcome = try await coordinator.mergeIfAuthorized(merged)

        XCTAssertNil(outcome)
        XCTAssertEqual(log.calls, 0)
    }

    func testMergeIfAuthorizedRetriesOnceAfterInterruption() async throws {
        let log = MergeLog()
        let coordinator = makeCoordinator(manager: FakeDaemonManager(status: .enabled)) { merged, _, _ in
            if log.next() == 1 { throw DaemonChannelError.interrupted }
            return merged.hash
        }

        let outcome = try await coordinator.mergeIfAuthorized(merged)

        XCTAssertEqual(outcome, .merged(hash: merged.hash))
        XCTAssertEqual(log.calls, 2)
    }

    func testMergeIfAuthorizedRechecksActualStatusAfterChannelError() async throws {
        let manager = FakeDaemonManager(status: .enabled)
        let coordinator = makeCoordinator(manager: manager) { _, _, _ in
            manager.setStatus(.requiresApproval)
            throw DaemonChannelError.unavailable
        }

        let outcome = try await coordinator.mergeIfAuthorized(merged)

        XCTAssertEqual(outcome, .channelFailed(.unavailable, statusAfterError: .requiresApproval))
    }

    func testSwitchPropagatesNonChannelErrors() async {
        // Errors outside the channel (e.g. a manifest recording failure) are not part of the switch semantics; rethrow as-is
        let coordinator = makeCoordinator(manager: FakeDaemonManager(status: .enabled)) { _, _, _ in
            throw WorkspaceError.notInitialized
        }

        do {
            _ = try await coordinator.performSwitch(merged)
            XCTFail("非通道错误应上抛")
        } catch let error as WorkspaceError {
            XCTAssertEqual(error, .notInitialized)
        } catch {
            XCTFail("错误类型不符：\(error)")
        }
    }
}
