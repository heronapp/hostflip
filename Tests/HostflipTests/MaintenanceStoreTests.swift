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
    private func makeStore(helper: HelperMaintenanceStub) -> MaintenanceStore {
        MaintenanceStore(
            currentVersion: "0.9.0",
            helperStatus: { await helper.currentStatus() },
            unregisterHelper: { try await helper.unregister() }
        )
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
