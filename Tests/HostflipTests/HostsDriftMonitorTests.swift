import HostflipCore
import XCTest
@testable import Hostflip

private final class DriftCallbackCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func next() -> Int {
        lock.withLock {
            value += 1
            return value
        }
    }
}

final class HostsDriftMonitorTests: XCTestCase {
    private var rootDirectory: URL!
    private var hostsURL: URL!
    private var workspace: Workspace!

    override func setUpWithError() throws {
        rootDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("hostflip-monitor-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rootDirectory, withIntermediateDirectories: true)
        hostsURL = rootDirectory.appendingPathComponent("hosts")
        let imported = "127.0.0.1 localhost\n"
        try Data(imported.utf8).write(to: hostsURL)
        workspace = Workspace(rootDirectory: rootDirectory.appendingPathComponent("workspace"))
        _ = try workspace.open(systemHosts: { imported })
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: rootDirectory)
    }

    func testStartChecksImmediatelyAndContinuesAfterAtomicReplacement() async throws {
        let initialCheck = expectation(description: "checks immediately when the watch is armed")
        let driftDetected = expectation(description: "detects drift after an atomic replacement")
        let monitor = HostsDriftMonitor(workspace: workspace, hostsURL: hostsURL)
        monitor.start { hasDrift in
            if hasDrift {
                driftDetected.fulfill()
            } else {
                initialCheck.fulfill()
            }
        }

        await fulfillment(of: [initialCheck], timeout: 1)
        try Data("127.0.0.1 localhost\n1.2.3.4 external.local\n".utf8)
            .write(to: hostsURL, options: .atomic)

        await fulfillment(of: [driftDetected], timeout: 1)
        monitor.stop()
    }

    func testReportsAgainWhenTheDriftedContentChanges() async throws {
        let initialCheck = expectation(description: "no drift on the initial check")
        let firstDrift = expectation(description: "reports the first drifted version")
        let secondDrift = expectation(description: "keeps reporting new content while drifted")
        let counter = DriftCallbackCounter()
        let monitor = HostsDriftMonitor(workspace: workspace, hostsURL: hostsURL)
        monitor.start { hasDrift in
            guard hasDrift else {
                initialCheck.fulfill()
                return
            }
            if counter.next() == 1 {
                firstDrift.fulfill()
            } else {
                secondDrift.fulfill()
            }
        }
        await fulfillment(of: [initialCheck], timeout: 1)

        try Data("127.0.0.1 localhost\n1.2.3.4 first.local\n".utf8)
            .write(to: hostsURL, options: .atomic)
        await fulfillment(of: [firstDrift], timeout: 1)

        try Data("127.0.0.1 localhost\n5.6.7.8 second.local\n".utf8)
            .write(to: hostsURL, options: .atomic)
        await fulfillment(of: [secondDrift], timeout: 1)
        monitor.stop()
    }

    func testExpectedDaemonWriteDoesNotReportDrift() async throws {
        let initialCheck = expectation(description: "no drift on the initial check")
        let writeObserved = expectation(description: "reports the own write as drift-free")
        let unexpectedDrift = expectation(description: "an own write must not alert")
        unexpectedDrift.isInverted = true
        let nonDriftCounter = DriftCallbackCounter()
        let monitor = HostsDriftMonitor(workspace: workspace, hostsURL: hostsURL)
        monitor.start { hasDrift in
            if hasDrift {
                unexpectedDrift.fulfill()
            } else if nonDriftCounter.next() == 1 {
                initialCheck.fulfill()
            } else {
                writeObserved.fulfill()
            }
        }
        await fulfillment(of: [initialCheck], timeout: 1)

        let written = MergedHosts(content: "10.0.0.1 managed.local\n")
        await monitor.expectedWriteWillBegin(written.hash)
        try Data(written.content.utf8).write(to: hostsURL, options: .atomic)
        try workspace.recordLastWrittenHash(written.hash)
        await monitor.expectedWriteDidEnd(written.hash)

        await fulfillment(of: [writeObserved, unexpectedDrift], timeout: 1)
        monitor.stop()
    }

    func testConfirmedDaemonWriteDoesNotReportDriftWhenManifestRecordFails() async throws {
        let initialCheck = expectation(description: "no drift on the initial check")
        let writeObserved = expectation(description: "reports the confirmed write as drift-free")
        let unexpectedDrift = expectation(description: "a daemon-confirmed write must not be misreported")
        unexpectedDrift.isInverted = true
        let nonDriftCounter = DriftCallbackCounter()
        let monitor = HostsDriftMonitor(workspace: workspace, hostsURL: hostsURL)
        monitor.start { hasDrift in
            if hasDrift {
                unexpectedDrift.fulfill()
            } else if nonDriftCounter.next() == 1 {
                initialCheck.fulfill()
            } else {
                writeObserved.fulfill()
            }
        }
        await fulfillment(of: [initialCheck], timeout: 1)

        let written = MergedHosts(content: "10.0.0.1 managed.local\n")
        await monitor.expectedWriteWillBegin(written.hash)
        try Data(written.content.utf8).write(to: hostsURL, options: .atomic)
        await monitor.hostsWriteDidConfirm(written.hash)
        await monitor.expectedWriteDidEnd(written.hash)

        let persistedHash = try workspace.expectedSystemHostsHash()
        let baseline = await monitor.expectedCurrentHash(persistedHash: persistedHash)
        XCTAssertEqual(baseline, written.hash)
        await fulfillment(of: [writeObserved, unexpectedDrift], timeout: 1)
        monitor.stop()
    }

