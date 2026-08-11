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
        let initialCheck = expectation(description: "建立监听时立即检查")
        let driftDetected = expectation(description: "原子替换后检测漂移")
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
        let initialCheck = expectation(description: "初查无漂移")
        let firstDrift = expectation(description: "发现第一版漂移")
        let secondDrift = expectation(description: "漂移期间继续报告新现场")
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
        let initialCheck = expectation(description: "初查无漂移")
        let writeObserved = expectation(description: "自身写入以无漂移状态通知")
        let unexpectedDrift = expectation(description: "自身写入不应报警")
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
        let initialCheck = expectation(description: "初查无漂移")
        let writeObserved = expectation(description: "已确认写入以无漂移状态通知")
        let unexpectedDrift = expectation(description: "daemon 已确认写入不应误报")
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

    func testExpectedWriteWindowNeverHidesPreexistingDrift() async throws {
        let target = MergedHosts(content: "10.0.0.1 managed.local\n")
        try Data(target.content.utf8).write(to: hostsURL, options: .atomic)
        let driftDetected = expectation(description: "启动时发现既有漂移")
        let unexpectedClear = expectation(description: "预期窗口不应掩盖既有漂移")
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
        let initialCheck = expectation(description: "初查无漂移")
        let driftDetected = expectation(description: "发现用户将要审阅的漂移")
        let targetAccepted = expectation(description: "调和目标写入不再作为新漂移报告")
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
        let initialCheck = expectation(description: "初查无漂移")
        let unexpectedDrift = expectation(description: "重叠窗口不应误报")
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
