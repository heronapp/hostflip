import XCTest
@testable import HostflipCore
@testable import HostflipXPC

/// Manually operated gate that suspends send at a controllable point.
private actor Gate {
    private var continuations: [CheckedContinuation<Void, Never>] = []
    private var isOpen = false

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { continuations.append($0) }
    }

    func open() {
        isOpen = true
        continuations.forEach { $0.resume() }
        continuations.removeAll()
    }
}

/// Records the order in which sends start.
private actor Recorder {
    private(set) var events: [String] = []

    func append(_ event: String) {
        events.append(event)
    }
}

private actor ConfirmedWriteTrackerSpy: ConfirmedHostsWriteTracking {
    private let overrideHash: String
    private(set) var confirmedTargetHashes: [String] = []

    init(overrideHash: String) {
        self.overrideHash = overrideHash
    }

    func expectedCurrentHash(persistedHash: String) -> String {
        overrideHash
    }

    func hostsWriteDidConfirm(_ targetHash: String) {
        confirmedTargetHashes.append(targetHash)
    }
}

/// Injects a closure at the send seam to simulate daemon replies, with the workspace in a temporary directory:
/// verifies the ordering constraint that the hash is recorded into the manifest only after a successful confirmation.
final class MergeCoordinatorTests: XCTestCase {
    private var rootDirectory: URL!
    private var workspace: Workspace!