    func testRecheckClearsTheDriftVerdictAfterAnExternalWriterRecordsItsBaseline() async throws {
        let initialCheck = expectation(description: "no drift on the initial check")
        let staleDrift = expectation(description: "the file event outruns the manifest record, so the old baseline reads as drift")
        let cleared = expectation(description: "the recheck reads the recorded baseline and clears the stale verdict")
        let driftCounter = DriftCallbackCounter()
        let nonDriftCounter = DriftCallbackCounter()
        let monitor = HostsDriftMonitor(workspace: workspace, hostsURL: hostsURL)
        monitor.start { hasDrift in
            if hasDrift {
                if driftCounter.next() == 1 { staleDrift.fulfill() }
            } else if nonDriftCounter.next() == 1 {
                initialCheck.fulfill()
            } else {
                cleared.fulfill()
            }
        }
        await fulfillment(of: [initialCheck], timeout: 1)

        // An external writer (the CLI) merges through the daemon: the hosts file event reaches
        // the monitor before the writer's recordLastWrittenHash lands, so the check against the
        // still-stale manifest reports drift.
        let written = MergedHosts(content: "10.0.0.1 cli-written.local\n")
        try Data(written.content.utf8).write(to: hostsURL, options: .atomic)
        await fulfillment(of: [staleDrift], timeout: 1)

        // The record lands (no further hosts file event), then the writer's change notification
        // triggers a recheck: the fresh read sees a consistent baseline and clears the verdict.
        try workspace.recordLastWrittenHash(written.hash)
        monitor.recheck()

        await fulfillment(of: [cleared], timeout: 1)
        monitor.stop()
    }

    func testExpectedWriteWindowNeverHidesPreexistingDrift() async throws {
        let target = MergedHosts(content: "10.0.0.1 managed.local\n")
        try Data(target.content.utf8).write(to: hostsURL, options: .atomic)
        let driftDetected = expectation(description: "finds the preexisting drift on start")
        let unexpectedClear = expectation(description: "the expected-write window must not hide preexisting drift")
        unexpectedClear.isInverted = true
        let monitor = HostsDriftMonitor(workspace: workspace, hostsURL: hostsURL)
        monitor.start { hasDrift in
            if hasDrift {
                driftDetected.fulfill()
            } else {
                unexpectedClear.fulfill()
            }
        }
        await fulfillment(of: [driftDetected], timeout: 1)

        await monitor.expectedWriteWillBegin(target.hash)
        try Data(target.content.utf8).write(to: hostsURL, options: .atomic)

        await fulfillment(of: [unexpectedClear], timeout: 0.3)
        monitor.stop()
    }

    func testReviewedDriftWriteTreatsOnlyTheReconciliationTargetAsExpected() async throws {
        let initialCheck = expectation(description: "no drift on the initial check")
        let driftDetected = expectation(description: "reports the drift the user is about to review")
        let targetAccepted = expectation(description: "the reconciliation target write is not reported as new drift")
        let nonDriftCounter = DriftCallbackCounter()
        let monitor = HostsDriftMonitor(workspace: workspace, hostsURL: hostsURL)
        monitor.start { hasDrift in
            if hasDrift {
                driftDetected.fulfill()
            } else if nonDriftCounter.next() == 1 {
                initialCheck.fulfill()
            } else {
                targetAccepted.fulfill()
            }
        }
        await fulfillment(of: [initialCheck], timeout: 1)

        let reviewed = MergedHosts(content: "9.9.9.9 reviewed.local\n")
        try Data(reviewed.content.utf8).write(to: hostsURL, options: .atomic)
        await fulfillment(of: [driftDetected], timeout: 1)

        let target = MergedHosts(content: "10.0.0.1 managed.local\n")
        await monitor.expectedWriteWillBegin(
            target.hash,
            replacingObservedHash: reviewed.hash
        )
        try Data(target.content.utf8).write(to: hostsURL, options: .atomic)
        await fulfillment(of: [targetAccepted], timeout: 1)
        await monitor.hostsWriteDidConfirm(target.hash)
        await monitor.expectedWriteDidEnd(target.hash)
        monitor.stop()
    }

    func testOverlappingExpectedWriteWindowsDoNotClearEachOther() async throws {
        let initialCheck = expectation(description: "no drift on the initial check")
        let unexpectedDrift = expectation(description: "overlapping windows must not misreport")
        unexpectedDrift.isInverted = true
        let nonDriftCounter = DriftCallbackCounter()
        let monitor = HostsDriftMonitor(workspace: workspace, hostsURL: hostsURL)
        monitor.start { hasDrift in
            if hasDrift {
                unexpectedDrift.fulfill()
            } else if nonDriftCounter.next() == 1 {
                initialCheck.fulfill()
            }
        }
        await fulfillment(of: [initialCheck], timeout: 1)

        let first = MergedHosts(content: "10.0.0.1 first.local\n")
        let second = MergedHosts(content: "10.0.0.2 second.local\n")
        await monitor.expectedWriteWillBegin(first.hash)
        try Data(first.content.utf8).write(to: hostsURL, options: .atomic)
        await monitor.expectedWriteWillBegin(second.hash)
        await monitor.expectedWriteDidEnd(second.hash)

        await fulfillment(of: [unexpectedDrift], timeout: 0.3)
        try workspace.recordLastWrittenHash(first.hash)
        await monitor.expectedWriteDidEnd(first.hash)
        monitor.stop()
    }
}
