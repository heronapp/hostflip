import Foundation
import HostflipCore
import HostflipXPC
import XCTest
@testable import Hostflip

/// SwitchCoordinating stub: records the merged content it receives and replies with preset results, without touching XPC.
@MainActor
private final class SwitchCoordinatingStub: SwitchCoordinating {
    var switchOutcome: Result<SwitchCoordinator.Outcome, any Error> = .success(.merged(hash: "stub"))
    var authorizedMergeOutcome: Result<SwitchCoordinator.Outcome?, any Error> = .success(nil)
    /// Runs before performSwitch returns, simulating the user continuing to act while a switch is in flight.
    var whileSwitchInFlight: (@MainActor () -> Void)?
    /// Runs before reconcile returns, simulating the system hosts changing again while reconciliation is in flight.
    var whileReconciliationInFlight: (@MainActor () -> Void)?
    private(set) var performedSwitches: [MergedHosts] = []
    private(set) var authorizedMerges: [MergedHosts] = []
    private(set) var reconciledMerges: [MergedHosts] = []
    private(set) var reconciliationObservedHashes: [String] = []

    func performSwitch(_ merged: MergedHosts) async throws -> SwitchCoordinator.Outcome {
        performedSwitches.append(merged)
        whileSwitchInFlight?()
        whileSwitchInFlight = nil
        return try switchOutcome.get()
    }

    func mergeIfAuthorized(_ merged: MergedHosts) async throws -> SwitchCoordinator.Outcome? {
        authorizedMerges.append(merged)
        return try authorizedMergeOutcome.get()
    }

    func reconcile(
        _ merged: MergedHosts,
        observedCurrentHash: String
    ) async throws -> SwitchCoordinator.Outcome {
        reconciledMerges.append(merged)
        reconciliationObservedHashes.append(observedCurrentHash)
        whileReconciliationInFlight?()
        whileReconciliationInFlight = nil
        return try switchOutcome.get()
    }
}

private struct StubError: Error {}

private final class HostsDriftMonitoringStub: HostsDriftMonitoring, @unchecked Sendable {
    private var onChange: (@MainActor @Sendable (Bool) -> Void)?

    func start(onChange: @escaping @MainActor @Sendable (Bool) -> Void) {
        self.onChange = onChange
    }

    @MainActor
    func report(_ hasDrift: Bool) {
        onChange?(hasDrift)
    }
}

private final class SystemHostsDataSource: @unchecked Sendable {
    private let lock = NSLock()
    private var data: Data

    init(_ data: Data) {
        self.data = data
    }

    func read() -> Data {
        lock.withLock { data }
    }

    func replace(with data: Data) {
        lock.withLock { self.data = data }
    }
}

final class WorkspaceStoreTests: XCTestCase {
    private static let importedHosts = "127.0.0.1 localhost\n"
    private var rootDirectory: URL!