    override func setUpWithError() throws {
        rootDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("hostflip-coordinator-tests-\(UUID().uuidString)", isDirectory: true)
        workspace = Workspace(rootDirectory: rootDirectory)
        _ = try workspace.open(systemHosts: { "127.0.0.1 localhost\n" })
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: rootDirectory)
    }

    func testMergeRecordsDaemonConfirmedHashOnSuccess() async throws {
        let coordinator = MergeCoordinator(workspace: workspace, send: { merged, _, _, _ in merged.hash })
        let merged = MergedHosts(content: "127.0.0.1 localhost\n1.1.1.1 a\n")

        let confirmed = try await coordinator.merge(merged)

        XCTAssertEqual(confirmed, merged.hash)
        XCTAssertEqual(try workspace.lastWrittenHash(), merged.hash)
    }

    func testReconciliationUsesObservedHashAndRecordsConfirmedTarget() async throws {
        let receivedBaseline = Recorder()
        let tracker = ConfirmedWriteTrackerSpy(overrideHash: "persisted-baseline")
        let merged = MergedHosts(content: "127.0.0.1 localhost\n1.2.3.4 external.local\n")
        let coordinator = MergeCoordinator(
            workspace: workspace,
            send: { merged, expectedCurrentHash, _, _ in
                await receivedBaseline.append(expectedCurrentHash)
                return merged.hash
            },
            confirmedWriteTracker: tracker
        )

        let confirmed = try await coordinator.merge(
            merged,
            expectedCurrentHash: "user-reviewed-actual"
        )

        XCTAssertEqual(confirmed, merged.hash)
        let baselines = await receivedBaseline.events
        XCTAssertEqual(baselines, ["user-reviewed-actual"])
        XCTAssertEqual(try workspace.lastWrittenHash(), merged.hash)
    }

    func testMergeKeepsPriorHashWhenDaemonReportsFailure() async throws {
        let prior = MergedHosts(content: "127.0.0.1 localhost\n")
        try await MergeCoordinator(workspace: workspace, send: { merged, _, _, _ in merged.hash }).merge(prior)
        let failure = HostsWriteError(stage: .flushDNS, message: "dscacheutil exited with status 1")
        let failing = MergeCoordinator(workspace: workspace, send: { _, _, _, _ in
            throw DaemonChannelError.mergeWriteFailed(failure)
        })

        do {
            try await failing.merge(MergedHosts(content: "2.2.2.2 b\n"))
            XCTFail("a failed merge write must not return normally")
        } catch let error as DaemonChannelError {
            XCTAssertEqual(error, .mergeWriteFailed(failure))
        }
        XCTAssertEqual(try workspace.lastWrittenHash(), prior.hash)
    }

    func testMergeReportsWrittenHashToTrackerWhenDNSFlushFailsAfterReplacement() async throws {
        let prior = MergedHosts(content: "127.0.0.1 localhost\n")
        let merged = MergedHosts(content: "2.2.2.2 b\n")
        let tracker = ConfirmedWriteTrackerSpy(overrideHash: prior.hash)
        let failure = HostsWriteError(
            stage: .flushDNS,
            message: "dscacheutil exited with status 1",
            writtenHash: merged.hash
        )
        let coordinator = MergeCoordinator(
            workspace: workspace,
            send: { _, _, _, _ in throw DaemonChannelError.mergeWriteFailed(failure) },
            confirmedWriteTracker: tracker
        )

        do {
            try await coordinator.merge(merged)
            XCTFail("a DNS flush failure must be rethrown")
        } catch let error as DaemonChannelError {
            XCTAssertEqual(error, .mergeWriteFailed(failure))
        }

        let confirmedTargetHashes = await tracker.confirmedTargetHashes
        XCTAssertEqual(confirmedTargetHashes, [merged.hash])
        XCTAssertNil(try workspace.lastWrittenHash())
    }

    func testMergeUsesConfirmedBaselineAndReportsConfirmationBeforeManifestRecordFailure() async throws {
        let tracker = ConfirmedWriteTrackerSpy(overrideHash: "confirmed-prior")
        let receivedBaseline = Recorder()
        let merged = MergedHosts(content: "10.0.0.1 managed.local\n")
        let manifestURL = rootDirectory.appendingPathComponent("manifest.json")
        let coordinator = MergeCoordinator(
            workspace: workspace,
            send: { merged, expectedCurrentHash, _, _ in
                await receivedBaseline.append(expectedCurrentHash)
                try FileManager.default.removeItem(at: manifestURL)
                return merged.hash
            },
            confirmedWriteTracker: tracker
        )

        do {
            try await coordinator.merge(merged)
            XCTFail("a manifest record failure must be rethrown")
        } catch let error as ConfirmedWriteBaselineError {
            // Typed, with the confirmed hash attached (#73): the daemon did write, and a
            // caller reporting this as "hosts not updated" would misdescribe the system.
            XCTAssertEqual(error.confirmedHash, merged.hash)
            XCTAssertEqual(error.underlying as? WorkspaceError, .notInitialized)
        }

        let baselines = await receivedBaseline.events
        let confirmedTargetHashes = await tracker.confirmedTargetHashes
        XCTAssertEqual(baselines, ["confirmed-prior"])
        XCTAssertEqual(confirmedTargetHashes, [merged.hash])
    }

    func testConcurrentMergesSerializeWholeSendRecordChainInEnqueueOrder() async throws {
        let gate = Gate()
        let started = Recorder()
        let coordinator = MergeCoordinator(workspace: workspace, send: { merged, _, _, _ in
            await started.append(merged.content)
            if merged.content.contains("first") { await gate.wait() }
            return merged.hash
        })
        let first = MergedHosts(content: "1.1.1.1 first\n")
        let second = MergedHosts(content: "2.2.2.2 second\n")

        let firstMerge = Task { try await coordinator.merge(first) }
        try await Task.sleep(for: .milliseconds(50))
        let secondMerge = Task { try await coordinator.merge(second) }
        try await Task.sleep(for: .milliseconds(50))

        // While first's send is suspended, second must still be queued — the whole send→record chain is serial
        let startedWhileFirstPending = await started.events
        XCTAssertEqual(startedWhileFirstPending, [first.content])

        await gate.open()
        _ = try await firstMerge.value
        _ = try await secondMerge.value

        let startedAfterBoth = await started.events
        XCTAssertEqual(startedAfterBoth, [first.content, second.content])
        // The manifest records the last enqueued merge — matching what the daemon ultimately wrote to disk
        XCTAssertEqual(try workspace.lastWrittenHash(), second.hash)
    }
}
