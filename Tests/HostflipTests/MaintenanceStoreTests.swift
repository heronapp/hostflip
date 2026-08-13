import Foundation
import HostflipCore
import HostflipXPC
@testable import Hostflip
import XCTest

final class MaintenanceStoreTests: XCTestCase {
    @MainActor
    func testRefreshHelperStatusShowsCurrentRegistrationState() async {
        let helper = HelperMaintenanceStub(status: .enabled)
        let store = makeStore(helper: helper)

        await store.refreshHelperStatus()
        XCTAssertEqual(store.helperStatus, .enabled)

        await helper.setStatus(.requiresApproval)
        await store.refreshHelperStatus()
        XCTAssertEqual(store.helperStatus, .requiresApproval)

        await helper.setStatus(.notRegistered)
        await store.refreshHelperStatus()
        XCTAssertEqual(store.helperStatus, .notRegistered)

        await helper.setStatus(.notFound)
        await store.refreshHelperStatus()
        XCTAssertEqual(store.helperStatus, .notFound)
    }

    @MainActor
    func testRemoveHelperUnregistersAndReportsSuccess() async {
        let helper = HelperMaintenanceStub(status: .enabled)
        let store = makeStore(helper: helper)

        await store.removeHelper()

        let unregisterCallCount = await helper.unregisterCallCount()
        XCTAssertEqual(unregisterCallCount, 1)
        XCTAssertEqual(store.helperStatus, .notRegistered)
        XCTAssertEqual(store.feedback, .helperRemoved)
    }

    @MainActor
    func testRemoveHelperFailureKeepsRetryableFeedbackAndCurrentStatus() async {
        let helper = HelperMaintenanceStub(status: .enabled, unregisterFails: true)
        let store = makeStore(helper: helper)

        await store.removeHelper()

        XCTAssertEqual(store.helperStatus, .enabled)
        guard case .helperRemovalFailed(let message) = store.feedback else {
            return XCTFail("应保留 helper 移除失败反馈")
        }
        XCTAssertTrue(message.contains("Try again"))
    }

    @MainActor
    func testRemoveHelperPreservesWorkspaceProfiles() async throws {
        let rootDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("hostflip-maintenance-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: rootDirectory) }
        let workspace = Workspace(rootDirectory: rootDirectory)
        var model = try workspace.open(systemHosts: { "127.0.0.1 localhost\n" })
        let profileID = Profile.ID("development")
        try model.addProfile(id: profileID, name: "Development", content: "127.0.0.1 dev.local\n")
        try workspace.save(model)
        let store = makeStore(helper: HelperMaintenanceStub(status: .enabled))

        await store.removeHelper()

        let reloaded = try workspace.open(systemHosts: {
            XCTFail("维护操作不应重新初始化工作区")
            return ""
        })
        XCTAssertEqual(reloaded.standaloneProfiles.first?.id, profileID)
        XCTAssertEqual(reloaded.standaloneProfiles.first?.content, "127.0.0.1 dev.local\n")
    }

    @MainActor
    func testApprovalPollingReflectsExternalApprovalWithoutManualRefresh() async {
        let helper = HelperMaintenanceStub(status: .requiresApproval)
        let gate = PollGate()
        let store = MaintenanceStore(
            helperStatus: { await helper.currentStatus() },
            unregisterHelper: { try await helper.unregister() },
            wait: { _ in await gate.waitForTick() }
        )

        await store.refreshHelperStatus()
        XCTAssertEqual(store.helperStatus, .requiresApproval)

        // Approve externally (the System Settings toggle), then release one poll cycle.
        await helper.setStatus(.enabled)
        await gate.tick()
        await waitUntil { store.helperStatus == .enabled }
        XCTAssertEqual(store.helperStatus, .enabled)
    }

    @MainActor
    func testApprovalPollingStopsOnceStatusSettles() async {
        let helper = HelperMaintenanceStub(status: .requiresApproval)
        let gate = PollGate()
        let store = MaintenanceStore(
            helperStatus: { await helper.currentStatus() },
            unregisterHelper: { try await helper.unregister() },
            wait: { _ in await gate.waitForTick() }
        )

        await store.refreshHelperStatus()
        await helper.setStatus(.enabled)
        await gate.tick()
        await waitUntil { store.helperStatus == .enabled }

        // A settled poll loop must not pick this up: no cycle should still be waiting.
        await helper.setStatus(.requiresApproval)
        await gate.tick()
        for _ in 0 ..< 50 { await Task.yield() }
        XCTAssertEqual(store.helperStatus, .enabled, "轮询应在批准后停止")
    }

    /// Yields until the condition holds (the poll task needs a few actor hops to land).
    @MainActor
    private func waitUntil(_ condition: () -> Bool) async {
        for _ in 0 ..< 1000 {
            if condition() { return }
            await Task.yield()
        }
        XCTFail("等待条件超时")
    }

    @MainActor
    private func makeStore(helper: HelperMaintenanceStub) -> MaintenanceStore {
        MaintenanceStore(
            helperStatus: { await helper.currentStatus() },
            unregisterHelper: { try await helper.unregister() }
        )
    }
}

/// Deterministic stand-in for the poll interval: each waitForTick() suspends until
/// the test releases it with tick().
private actor PollGate {
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var pendingTicks = 0

    func waitForTick() async {
        if pendingTicks > 0 {
            pendingTicks -= 1
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    func tick() {
        if waiters.isEmpty {
            pendingTicks += 1
        } else {
            waiters.removeFirst().resume()
        }
    }
}

private actor HelperMaintenanceStub {
    private var status: DaemonRegistrationStatus
    private var unregisterCalls = 0
    private let unregisterFails: Bool

    init(status: DaemonRegistrationStatus, unregisterFails: Bool = false) {
        self.status = status
        self.unregisterFails = unregisterFails
    }

    func currentStatus() -> DaemonRegistrationStatus {
        status
    }

    func setStatus(_ status: DaemonRegistrationStatus) {
        self.status = status
    }

    func unregister() throws {
        unregisterCalls += 1
        if unregisterFails { throw StubError() }
        status = .notRegistered
    }

    func unregisterCallCount() -> Int {
        unregisterCalls
    }
}

private struct StubError: Error {}