    override func setUpWithError() throws {
        rootDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("hostflip-store-tests-\(UUID().uuidString)", isDirectory: true)
        _ = try Workspace(rootDirectory: rootDirectory).open(systemHosts: { Self.importedHosts })
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: rootDirectory)
    }

    @MainActor
    func testInitialImportStillRejectsInvalidUTF8SystemHosts() {
        let emptyRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("hostflip-invalid-import-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: emptyRoot) }
        let store = WorkspaceStore(
            workspace: Workspace(rootDirectory: emptyRoot),
            coordinator: SwitchCoordinatingStub(),
            readSystemHosts: { Data([0xFF]) }
        )

        store.loadIfNeeded()

        XCTAssertNil(store.model)
        XCTAssertNotNil(store.loadError)
    }

    // MARK: - Managing standalone profiles

    @MainActor
    func testCreateStandaloneProfileAddsInactiveProfileAndPersists() throws {
        let store = makeStore(coordinator: SwitchCoordinatingStub())

        let profileID = try XCTUnwrap(store.createStandaloneProfile())

        XCTAssertEqual(store.standaloneProfiles.map(\.id), [profileID])
        XCTAssertEqual(store.standaloneProfiles.first?.name, "New Profile")
        XCTAssertFalse(store.isActive(profileID))

        let reloaded = try reloadModel()
        XCTAssertEqual(reloaded.standaloneProfiles.map(\.id), [profileID])
        XCTAssertEqual(reloaded.activeProfileIDs, [])
    }

    @MainActor
    func testCreateStandaloneProfileAvoidsDuplicateDefaultNames() throws {
        let store = makeStore(coordinator: SwitchCoordinatingStub())

        store.createStandaloneProfile()
        store.createStandaloneProfile()

        XCTAssertEqual(store.standaloneProfiles.map(\.name), ["New Profile", "New Profile 2"])
    }

    @MainActor
    func testRenameAndEditPersistAcrossReload() throws {
        let store = makeStore(coordinator: SwitchCoordinatingStub())
        let profileID = try XCTUnwrap(store.createStandaloneProfile())

        store.renameProfile(profileID, to: "本地开发")
        store.updateProfileContent(profileID, content: "1.2.3.4 dev.local\n")

        let reloaded = try reloadModel()
        XCTAssertEqual(reloaded.standaloneProfiles.first?.name, "本地开发")
        XCTAssertEqual(reloaded.standaloneProfiles.first?.content, "1.2.3.4 dev.local\n")
    }

    @MainActor
    func testRenameToBlankNameIsIgnored() throws {
        let store = makeStore(coordinator: SwitchCoordinatingStub())
        let profileID = try XCTUnwrap(store.createStandaloneProfile())

        store.renameProfile(profileID, to: "  \n")

        XCTAssertEqual(store.standaloneProfiles.first?.name, "New Profile")
    }

    @MainActor
    func testDeleteProfilePersistsAndLeavesBaseHostsUntouched() throws {
        let store = makeStore(coordinator: SwitchCoordinatingStub())
        let firstID = try XCTUnwrap(store.createStandaloneProfile())
        let secondID = try XCTUnwrap(store.createStandaloneProfile())

        store.deleteProfile(firstID)

        XCTAssertEqual(store.standaloneProfiles.map(\.id), [secondID])
        XCTAssertEqual(store.baseHostsContent, Self.importedHosts)

        let reloaded = try reloadModel()
        XCTAssertEqual(reloaded.standaloneProfiles.map(\.id), [secondID])
        XCTAssertEqual(reloaded.baseHosts.content, Self.importedHosts)
    }

    // MARK: - Managing groups

    @MainActor
    func testCreateGroupAddsEmptyGroupAndPersists() throws {
        let store = makeStore(coordinator: SwitchCoordinatingStub())

        let groupID = try XCTUnwrap(store.createGroup())

        XCTAssertEqual(store.groups, [Group(id: groupID, name: "New Group", profiles: [])])
        XCTAssertEqual(try reloadModel().groups, store.groups)
    }

    @MainActor
    func testRenameGroupPersistsAndIgnoresBlankName() throws {
        let store = makeStore(coordinator: SwitchCoordinatingStub())
        let groupID = try XCTUnwrap(store.createGroup())

        store.renameGroup(groupID, to: "  Development \n")

        XCTAssertEqual(store.groups.first?.name, "Development")
        XCTAssertEqual(try reloadModel().groups.first?.name, "Development")

        store.renameGroup(groupID, to: "  \n")

        XCTAssertEqual(store.groups.first?.name, "Development")
        XCTAssertEqual(try reloadModel().groups.first?.name, "Development")
    }

    @MainActor
    func testDeleteGroupDissolvesMembersInOrderAndPersistsWithoutAffectingOtherContent() async throws {
        let store = makeStore(coordinator: SwitchCoordinatingStub())
        let standaloneID = try XCTUnwrap(store.createStandaloneProfile())
        let firstMemberID = try XCTUnwrap(store.createStandaloneProfile())
        let secondMemberID = try XCTUnwrap(store.createStandaloneProfile())
        let otherMemberID = try XCTUnwrap(store.createStandaloneProfile())
        let groupID = try XCTUnwrap(store.createGroup())
        let otherGroupID = try XCTUnwrap(store.createGroup())
        store.updateProfileContent(firstMemberID, content: "1.1.1.1 first.local\n")
        store.updateProfileContent(secondMemberID, content: "2.2.2.2 second.local\n")
        store.moveProfile(firstMemberID, toGroup: groupID, at: 0)
        store.moveProfile(secondMemberID, toGroup: groupID, at: 1)
        store.moveProfile(otherMemberID, toGroup: otherGroupID, at: 0)
        store.setProfileActive(secondMemberID, true)
        await store.switchTask?.value
        store.setProfileActive(otherMemberID, true)
        await store.switchTask?.value

        let otherGroup = try XCTUnwrap(store.groups.first(where: { $0.id == otherGroupID }))
        store.deleteGroup(groupID)

        XCTAssertEqual(store.standaloneProfiles.map(\.id), [standaloneID, firstMemberID, secondMemberID])
        XCTAssertEqual(store.profile(firstMemberID)?.content, "1.1.1.1 first.local\n")
        XCTAssertEqual(store.profile(secondMemberID)?.content, "2.2.2.2 second.local\n")
        XCTAssertTrue(store.isActive(secondMemberID))
        XCTAssertTrue(store.isActive(otherMemberID))
        XCTAssertEqual(store.groups, [otherGroup])
        XCTAssertEqual(store.baseHostsContent, Self.importedHosts)

        let reloaded = try reloadModel()
        XCTAssertEqual(reloaded.standaloneProfiles, store.standaloneProfiles)
        XCTAssertEqual(reloaded.groups, [otherGroup])
        XCTAssertEqual(reloaded.activeProfileIDs, [secondMemberID, otherMemberID])
        XCTAssertEqual(reloaded.baseHosts.content, Self.importedHosts)
    }

    @MainActor
    func testDeleteEmptyGroupPersists() throws {
        let store = makeStore(coordinator: SwitchCoordinatingStub())
        let groupID = try XCTUnwrap(store.createGroup())

        store.deleteGroup(groupID)

        XCTAssertEqual(store.groups, [])
        XCTAssertEqual(try reloadModel().groups, [])
        XCTAssertEqual(store.baseHostsContent, Self.importedHosts)
    }

    @MainActor
    func testMoveProfileBetweenStandaloneAreaAndGroupAtRequestedIndexPersists() throws {
        let store = makeStore(coordinator: SwitchCoordinatingStub())
        let firstID = try XCTUnwrap(store.createStandaloneProfile())
        let secondID = try XCTUnwrap(store.createStandaloneProfile())
        let groupID = try XCTUnwrap(store.createGroup())

        store.moveProfile(firstID, toGroup: groupID, at: 0)

        XCTAssertEqual(store.standaloneProfiles.map(\.id), [secondID])
        XCTAssertEqual(store.groups.first?.profiles.map(\.id), [firstID])
        XCTAssertEqual(store.profile(firstID)?.id, firstID)
        XCTAssertEqual(store.group(containing: firstID)?.id, groupID)
        var reloaded = try reloadModel()
        XCTAssertEqual(reloaded.groups.first?.profiles.map(\.id), [firstID])

        store.moveProfile(firstID, toGroup: nil, at: 1)

        XCTAssertEqual(store.standaloneProfiles.map(\.id), [secondID, firstID])
        reloaded = try reloadModel()
        XCTAssertEqual(reloaded.standaloneProfiles.map(\.id), [secondID, firstID])
        XCTAssertEqual(reloaded.groups.first?.profiles, [])
    }

    @MainActor
    func testInsertProfileUsesContainerBoundariesWhenMovingInBothDirections() throws {
        let store = makeStore(coordinator: SwitchCoordinatingStub())
        let firstID = try XCTUnwrap(store.createStandaloneProfile())
        let secondID = try XCTUnwrap(store.createStandaloneProfile())
        let thirdID = try XCTUnwrap(store.createStandaloneProfile())

        store.insertProfile(firstID, toGroup: nil, at: 2)
        XCTAssertEqual(store.standaloneProfiles.map(\.id), [secondID, firstID, thirdID])

        store.insertProfile(thirdID, toGroup: nil, at: 1)
        XCTAssertEqual(store.standaloneProfiles.map(\.id), [secondID, thirdID, firstID])
        XCTAssertEqual(try reloadModel().standaloneProfiles.map(\.id), [secondID, thirdID, firstID])
    }

    @MainActor
    func testInsertProfileAcrossContainersDoesNotAdjustTheDestinationBoundary() throws {
        let store = makeStore(coordinator: SwitchCoordinatingStub())
        let standaloneID = try XCTUnwrap(store.createStandaloneProfile())
        let groupedID = try XCTUnwrap(store.createStandaloneProfile())
        let groupID = try XCTUnwrap(store.createGroup())
        store.moveProfile(groupedID, toGroup: groupID, at: 0)

        store.insertProfile(standaloneID, toGroup: groupID, at: 0)

        XCTAssertEqual(store.standaloneProfiles, [])
        XCTAssertEqual(store.groups.first?.profiles.map(\.id), [standaloneID, groupedID])
        XCTAssertEqual(try reloadModel().groups.first?.profiles.map(\.id), [standaloneID, groupedID])
    }

    @MainActor
    func testGroupProfilesSwitchExclusivelyAndSelectingTheActiveProfileAgainClosesTheGroup() async throws {
        let stub = SwitchCoordinatingStub()
        let store = makeStore(coordinator: stub)
        let firstID = try XCTUnwrap(store.createStandaloneProfile())
        let secondID = try XCTUnwrap(store.createStandaloneProfile())
        let groupID = try XCTUnwrap(store.createGroup())
        store.moveProfile(firstID, toGroup: groupID, at: 0)
        store.moveProfile(secondID, toGroup: groupID, at: 1)

        store.setProfileActive(firstID, true)
        await store.switchTask?.value
        store.setProfileActive(secondID, true)
        await store.switchTask?.value

        XCTAssertFalse(store.isActive(firstID))
        XCTAssertTrue(store.isActive(secondID))
        XCTAssertEqual(try reloadModel().activeProfileIDs, [secondID])

        store.setProfileActive(secondID, false)
        await store.switchTask?.value

        XCTAssertEqual(try reloadModel().activeProfileIDs, [])
        XCTAssertEqual(stub.performedSwitches.count, 3)
    }

    @MainActor
    func testMoveThatDeactivatesAProfileIsNotCommittedWhenAuthorizedSwitchIsBlocked() async throws {
        let stub = SwitchCoordinatingStub()
        let store = makeStore(coordinator: stub)
        let groupedID = try XCTUnwrap(store.createStandaloneProfile())
        let standaloneID = try XCTUnwrap(store.createStandaloneProfile())
        let groupID = try XCTUnwrap(store.createGroup())
        store.moveProfile(groupedID, toGroup: groupID, at: 0)
        store.setProfileActive(groupedID, true)
        await store.switchTask?.value
        store.setProfileActive(standaloneID, true)
        await store.switchTask?.value

        stub.switchOutcome = .success(.blocked(.needsApproval))
        store.moveProfile(standaloneID, toGroup: groupID, at: 1)
        XCTAssertTrue(store.isSwitching)
        await store.switchTask?.value

        XCTAssertEqual(store.standaloneProfiles.map(\.id), [standaloneID])
        XCTAssertEqual(store.groups.first?.profiles.map(\.id), [groupedID])
        XCTAssertTrue(store.isActive(groupedID))
        XCTAssertTrue(store.isActive(standaloneID))
        XCTAssertEqual(store.switchFeedback, .needsApproval)
        let reloaded = try reloadModel()
        XCTAssertEqual(reloaded.standaloneProfiles.map(\.id), [standaloneID])
        XCTAssertEqual(reloaded.groups.first?.profiles.map(\.id), [groupedID])
        XCTAssertEqual(reloaded.activeProfileIDs, [groupedID, standaloneID])
    }

    @MainActor
    func testMoveThatDeactivatesAProfileCommitsAfterAuthorizedSwitchSucceeds() async throws {
        let stub = SwitchCoordinatingStub()
        let store = makeStore(coordinator: stub)
        let groupedID = try XCTUnwrap(store.createStandaloneProfile())
        let standaloneID = try XCTUnwrap(store.createStandaloneProfile())
        let groupID = try XCTUnwrap(store.createGroup())
        store.updateProfileContent(groupedID, content: "1.1.1.1 grouped.local\n")
        store.updateProfileContent(standaloneID, content: "2.2.2.2 standalone.local\n")
        store.moveProfile(groupedID, toGroup: groupID, at: 0)
        store.setProfileActive(groupedID, true)
        await store.switchTask?.value
        store.setProfileActive(standaloneID, true)
        await store.switchTask?.value

        store.moveProfile(standaloneID, toGroup: groupID, at: 1)
        XCTAssertTrue(store.isSwitching)
        await store.switchTask?.value

        XCTAssertEqual(store.standaloneProfiles, [])
        XCTAssertEqual(store.groups.first?.profiles.map(\.id), [groupedID, standaloneID])
        XCTAssertTrue(store.isActive(groupedID))
        XCTAssertFalse(store.isActive(standaloneID))
        XCTAssertEqual(store.switchFeedback, .merged)
        XCTAssertTrue(try XCTUnwrap(stub.performedSwitches.last).content.contains("grouped.local"))
        XCTAssertFalse(try XCTUnwrap(stub.performedSwitches.last).content.contains("standalone.local"))
        let reloaded = try reloadModel()
        XCTAssertEqual(reloaded.groups.first?.profiles.map(\.id), [groupedID, standaloneID])
        XCTAssertEqual(reloaded.activeProfileIDs, [groupedID])
    }

    @MainActor
    func testReorderGroupsPersistsAndDeterminesMergeOrder() async throws {
        let store = makeStore(coordinator: SwitchCoordinatingStub())
        let firstProfileID = try XCTUnwrap(store.createStandaloneProfile())
        let secondProfileID = try XCTUnwrap(store.createStandaloneProfile())
        let firstGroupID = try XCTUnwrap(store.createGroup())
        let secondGroupID = try XCTUnwrap(store.createGroup())
        store.moveProfile(firstProfileID, toGroup: firstGroupID, at: 0)
        store.moveProfile(secondProfileID, toGroup: secondGroupID, at: 0)
        store.setProfileActive(firstProfileID, true)
        await store.switchTask?.value
        store.setProfileActive(secondProfileID, true)
        await store.switchTask?.value

        store.moveGroup(secondGroupID, toIndex: 0)

        XCTAssertEqual(store.groups.map(\.id), [secondGroupID, firstGroupID])
        let reloaded = try reloadModel()
        XCTAssertEqual(reloaded.groups.map(\.id), [secondGroupID, firstGroupID])
        XCTAssertEqual(reloaded.effectiveCombination.profiles.map(\.id), [secondProfileID, firstProfileID])
    }

    @MainActor
    func testInsertGroupUsesListBoundariesWhenMovingInBothDirections() throws {
        let store = makeStore(coordinator: SwitchCoordinatingStub())
        let firstID = try XCTUnwrap(store.createGroup())
        let secondID = try XCTUnwrap(store.createGroup())
        let thirdID = try XCTUnwrap(store.createGroup())

        store.insertGroup(firstID, at: 2)
        XCTAssertEqual(store.groups.map(\.id), [secondID, firstID, thirdID])

        store.insertGroup(thirdID, at: 1)
        XCTAssertEqual(store.groups.map(\.id), [secondID, thirdID, firstID])
        XCTAssertEqual(try reloadModel().groups.map(\.id), [secondID, thirdID, firstID])
    }

    @MainActor
    func testReorderStandaloneProfilesPersistsAndDeterminesMergeOrder() async throws {
        let store = makeStore(coordinator: SwitchCoordinatingStub())
        let firstID = try XCTUnwrap(store.createStandaloneProfile())
        let secondID = try XCTUnwrap(store.createStandaloneProfile())
        store.setProfileActive(firstID, true)
        await store.switchTask?.value
        store.setProfileActive(secondID, true)
        await store.switchTask?.value

        store.moveProfile(secondID, toGroup: nil, at: 0)

        XCTAssertEqual(store.standaloneProfiles.map(\.id), [secondID, firstID])
        let reloaded = try reloadModel()
        XCTAssertEqual(reloaded.standaloneProfiles.map(\.id), [secondID, firstID])
        XCTAssertEqual(reloaded.effectiveCombination.profiles.map(\.id), [secondID, firstID])
    }

    @MainActor
    func testFollowUpMergeSelfSigningFailureUsesFriendlyBackgroundError() async throws {
        let coordinator = SwitchCoordinatingStub()
        coordinator.authorizedMergeOutcome = .success(.channelFailed(
            .selfSigningUnavailable,
            statusAfterError: .enabled
        ))
        let store = makeStore(coordinator: coordinator)

        _ = try XCTUnwrap(store.createStandaloneProfile())
        await store.followUpMergeTask?.value

        XCTAssertNil(store.saveError)
        XCTAssertEqual(
            store.backgroundSyncError,
            "Changes were saved locally, but this build is not properly signed, so the system hosts file could not be updated."
        )
        store.clearBackgroundSyncError()
        XCTAssertNil(store.backgroundSyncError)
    }

    // MARK: - Switching active state

    @MainActor
    func testActivateCommitsPersistsAndReportsSuccessOnMergedOutcome() async throws {
        let stub = SwitchCoordinatingStub()
        let store = makeStore(coordinator: stub)
        let profileID = try XCTUnwrap(store.createStandaloneProfile())
        store.updateProfileContent(profileID, content: "1.2.3.4 dev.local\n")

        store.setProfileActive(profileID, true)
        XCTAssertTrue(store.isSwitching)
        await store.switchTask?.value

        XCTAssertFalse(store.isSwitching)
        XCTAssertTrue(store.isActive(profileID))
        XCTAssertEqual(store.switchFeedback, .merged)
        // The merged content sent to the daemon already includes the newly active profile
        XCTAssertTrue(try XCTUnwrap(stub.performedSwitches.last).content.contains("1.2.3.4 dev.local"))
        XCTAssertEqual(try reloadModel().activeProfileIDs, [profileID])
    }

    @MainActor
    func testDeactivateGoesThroughSwitchAndPersists() async throws {
        let stub = SwitchCoordinatingStub()
        let store = makeStore(coordinator: stub)
        let profileID = try XCTUnwrap(store.createStandaloneProfile())
        store.updateProfileContent(profileID, content: "1.2.3.4 dev.local\n")
        store.setProfileActive(profileID, true)
        await store.switchTask?.value

        store.setProfileActive(profileID, false)
        await store.switchTask?.value

        XCTAssertFalse(store.isActive(profileID))
        XCTAssertFalse(try XCTUnwrap(stub.performedSwitches.last).content.contains("1.2.3.4 dev.local"))
        XCTAssertEqual(try reloadModel().activeProfileIDs, [])
    }

    @MainActor
    func testPauseWritesOnlyBaseHostsWhilePreservingActiveProfileState() async throws {
        let stub = SwitchCoordinatingStub()
        let store = makeStore(coordinator: stub)
        let profileID = try XCTUnwrap(store.createStandaloneProfile())
        store.updateProfileContent(profileID, content: "1.2.3.4 dev.local\n")
        store.setProfileActive(profileID, true)
        await store.switchTask?.value

        store.setPaused(true)
        await store.switchTask?.value

        XCTAssertTrue(store.isPaused)
        XCTAssertTrue(store.isActive(profileID))
        XCTAssertFalse(store.hasEffectiveProfiles)
        XCTAssertFalse(try XCTUnwrap(stub.performedSwitches.last).content.contains("1.2.3.4 dev.local"))
        let reloaded = try reloadModel()
        XCTAssertTrue(reloaded.isPaused)
        XCTAssertEqual(reloaded.activeProfileIDs, [profileID])

        store.setPaused(false)
        await store.switchTask?.value

        XCTAssertFalse(store.isPaused)
        XCTAssertTrue(store.hasEffectiveProfiles)
        XCTAssertTrue(try XCTUnwrap(stub.performedSwitches.last).content.contains("1.2.3.4 dev.local"))
        XCTAssertFalse(try reloadModel().isPaused)
    }

    @MainActor
    func testPauseIsNotCommittedWhenAuthorizedSwitchIsBlocked() async throws {
        let stub = SwitchCoordinatingStub()
        stub.switchOutcome = .success(.blocked(.needsApproval))
        let store = makeStore(coordinator: stub)

        store.setPaused(true)
        await store.switchTask?.value

        XCTAssertFalse(store.isPaused)
        XCTAssertEqual(store.switchFeedback, .needsApproval)
        XCTAssertFalse(try reloadModel().isPaused)
    }

    @MainActor
    func testDetectedDriftBlocksUserSwitchBeforeCoordinatorAndKeepsStateUnchanged() throws {
        let coordinator = SwitchCoordinatingStub()
        let monitor = HostsDriftMonitoringStub()
        let store = makeStore(coordinator: coordinator, driftMonitor: monitor)
        let profileID = try XCTUnwrap(store.createStandaloneProfile())
        monitor.report(true)

        store.setProfileActive(profileID, true)

        XCTAssertTrue(store.hasHostsDrift)
        XCTAssertFalse(store.isSwitching)
        XCTAssertFalse(store.isActive(profileID))
        XCTAssertEqual(store.switchFeedback, .hostsDrift)
        XCTAssertEqual(coordinator.performedSwitches, [])
        XCTAssertEqual(try reloadModel().activeProfileIDs, [])
    }

    @MainActor
    func testDetectedDriftLoadsReadableDiffAgainstExpectedMergedHosts() throws {
        let actualHosts = "127.0.0.1 localhost\n"
            + "1.2.3.4 external.local\n"
        let monitor = HostsDriftMonitoringStub()
        let store = makeStore(
            coordinator: SwitchCoordinatingStub(),
            driftMonitor: monitor,
            systemHosts: Data(actualHosts.utf8)
        )

        monitor.report(true)

        let comparison = try XCTUnwrap(store.hostsDriftComparison)
        XCTAssertEqual(
            comparison.readableDiff,
            "--- hostflip expected\n+++ system hosts actual\n+ 1.2.3.4 external.local"
        )
        XCTAssertEqual(comparison.driftAdditions, ["1.2.3.4 external.local"])
        XCTAssertEqual(comparison.observedActualHash, MergedHosts.hash(of: Data(actualHosts.utf8)))
    }

    @MainActor
    func testSystemHostsSnapshotLoadsAndRefreshesIndependentlyOfWorkspace() {
        let systemHosts = SystemHostsDataSource(Data("1.1.1.1 first.local\n".utf8))
        let store = WorkspaceStore(
            workspace: Workspace(rootDirectory: rootDirectory),
            coordinator: SwitchCoordinatingStub(),
            readSystemHosts: systemHosts.read
        )

        store.loadIfNeeded()

        XCTAssertEqual(store.systemHostsContent, "1.1.1.1 first.local\n")
        XCTAssertNil(store.systemHostsReadError)

        systemHosts.replace(with: Data("2.2.2.2 second.local\n".utf8))
        store.refreshSystemHosts()

        XCTAssertEqual(store.systemHostsContent, "2.2.2.2 second.local\n")
        XCTAssertNil(store.systemHostsReadError)
    }

    @MainActor
    func testSystemHostsSnapshotRejectsInvalidUTF8WithoutBlockingWorkspace() {
        let store = WorkspaceStore(
            workspace: Workspace(rootDirectory: rootDirectory),
            coordinator: SwitchCoordinatingStub(),
            readSystemHosts: { Data([0xFF]) }
        )

        store.loadIfNeeded()

        XCTAssertNotNil(store.model)
        XCTAssertNil(store.systemHostsContent)
        XCTAssertNotNil(store.systemHostsReadError)
    }

    @MainActor
    func testSystemHostsSnapshotRefreshesWhenMonitorReportsANonDriftWrite() {
        let systemHosts = SystemHostsDataSource(Data("1.1.1.1 first.local\n".utf8))
        let monitor = HostsDriftMonitoringStub()
        let store = WorkspaceStore(
            workspace: Workspace(rootDirectory: rootDirectory),
            coordinator: SwitchCoordinatingStub(),
            driftMonitor: monitor,
            readSystemHosts: systemHosts.read
        )
        store.loadIfNeeded()
        systemHosts.replace(with: Data("2.2.2.2 hostflip-write.local\n".utf8))

        monitor.report(false)

        XCTAssertEqual(store.systemHostsContent, "2.2.2.2 hostflip-write.local\n")
        XCTAssertNil(store.systemHostsReadError)
    }

    func testReorderedLinesAreNotTreatedAsDriftAdditions() {
        let comparison = HostsDriftComparison(
            expectedContent: "1.1.1.1 first.local\n2.2.2.2 second.local\n",
            actualData: Data("2.2.2.2 second.local\n1.1.1.1 first.local\n".utf8)
        )

        XCTAssertEqual(comparison.driftAdditions, [])
    }

    @MainActor
    func testAddingDriftLinesToBaseHostsAppendsAndReconcilesObservedDrift() async throws {
        let actualHosts = "127.0.0.1 localhost\n"
            + "1.2.3.4 external.local\n"
        let coordinator = SwitchCoordinatingStub()
        let monitor = HostsDriftMonitoringStub()
        let store = makeStore(
            coordinator: coordinator,
            driftMonitor: monitor,
            systemHosts: Data(actualHosts.utf8)
        )
        monitor.report(true)
        var stayedBlockedDuringWrite = false
        coordinator.whileReconciliationInFlight = {
            monitor.report(false)
            stayedBlockedDuringWrite = store.hasHostsDrift
        }

        store.reconcileHosts(.addDriftLinesToBaseHosts)
        await store.reconciliationTask?.value

        XCTAssertTrue(stayedBlockedDuringWrite)
        XCTAssertEqual(store.baseHostsContent, Self.importedHosts + "1.2.3.4 external.local\n")
        XCTAssertEqual(coordinator.reconciledMerges, [try XCTUnwrap(store.model).mergedHosts])
        XCTAssertEqual(
            coordinator.reconciliationObservedHashes,
            [MergedHosts.hash(of: Data(actualHosts.utf8))]
        )
        XCTAssertFalse(store.hasHostsDrift)
        XCTAssertNil(store.hostsDriftComparison)
        XCTAssertEqual(try reloadModel().baseHosts.content, store.baseHostsContent)

        let profileID = try XCTUnwrap(store.createStandaloneProfile())
        store.setProfileActive(profileID, true)
        await store.switchTask?.value
        XCTAssertTrue(store.isActive(profileID))
        XCTAssertEqual(coordinator.performedSwitches.count, 1)
    }

    @MainActor
    func testUsingSystemHostsAsBaseAcceptsCurrentFileWithoutRewritingIt() throws {
        let actualHosts = Data("9.9.9.9 adopted.local\n".utf8)
        let coordinator = SwitchCoordinatingStub()
        let monitor = HostsDriftMonitoringStub()
        let store = makeStore(
            coordinator: coordinator,
            driftMonitor: monitor,
            systemHosts: actualHosts
        )
        let originalBackupURL = rootDirectory.appendingPathComponent("hosts.orig")
        let originalBackup = try Data(contentsOf: originalBackupURL)
        monitor.report(true)

        XCTAssertNil(store.useSystemHostsAsBaseUnavailableReason)
        store.useSystemHostsAsBase()

        XCTAssertEqual(store.baseHostsContent, String(decoding: actualHosts, as: UTF8.self))
        XCTAssertEqual(try reloadModel().baseHosts.content, store.baseHostsContent)
        XCTAssertEqual(
            try Workspace(rootDirectory: rootDirectory).lastWrittenHash(),
            MergedHosts.hash(of: actualHosts)
        )
        XCTAssertEqual(try Data(contentsOf: originalBackupURL), originalBackup)
        XCTAssertEqual(coordinator.reconciledMerges, [])
        XCTAssertFalse(store.hasHostsDrift)
        XCTAssertNil(store.hostsDriftComparison)
        XCTAssertEqual(store.switchFeedback, .baseHostsReplaced)
    }

    @MainActor
    func testUsingSystemHostsAsBaseCancelsAPendingBackgroundMerge() async {
        let actualHosts = Data("9.9.9.9 adopted.local\n".utf8)
        let coordinator = SwitchCoordinatingStub()
        let monitor = HostsDriftMonitoringStub()
        let store = makeStore(
            coordinator: coordinator,
            driftMonitor: monitor,
            systemHosts: actualHosts
        )
        _ = store.createStandaloneProfile()
        monitor.report(true)

        store.useSystemHostsAsBase()
        await store.followUpMergeTask?.value

        XCTAssertEqual(store.baseHostsContent, String(decoding: actualHosts, as: UTF8.self))
        XCTAssertEqual(coordinator.authorizedMerges, [])
    }

    @MainActor
    func testUsingSystemHostsAsBasePreservesPausedStateWhenNoProfileIsActive() async {
        let actualHosts = Data("9.9.9.9 adopted.local\n".utf8)
        let coordinator = SwitchCoordinatingStub()
        let monitor = HostsDriftMonitoringStub()
        let store = makeStore(
            coordinator: coordinator,
            driftMonitor: monitor,
            systemHosts: actualHosts
        )
        store.setPaused(true)
        await store.switchTask?.value
        monitor.report(true)

        XCTAssertNil(store.useSystemHostsAsBaseUnavailableReason)
        store.useSystemHostsAsBase()

        XCTAssertTrue(store.isPaused)
        XCTAssertEqual(store.baseHostsContent, String(decoding: actualHosts, as: UTF8.self))
    }

    @MainActor
    func testUsingSystemHostsAsBaseRejectsAFileChangedAfterReview() throws {
        let reviewedHosts = Data("9.9.9.9 reviewed.local\n".utf8)
        let latestHosts = Data("8.8.8.8 latest.local\n".utf8)
        let systemHosts = SystemHostsDataSource(reviewedHosts)
        let monitor = HostsDriftMonitoringStub()
        let store = WorkspaceStore(
            workspace: Workspace(rootDirectory: rootDirectory),
            coordinator: SwitchCoordinatingStub(),
            driftMonitor: monitor,
            readSystemHosts: systemHosts.read
        )
        store.loadIfNeeded()
        monitor.report(true)
        systemHosts.replace(with: latestHosts)

        store.useSystemHostsAsBase()

        XCTAssertEqual(store.baseHostsContent, Self.importedHosts)
        XCTAssertEqual(try reloadModel().baseHosts.content, Self.importedHosts)
        XCTAssertTrue(store.hasHostsDrift)
        XCTAssertEqual(
            store.hostsDriftComparison?.observedActualHash,
            MergedHosts.hash(of: latestHosts)
        )
        XCTAssertNotNil(store.reconciliationError)
        XCTAssertEqual(store.switchFeedback, .hostsDrift)
    }

    @MainActor
    func testUsingSystemHostsAsBaseIsUnavailableWithAnActiveProfile() async throws {
        let coordinator = SwitchCoordinatingStub()
        let monitor = HostsDriftMonitoringStub()
        let store = makeStore(coordinator: coordinator, driftMonitor: monitor)
        let profileID = try XCTUnwrap(store.createStandaloneProfile())
        store.setProfileActive(profileID, true)
        await store.switchTask?.value
        monitor.report(true)

        XCTAssertNotNil(store.useSystemHostsAsBaseUnavailableReason)
        store.useSystemHostsAsBase()

        XCTAssertEqual(store.baseHostsContent, Self.importedHosts)
        XCTAssertTrue(store.hasHostsDrift)
    }

    @MainActor
    func testUsingSystemHostsAsBaseIsUnavailableForGeneratedHostflipOutput() {
        let generatedHosts = Data((
            Self.importedHosts
                + "\n" + MergedHosts.appendedBlockBegin + "\n"
                + "# ── Blocker ──\n0.0.0.0 ads.example.com\n"
                + MergedHosts.appendedBlockEnd + "\n"
        ).utf8)
        let monitor = HostsDriftMonitoringStub()
        let store = makeStore(
            coordinator: SwitchCoordinatingStub(),
            driftMonitor: monitor,
            systemHosts: generatedHosts
        )
        monitor.report(true)

        XCTAssertNotNil(store.useSystemHostsAsBaseUnavailableReason)
        store.useSystemHostsAsBase()

        XCTAssertEqual(store.baseHostsContent, Self.importedHosts)
        XCTAssertTrue(store.hasHostsDrift)
    }

    @MainActor
    func testUsingSystemHostsAsBaseIsUnavailableForLegacyBannerOutput() {
        // Files written by releases up to 0.1.1 carry the old top banner and
        // must be recognized as generated output just like the new fence.
        let generatedHosts = Data((
            MergedHosts.legacyGeneratedBanner + "\n"
                + "# ── hostflip: Base Hosts ──\n"
                + Self.importedHosts
        ).utf8)
        let monitor = HostsDriftMonitoringStub()
        let store = makeStore(
            coordinator: SwitchCoordinatingStub(),
            driftMonitor: monitor,
            systemHosts: generatedHosts
        )
        monitor.report(true)

        XCTAssertNotNil(store.useSystemHostsAsBaseUnavailableReason)
    }

    @MainActor
    func testOverwritingDriftReconcilesCurrentActiveStateWithoutChangingBase() async throws {
        let actualHosts = "# drifted content\n9.9.9.9 unknown.local\n"
        let coordinator = SwitchCoordinatingStub()
        let monitor = HostsDriftMonitoringStub()
        let store = makeStore(
            coordinator: coordinator,
            driftMonitor: monitor,
            systemHosts: Data(actualHosts.utf8)
        )
        let expected = try XCTUnwrap(store.model).mergedHosts
        monitor.report(true)

        store.reconcileHosts(.overwriteDriftWithActiveState)
        await store.reconciliationTask?.value

        XCTAssertEqual(coordinator.reconciledMerges, [expected])
        XCTAssertEqual(
            coordinator.reconciliationObservedHashes,
            [MergedHosts.hash(of: Data(actualHosts.utf8))]
        )
        XCTAssertEqual(store.baseHostsContent, Self.importedHosts)
        XCTAssertEqual(try reloadModel().baseHosts.content, Self.importedHosts)
        XCTAssertFalse(store.hasHostsDrift)
    }

    @MainActor
    func testPostponingReconciliationKeepsWarningAndBlocksNewSwitchWrites() throws {
        let coordinator = SwitchCoordinatingStub()
        let monitor = HostsDriftMonitoringStub()
        let store = makeStore(coordinator: coordinator, driftMonitor: monitor)
        let profileID = try XCTUnwrap(store.createStandaloneProfile())
        monitor.report(true)

        store.reconcileHosts(.later)
        store.setProfileActive(profileID, true)

        XCTAssertTrue(store.hasHostsDrift)
        XCTAssertNotNil(store.hostsDriftComparison)
        XCTAssertEqual(store.switchFeedback, .hostsDrift)
        XCTAssertEqual(coordinator.reconciledMerges, [])
        XCTAssertEqual(coordinator.performedSwitches, [])
        XCTAssertFalse(store.isActive(profileID))
    }

    @MainActor
    func testFailedReconciliationKeepsDriftAndCanBeRetried() async throws {
        let coordinator = SwitchCoordinatingStub()
        coordinator.switchOutcome = .success(.channelFailed(.unavailable, statusAfterError: .enabled))
        let monitor = HostsDriftMonitoringStub()
        let store = makeStore(coordinator: coordinator, driftMonitor: monitor)
        monitor.report(true)

        store.reconcileHosts(.addDriftLinesToBaseHosts)
        await store.reconciliationTask?.value

        XCTAssertTrue(store.hasHostsDrift)
        XCTAssertNotNil(store.hostsDriftComparison)
        XCTAssertNotNil(store.reconciliationError)
        XCTAssertEqual(store.baseHostsContent, Self.importedHosts)

        coordinator.switchOutcome = .success(.merged(hash: "retried"))
        store.reconcileHosts(.addDriftLinesToBaseHosts)
        await store.reconciliationTask?.value

        XCTAssertFalse(store.hasHostsDrift)
        XCTAssertNil(store.reconciliationError)
    }

    @MainActor
    func testSwitchCommitsWhenReplacementLandedAndOnlyDNSRefreshFailed() async throws {
        let stub = SwitchCoordinatingStub()
        let store = makeStore(coordinator: stub)
        let profileID = try XCTUnwrap(store.createStandaloneProfile())
        store.updateProfileContent(profileID, content: "9.9.9.9 landed.local\n")

        // Capture the merged hash the activation will target, then roll back.
        store.setProfileActive(profileID, true)
        await store.switchTask?.value
        let targetHash = try XCTUnwrap(stub.performedSwitches.last?.hash)
        store.setProfileActive(profileID, false)
        await store.switchTask?.value

        stub.switchOutcome = .success(.channelFailed(
            .mergeWriteFailed(HostsWriteError(
                stage: .flushDNS,
                message: "refresh failed",
                writtenHash: targetHash
            )),
            statusAfterError: .enabled
        ))
        store.setProfileActive(profileID, true)
        await store.switchTask?.value

        // The replacement physically landed, so the switch is committed and
        // persisted; only the flush failure is surfaced.
        XCTAssertTrue(store.isActive(profileID))
        XCTAssertEqual(try reloadModel().activeProfileIDs, [profileID])
        XCTAssertEqual(
            store.switchFeedback,
            .failed("System hosts was updated, but DNS refresh failed: refresh failed")
        )
    }

    @MainActor
    func testReconciliationPreservesKeptLinesWhenReplacementPrecedesDNSFailure() async throws {
        let actualHosts = "127.0.0.1 localhost\n"
            + "1.2.3.4 external.local\n"
        let failure = HostsWriteError(
            stage: .flushDNS,
            message: "refresh failed",
            writtenHash: MergedHosts(content: actualHosts).hash
        )
        let coordinator = SwitchCoordinatingStub()
        coordinator.switchOutcome = .success(.channelFailed(
            .mergeWriteFailed(failure),
            statusAfterError: .enabled
        ))
        let monitor = HostsDriftMonitoringStub()
        let store = makeStore(
            coordinator: coordinator,
            driftMonitor: monitor,
            systemHosts: Data(actualHosts.utf8)
        )
        monitor.report(true)

        store.reconcileHosts(.addDriftLinesToBaseHosts)
        await store.reconciliationTask?.value

        XCTAssertEqual(store.baseHostsContent, Self.importedHosts + "1.2.3.4 external.local\n")
        XCTAssertEqual(try reloadModel().baseHosts.content, store.baseHostsContent)
        XCTAssertEqual(
            try Workspace(rootDirectory: rootDirectory).lastWrittenHash(),
            failure.writtenHash
        )
        XCTAssertFalse(store.hasHostsDrift)
        XCTAssertNotNil(store.reconciliationError)
        guard case .failed = store.switchFeedback else {
            return XCTFail("DNS 刷新失败应保留失败反馈")
        }

        monitor.report(false)
        XCTAssertNotNil(store.reconciliationError)
    }

    @MainActor
    func testNewDriftWhileReconciliationIsInFlightKeepsLatestWarning() async throws {
        let firstDrift = Data("9.9.9.9 first.local\n".utf8)
        let latestDrift = Data("8.8.8.8 latest.local\n".utf8)
        let systemHosts = SystemHostsDataSource(firstDrift)
        let coordinator = SwitchCoordinatingStub()
        let monitor = HostsDriftMonitoringStub()
        let store = WorkspaceStore(
            workspace: Workspace(rootDirectory: rootDirectory),
            coordinator: coordinator,
            driftMonitor: monitor,
            readSystemHosts: systemHosts.read
        )
        store.loadIfNeeded()
        monitor.report(true)
        coordinator.whileReconciliationInFlight = {
            systemHosts.replace(with: latestDrift)
            monitor.report(true)
        }

        store.reconcileHosts(.overwriteDriftWithActiveState)
        await store.reconciliationTask?.value
        monitor.report(false)

        XCTAssertTrue(store.hasHostsDrift)
        XCTAssertEqual(
            store.hostsDriftComparison?.observedActualHash,
            MergedHosts.hash(of: latestDrift)
        )
        XCTAssertNotNil(store.reconciliationError)
        XCTAssertEqual(store.baseHostsContent, Self.importedHosts)
    }

    @MainActor
    func testWorkspaceSaveFailureAfterReconciliationKeepsWritesBlocked() async throws {
        let actualHosts = Data("1.2.3.4 external.local\n".utf8)
        let coordinator = SwitchCoordinatingStub()
        let monitor = HostsDriftMonitoringStub()
        let store = makeStore(
            coordinator: coordinator,
            driftMonitor: monitor,
            systemHosts: actualHosts
        )
        monitor.report(true)
        try Data("invalid manifest".utf8).write(
            to: rootDirectory.appendingPathComponent("manifest.json"),
            options: .atomic
        )

        store.reconcileHosts(.addDriftLinesToBaseHosts)
        await store.reconciliationTask?.value
        monitor.report(false)

        XCTAssertTrue(store.hasHostsDrift)
        XCTAssertNotNil(store.saveError)
        XCTAssertNil(store.backgroundSyncError)
        XCTAssertNotNil(store.reconciliationError)
        guard case .failed = store.switchFeedback else {
            return XCTFail("工作区保存失败后应保留失败反馈")
        }
    }

    @MainActor
    func testDaemonPreflightDriftRejectionEntersTheSameBlockedState() async throws {
        let coordinator = SwitchCoordinatingStub()
        coordinator.switchOutcome = .success(.channelFailed(
            .mergeRejected(.hostsDrift(expected: "prior", actual: "drifted")),
            statusAfterError: .enabled
        ))
        let store = makeStore(coordinator: coordinator)
        let profileID = try XCTUnwrap(store.createStandaloneProfile())

        store.setProfileActive(profileID, true)
        await store.switchTask?.value

        XCTAssertTrue(store.hasHostsDrift)
        XCTAssertFalse(store.isActive(profileID))
        XCTAssertEqual(store.switchFeedback, .hostsDrift)
        XCTAssertEqual(try reloadModel().activeProfileIDs, [])
    }

    @MainActor
    func testDriftDetectionContinuesWhilePaused() async {
        let monitor = HostsDriftMonitoringStub()
        let store = makeStore(coordinator: SwitchCoordinatingStub(), driftMonitor: monitor)
        store.setPaused(true)
        await store.switchTask?.value
        XCTAssertTrue(store.isPaused)

        monitor.report(true)

        XCTAssertTrue(store.hasHostsDrift)
        XCTAssertTrue(store.isPaused)
    }

    @MainActor
    func testSettingSameActivationStateDoesNotSwitch() async throws {
        let stub = SwitchCoordinatingStub()
        let store = makeStore(coordinator: stub)
        let profileID = try XCTUnwrap(store.createStandaloneProfile())

        store.setProfileActive(profileID, false)
        await store.switchTask?.value

        XCTAssertEqual(stub.performedSwitches, [])
        XCTAssertNil(store.switchFeedback)
    }

    @MainActor
    func testActivationUnchangedWhenBlocked() async throws {
        let stub = SwitchCoordinatingStub()
        stub.switchOutcome = .success(.blocked(.needsApproval))
        let store = makeStore(coordinator: stub)
        let profileID = try XCTUnwrap(store.createStandaloneProfile())

        store.setProfileActive(profileID, true)
        await store.switchTask?.value

        XCTAssertFalse(store.isActive(profileID))
        XCTAssertEqual(store.switchFeedback, .needsApproval)
        XCTAssertEqual(try reloadModel().activeProfileIDs, [])
    }

    @MainActor
    func testActivationUnchangedOnChannelFailure() async throws {
        let stub = SwitchCoordinatingStub()
        stub.switchOutcome = .success(.channelFailed(.unavailable, statusAfterError: .notFound))
        let store = makeStore(coordinator: stub)
        let profileID = try XCTUnwrap(store.createStandaloneProfile())

        store.setProfileActive(profileID, true)
        await store.switchTask?.value

        XCTAssertFalse(store.isActive(profileID))
        guard case .failed = store.switchFeedback else {
            return XCTFail("应报告失败反馈，实际：\(String(describing: store.switchFeedback))")
        }
        XCTAssertEqual(try reloadModel().activeProfileIDs, [])
    }

    @MainActor
    func testChannelFailureNeedingApprovalGuidesReapproval() async throws {
        let stub = SwitchCoordinatingStub()
        stub.switchOutcome = .success(.channelFailed(.unavailable, statusAfterError: .requiresApproval))
        let store = makeStore(coordinator: stub)
        let profileID = try XCTUnwrap(store.createStandaloneProfile())

        store.setProfileActive(profileID, true)
        await store.switchTask?.value

        XCTAssertFalse(store.isActive(profileID))
        XCTAssertEqual(store.switchFeedback, .needsApproval)
    }

    @MainActor
    func testDeleteActiveProfileGoesThroughSwitchAndPersists() async throws {
        let stub = SwitchCoordinatingStub()
        let store = makeStore(coordinator: stub)
        let profileID = try XCTUnwrap(store.createStandaloneProfile())
        store.updateProfileContent(profileID, content: "1.2.3.4 dev.local\n")
        store.setProfileActive(profileID, true)
        await store.switchTask?.value

        store.deleteProfile(profileID)
        await store.switchTask?.value

        XCTAssertEqual(store.standaloneProfiles, [])
        XCTAssertEqual(store.switchFeedback, .merged)
        // Deletion is an active-state change: the merged content sent to the daemon no longer contains the profile
        XCTAssertFalse(try XCTUnwrap(stub.performedSwitches.last).content.contains("1.2.3.4 dev.local"))
        let reloaded = try reloadModel()
        XCTAssertEqual(reloaded.standaloneProfiles, [])
        XCTAssertEqual(reloaded.baseHosts.content, Self.importedHosts)
    }

    @MainActor
    func testDeleteActiveProfileKeptWhenBlocked() async throws {
        let stub = SwitchCoordinatingStub()
        let store = makeStore(coordinator: stub)
        let profileID = try XCTUnwrap(store.createStandaloneProfile())
        store.setProfileActive(profileID, true)
        await store.switchTask?.value

        stub.switchOutcome = .success(.blocked(.needsApproval))
        store.deleteProfile(profileID)
        await store.switchTask?.value

        XCTAssertEqual(store.standaloneProfiles.map(\.id), [profileID])
        XCTAssertTrue(store.isActive(profileID))
        XCTAssertEqual(store.switchFeedback, .needsApproval)
        XCTAssertEqual(try reloadModel().activeProfileIDs, [profileID])
    }

    @MainActor
    func testEditsLandedDuringSwitchSurviveCommit() async throws {
        let stub = SwitchCoordinatingStub()
        let store = makeStore(coordinator: stub)
        let profileID = try XCTUnwrap(store.createStandaloneProfile())
        store.updateProfileContent(profileID, content: "1.2.3.4 dev.local\n")

        stub.whileSwitchInFlight = {
            store.updateProfileContent(profileID, content: "5.6.7.8 edited.local\n")
        }
        store.setProfileActive(profileID, true)
        await store.switchTask?.value

        // The switch commit replays on the latest model and does not roll back in-flight edits
        XCTAssertTrue(store.isActive(profileID))
        XCTAssertEqual(store.profile(profileID)?.content, "5.6.7.8 edited.local\n")
        let reloaded = try reloadModel()
        XCTAssertEqual(reloaded.standaloneProfiles.first?.content, "5.6.7.8 edited.local\n")
        XCTAssertEqual(reloaded.activeProfileIDs, [profileID])
    }

    @MainActor
    func testActivationReportsFailureWhenCoordinatorThrows() async throws {
        let stub = SwitchCoordinatingStub()
        stub.switchOutcome = .failure(StubError())
        let store = makeStore(coordinator: stub)
        let profileID = try XCTUnwrap(store.createStandaloneProfile())

        store.setProfileActive(profileID, true)
        await store.switchTask?.value

        XCTAssertFalse(store.isActive(profileID))
        guard case .failed = store.switchFeedback else {
            return XCTFail("应报告失败反馈，实际：\(String(describing: store.switchFeedback))")
        }
    }

    // MARK: - Helpers

    @MainActor
    private func makeStore(coordinator: some SwitchCoordinating) -> WorkspaceStore {
        makeStore(coordinator: coordinator, driftMonitor: nil)
    }

    @MainActor
    private func makeStore(
        coordinator: some SwitchCoordinating,
        driftMonitor: (any HostsDriftMonitoring)?,
        systemHosts: Data = Data(WorkspaceStoreTests.importedHosts.utf8)
    ) -> WorkspaceStore {
        let store = WorkspaceStore(
            workspace: Workspace(rootDirectory: rootDirectory),
            coordinator: coordinator,
            driftMonitor: driftMonitor,
            readSystemHosts: { systemHosts }
        )
        store.loadIfNeeded()
        return store
    }

    /// Reloads with a fresh Workspace instance to verify persisted state; at this point the system hosts must never be imported again.
    private func reloadModel() throws -> ActivationModel {
        try Workspace(rootDirectory: rootDirectory).open(systemHosts: {
            XCTFail("已初始化的工作区不应再导入系统 hosts")
            return ""
        })
    }
}
