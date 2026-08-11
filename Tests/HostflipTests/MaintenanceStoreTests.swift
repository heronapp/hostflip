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
    func testCheckForUpdatesOpensNewerSemanticVersionRelease() async throws {
        let helper = HelperMaintenanceStub(status: .enabled)
        let releaseURL = try XCTUnwrap(URL(string: "https://github.com/heronapp/hostflip/releases/tag/v0.10.0"))
        let opener = ReleaseOpenerStub()
        let store = makeStore(
            helper: helper,
            currentVersion: "0.9.0",
            latestRelease: {
                GitHubRelease(version: "v0.10.0", pageURL: releaseURL)
            },
            openRelease: { opener.open($0) }
        )

        await store.checkForUpdates()

        XCTAssertEqual(opener.openedURLs, [releaseURL])
        XCTAssertEqual(store.feedback, .updateOpened(version: "0.10.0"))
    }

    @MainActor
    func testCheckForUpdatesReportsWhenCurrentVersionIsLatest() async throws {
        let helper = HelperMaintenanceStub(status: .enabled)
        let releaseURL = try XCTUnwrap(URL(string: "https://github.com/heronapp/hostflip/releases/tag/v0.9.0"))
        let opener = ReleaseOpenerStub()
        let store = makeStore(
            helper: helper,
            currentVersion: "0.9.0",
            latestRelease: {
                GitHubRelease(version: "v0.9.0", pageURL: releaseURL)
            },
            openRelease: { opener.open($0) }
        )

        await store.checkForUpdates()

        XCTAssertTrue(opener.openedURLs.isEmpty)
        XCTAssertEqual(store.feedback, .upToDate(version: "0.9.0"))
    }

    @MainActor
    func testCheckForUpdatesReportsNetworkFailure() async {
        let helper = HelperMaintenanceStub(status: .enabled)
        let store = makeStore(helper: helper)

        await store.checkForUpdates()

        guard case .updateCheckFailed(let message) = store.feedback else {
            return XCTFail("应显示更新检查失败反馈")
        }
        XCTAssertTrue(message.contains("Try again"))
    }

    @MainActor
    private func makeStore(
        helper: HelperMaintenanceStub,
        currentVersion: String = "0.9.0",
        latestRelease: @escaping @Sendable () async throws -> GitHubRelease = { throw StubError() },
        openRelease: @escaping (URL) -> Bool = { _ in true }
    ) -> MaintenanceStore {
        MaintenanceStore(
            currentVersion: currentVersion,
            helperStatus: { await helper.currentStatus() },
            unregisterHelper: { try await helper.unregister() },
            latestRelease: latestRelease,
            openRelease: openRelease
        )
    }
}

@MainActor
private final class ReleaseOpenerStub {
    private(set) var openedURLs: [URL] = []

    func open(_ url: URL) -> Bool {
        openedURLs.append(url)
        return true
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
