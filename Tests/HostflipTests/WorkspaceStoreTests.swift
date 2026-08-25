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
    private let lock = NSLock()
    private var recheckCount = 0

    func start(onChange: @escaping @MainActor @Sendable (Bool) -> Void) {
        self.onChange = onChange
    }

    func recheck() {
        lock.withLock { recheckCount += 1 }
    }

    var recordedRechecks: Int {
        lock.withLock { recheckCount }
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

/// Mutable canned fetch results keyed by Source URL: tests flip the remote content between
/// calls, and can attach a one-shot side effect that runs before a fetch returns (simulating
/// concurrent writers racing an in-flight refresh).
private final class RemoteContentStub: @unchecked Sendable {
    private let lock = NSLock()
    private var results: [URL: Result<String, any Error>] = [:]
    private var beforeFetch: (@Sendable () throws -> Void)?

    func set(_ url: URL, _ result: Result<String, any Error>) {
        lock.withLock { results[url] = result }
    }

    func setBeforeFetch(_ effect: @escaping @Sendable () throws -> Void) {
        lock.withLock { beforeFetch = effect }
    }

    func fetch(_ url: URL) throws -> String {
        let (effect, result) = lock.withLock { (beforeFetch, results[url]) }
        try effect?()
        guard let result else { throw StubError() }
        return try result.get()
    }
}

/// Mutable canned conditional-fetch outcomes keyed by Source URL, recording the validators
/// each fetch sent; @unchecked because access is locked.
private final class RemoteOutcomeStub: @unchecked Sendable {
    private let lock = NSLock()
    private var results: [URL: Result<RemoteFetchOutcome, any Error>] = [:]
    private var received: [RemoteContentValidators?] = []
    private var beforeFetch: (@Sendable () throws -> Void)?

    var sentValidators: [RemoteContentValidators?] {
        lock.withLock { received }
    }

    func set(_ url: URL, _ result: Result<RemoteFetchOutcome, any Error>) {
        lock.withLock { results[url] = result }
    }

    /// One-shot side effect run before the next fetch returns, simulating a concurrent
    /// writer racing an in-flight refresh.
    func setBeforeFetch(_ effect: @escaping @Sendable () throws -> Void) {
        lock.withLock { beforeFetch = effect }
    }

    func fetch(_ url: URL, sending validators: RemoteContentValidators?) throws -> RemoteFetchOutcome {
        let (effect, result) = lock.withLock { () -> (
            (@Sendable () throws -> Void)?, Result<RemoteFetchOutcome, any Error>?
        ) in
            received.append(validators)
            defer { beforeFetch = nil }
            return (beforeFetch, results[url])
        }
        try effect?()
        guard let result else { throw StubError() }
        return try result.get()
    }
}

/// Mutable date for tests that must observe a refresh advancing the success time;
/// @unchecked because access is locked.
private final class MutableClock: @unchecked Sendable {
    private let lock = NSLock()
    private var date: Date

    init(_ date: Date) {
        self.date = date
    }

    var now: Date {
        lock.withLock { date }
    }

    func advance(by interval: TimeInterval) {
        lock.withLock { date = date.addingTimeInterval(interval) }
    }
}

final class WorkspaceStoreTests: XCTestCase {
    private static let importedHosts = "127.0.0.1 localhost\n"
    /// The injected refresh clock: a whole second, matching the manifest's ISO8601 precision.
    private static let refreshClock = Date(timeIntervalSince1970: 1_755_000_000)
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
    func testCreateProfileInGroupLandsInGroupAndPersists() throws {
        let store = makeStore(coordinator: SwitchCoordinatingStub())
        let groupID = try XCTUnwrap(store.createGroup())

        let profileID = try XCTUnwrap(store.createProfile(in: groupID))

        XCTAssertEqual(store.standaloneProfiles, [])
        XCTAssertEqual(store.groups.first?.profiles.map(\.id), [profileID])
        XCTAssertFalse(store.isActive(profileID))

        let reloaded = try reloadModel()
        XCTAssertEqual(reloaded.groups.first?.profiles.map(\.id), [profileID])
    }

    @MainActor
    func testCreateStandaloneProfileAvoidsDuplicateDefaultNames() throws {
        let store = makeStore(coordinator: SwitchCoordinatingStub())

        store.createStandaloneProfile()
        store.createStandaloneProfile()

        XCTAssertEqual(store.standaloneProfiles.map(\.name), ["New Profile", "New Profile 2"])
    }

    @MainActor
    func testDuplicateProfilePlacesAnInactiveCopyRightAfterTheOriginalAndPersists() async throws {
        let coordinator = SwitchCoordinatingStub()
        let store = makeStore(coordinator: coordinator)
        let originalID = try XCTUnwrap(store.createStandaloneProfile())
        let trailingID = try XCTUnwrap(store.createStandaloneProfile())
        store.renameProfile(originalID, to: "staging")
        store.updateProfileContent(originalID, content: "1.2.3.4 staging.example.com\n")
        store.setProfileActive(originalID, true)
        await store.switchTask?.value
        let switchesBefore = coordinator.performedSwitches.count

        let copyID = try XCTUnwrap(store.duplicateProfile(originalID))

        XCTAssertEqual(store.standaloneProfiles.map(\.id), [originalID, copyID, trailingID])
        let copy = try XCTUnwrap(store.profile(copyID))
        XCTAssertEqual(copy.name, "staging Copy")
        XCTAssertEqual(copy.content, "1.2.3.4 staging.example.com\n")
        XCTAssertFalse(store.isActive(copyID))
        XCTAssertTrue(store.isActive(originalID))
        // The copy is inactive, so no switch is performed.
        XCTAssertEqual(coordinator.performedSwitches.count, switchesBefore)

        let reloaded = try reloadModel()
        XCTAssertEqual(reloaded.standaloneProfiles.map(\.id), [originalID, copyID, trailingID])
        XCTAssertEqual(reloaded.profile(copyID), copy)
        XCTAssertEqual(reloaded.activeProfileIDs, [originalID])
    }

    @MainActor
    func testDuplicateProfileInGroupStaysInTheGroupAfterTheOriginal() async throws {
        let store = makeStore(coordinator: SwitchCoordinatingStub())
        let groupID = try XCTUnwrap(store.createGroup())
        let originalID = try XCTUnwrap(store.createProfile(in: groupID))
        let trailingID = try XCTUnwrap(store.createProfile(in: groupID))
        store.setProfileActive(originalID, true)
        await store.switchTask?.value

        let copyID = try XCTUnwrap(store.duplicateProfile(originalID))

        XCTAssertEqual(store.standaloneProfiles, [])
        XCTAssertEqual(store.groups.first?.profiles.map(\.id), [originalID, copyID, trailingID])
        XCTAssertTrue(store.isActive(originalID))
        XCTAssertFalse(store.isActive(copyID))
        XCTAssertEqual(try reloadModel().groups.first?.profiles.map(\.id), [originalID, copyID, trailingID])
    }

    @MainActor
    func testDuplicatingTwiceStacksTheNewestCopyRightAfterTheOriginal() throws {
        let store = makeStore(coordinator: SwitchCoordinatingStub())
        let originalID = try XCTUnwrap(store.createStandaloneProfile())

        let firstCopyID = try XCTUnwrap(store.duplicateProfile(originalID))
        let secondCopyID = try XCTUnwrap(store.duplicateProfile(originalID))

        XCTAssertEqual(store.standaloneProfiles.map(\.id), [originalID, secondCopyID, firstCopyID])
        // Names are not de-duplicated, matching the rename semantics.
        XCTAssertEqual(store.standaloneProfiles.map(\.name), ["New Profile", "New Profile Copy", "New Profile Copy"])
    }

    @MainActor
    func testDuplicateRemoteProfileKeepsTheHeaderWithoutRefreshHistory() async throws {
        let store = makeStore(coordinator: SwitchCoordinatingStub(), fetchRemoteContent: { _ in
            "9.9.9.9 fetched.example.com\n"
        })
        let originalID = try XCTUnwrap(store.createStandaloneProfile())
        store.updateProfileContent(
            originalID,
            content: "#!hostflip-remote https://example.com/hosts.txt interval=6h\n"
        )
        _ = await store.confirmRemoteConversion()
        let original = try XCTUnwrap(store.profile(originalID))
        XCTAssertNotNil(original.remoteRefreshState)

        let copyID = try XCTUnwrap(store.duplicateProfile(originalID))

        let copy = try XCTUnwrap(store.profile(copyID))
        XCTAssertTrue(copy.isRemote)
        XCTAssertEqual(copy.remoteHeader, original.remoteHeader)
        XCTAssertEqual(copy.content, original.content)
        XCTAssertNil(copy.remoteRefreshState)
        XCTAssertNil(try reloadModel().profile(copyID)?.remoteRefreshState)
    }

    @MainActor
    func testDuplicateOfAForeignlyDeletedProfileIsDroppedAndReturnsNil() throws {
        let store = makeStore(coordinator: SwitchCoordinatingStub())
        let profileID = try XCTUnwrap(store.createStandaloneProfile())
        foreignlyModifyWorkspace { try $0.deleteProfile(profileID) }

        XCTAssertNil(store.duplicateProfile(profileID))

        XCTAssertEqual(store.standaloneProfiles, [])
        XCTAssertNil(store.saveError)
    }

    @MainActor
    func testDuplicateNamesTheCopyAfterAForeignRename() throws {
        let store = makeStore(coordinator: SwitchCoordinatingStub())
        let profileID = try XCTUnwrap(store.createStandaloneProfile())
        foreignlyModifyWorkspace { try $0.renameProfile(profileID, to: "renamed") }

        let copyID = try XCTUnwrap(store.duplicateProfile(profileID))

        XCTAssertEqual(store.profile(copyID)?.name, "renamed Copy")
    }

    @MainActor
    func testDuplicateUnknownProfileIsIgnored() throws {
        let store = makeStore(coordinator: SwitchCoordinatingStub())
        let profileID = try XCTUnwrap(store.createStandaloneProfile())

        XCTAssertNil(store.duplicateProfile(Profile.ID("missing")))

        XCTAssertEqual(store.standaloneProfiles.map(\.id), [profileID])
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

    /// #82: before the first confirmed write, the drift review diffs against hosts.orig —
    /// the same baseline as the verdict — not against the capture-stripped merged output.
    @MainActor
    func testPreFirstWriteDriftDiffsAgainstTheFullCaptureBackup() async throws {
        let captured = "127.0.0.1 localhost\n\n# --- SWITCHHOSTS_CONTENT_START ---\n\n10.0.0.1 api.example.com\n"
        try FileManager.default.removeItem(at: rootDirectory)
        _ = try Workspace(rootDirectory: rootDirectory).open(systemHosts: { captured })
        let systemHosts = SystemHostsDataSource(Data(captured.utf8))
        let monitor = HostsDriftMonitoringStub()
        let store = WorkspaceStore(
            workspace: Workspace(rootDirectory: rootDirectory),
            coordinator: SwitchCoordinatingStub(),
            driftMonitor: monitor,
            readSystemHosts: systemHosts.read,
            fetchRemote: { _, _ in throw StubError() },
            now: { Self.refreshClock }
        )
        store.loadIfNeeded()
        XCTAssertEqual(store.baseHostsContent, "127.0.0.1 localhost\n")

        systemHosts.replace(with: Data((captured + "1.2.3.4 external.local\n").utf8))
        monitor.report(true)

        let comparison = try XCTUnwrap(store.hostsDriftComparison)
        XCTAssertEqual(comparison.driftAdditions, ["1.2.3.4 external.local"])

        store.reconcileHosts(.addDriftLinesToBaseHosts)
        await store.reconciliationTask?.value
        XCTAssertEqual(
            store.baseHostsContent,
            "127.0.0.1 localhost\n1.2.3.4 external.local\n"
        )
    }

    /// #82: an unreadable pre-write baseline yields no comparison at all — falling back to
    /// the merged output would show the capture-stripped block as additions again.
    @MainActor
    func testAnUnreadableCaptureBackupFailsClosedWithNoComparison() throws {
        let monitor = HostsDriftMonitoringStub()
        let store = makeStore(coordinator: SwitchCoordinatingStub(), driftMonitor: monitor)
        try FileManager.default.removeItem(at: rootDirectory.appendingPathComponent("hosts.orig"))

        monitor.report(true)

        XCTAssertTrue(store.hasHostsDrift)
        XCTAssertNil(store.hostsDriftComparison)
    }

    /// #82: once a write is confirmed the expected side is the merged output, exactly as before.
    @MainActor
    func testPostWriteDriftStillDiffsAgainstTheMergedOutput() async throws {
        let systemHosts = SystemHostsDataSource(Data(Self.importedHosts.utf8))
        let monitor = HostsDriftMonitoringStub()
        let coordinator = SwitchCoordinatingStub()
        let store = WorkspaceStore(
            workspace: Workspace(rootDirectory: rootDirectory),
            coordinator: coordinator,
            driftMonitor: monitor,
            readSystemHosts: systemHosts.read,
            fetchRemote: { _, _ in throw StubError() },
            now: { Self.refreshClock }
        )
        store.loadIfNeeded()
        let profileID = try XCTUnwrap(store.createStandaloneProfile())
        store.updateProfileContent(profileID, content: "10.0.0.5 dev.local\n")
        store.setProfileActive(profileID, true)
        await store.switchTask?.value
        // The coordinator stub bypasses the real MergeCoordinator, which records the
        // written hash after the daemon confirms; record it here as production would.
        try Workspace(rootDirectory: rootDirectory).recordLastWrittenHash("stub")

        systemHosts.replace(with: Data("127.0.0.1 localhost\n9.9.9.9 rogue.local\n".utf8))
        monitor.report(true)

        let comparison = try XCTUnwrap(store.hostsDriftComparison)
        // Expected side is the merged output: the active profile's line reads as removed
        // from the actual file, the rogue line as added.
        XCTAssertEqual(comparison.driftAdditions, ["9.9.9.9 rogue.local"])
        XCTAssertTrue(comparison.readableDiff.contains("- 10.0.0.5 dev.local"))
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
            return XCTFail("a DNS flush failure must keep the failure feedback")
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
            return XCTFail("a workspace save failure must keep the failure feedback")
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
            return XCTFail("expected failure feedback, got: \(String(describing: store.switchFeedback))")
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
    func testHelperBecomingEnabledRetiresApprovalFeedback() async throws {
        let stub = SwitchCoordinatingStub()
        stub.switchOutcome = .success(.blocked(.needsApproval))
        let store = makeStore(coordinator: stub)
        let profileID = try XCTUnwrap(store.createStandaloneProfile())
        store.setProfileActive(profileID, true)
        await store.switchTask?.value
        XCTAssertEqual(store.switchFeedback, .needsApproval)

        store.helperStatusDidChange(.requiresApproval)
        XCTAssertEqual(store.switchFeedback, .needsApproval)

        store.helperStatusDidChange(.enabled)
        XCTAssertNil(store.switchFeedback)
    }

    @MainActor
    func testHelperBecomingEnabledRetiresUnavailableFeedback() async throws {
        let stub = SwitchCoordinatingStub()
        stub.switchOutcome = .success(.blocked(.unavailable))
        let store = makeStore(coordinator: stub)
        let profileID = try XCTUnwrap(store.createStandaloneProfile())
        store.setProfileActive(profileID, true)
        await store.switchTask?.value
        XCTAssertEqual(store.switchFeedback, .unavailable)

        store.helperStatusDidChange(.enabled)
        XCTAssertNil(store.switchFeedback)
    }

    @MainActor
    func testHelperStatusNeverRetiresOtherFeedback() async throws {
        let stub = SwitchCoordinatingStub()
        stub.switchOutcome = .failure(StubError())
        let store = makeStore(coordinator: stub)
        let profileID = try XCTUnwrap(store.createStandaloneProfile())
        store.setProfileActive(profileID, true)
        await store.switchTask?.value
        guard case .failed = store.switchFeedback else {
            return XCTFail("expected failure feedback, got: \(String(describing: store.switchFeedback))")
        }

        for status in [DaemonRegistrationStatus.enabled, .notRegistered, .notFound, .requiresApproval] {
            store.helperStatusDidChange(status)
        }
        guard case .failed = store.switchFeedback else {
            return XCTFail("failure feedback must survive helper status changes")
        }
    }

    @MainActor
    func testApprovalFeedbackHoldsOnlyWhileApprovalIsStillRequired() async throws {
        for status in [DaemonRegistrationStatus.enabled, .notRegistered, .notFound] {
            let stub = SwitchCoordinatingStub()
            stub.switchOutcome = .success(.blocked(.needsApproval))
            let store = makeStore(coordinator: stub)
            let profileID = try XCTUnwrap(store.createStandaloneProfile())
            store.setProfileActive(profileID, true)
            await store.switchTask?.value

            store.helperStatusDidChange(.requiresApproval)
            XCTAssertEqual(store.switchFeedback, .needsApproval)
            // Helper removed after the verdict: guiding the user to approve it would be nonsense.
            store.helperStatusDidChange(status)
            XCTAssertNil(store.switchFeedback, "status: \(status)")
        }
    }

    @MainActor
    func testUnavailableFeedbackHoldsUntilTheHelperIsEnabled() async throws {
        let stub = SwitchCoordinatingStub()
        stub.switchOutcome = .success(.blocked(.unavailable))
        let store = makeStore(coordinator: stub)
        let profileID = try XCTUnwrap(store.createStandaloneProfile())
        store.setProfileActive(profileID, true)
        await store.switchTask?.value

        for status in [DaemonRegistrationStatus.notFound, .notRegistered, .requiresApproval] {
            store.helperStatusDidChange(status)
            XCTAssertEqual(store.switchFeedback, .unavailable, "status: \(status)")
        }
    }

    @MainActor
    func testRepeatedEnabledStatusRetiresApprovalFeedbackFromAnUnobservedRevocation() async throws {
        let stub = SwitchCoordinatingStub()
        let store = makeStore(coordinator: stub)
        let profileID = try XCTUnwrap(store.createStandaloneProfile())
        store.helperStatusDidChange(.enabled)

        // Approval revoked and the switch made from the menu bar with the window closed: no
        // status read ever sees requiresApproval.
        stub.switchOutcome = .success(.blocked(.needsApproval))
        store.setProfileActive(profileID, true)
        await store.switchTask?.value
        XCTAssertEqual(store.switchFeedback, .needsApproval)

        // Re-approved, window opened: the first read is .enabled again and must still retire.
        store.helperStatusDidChange(.enabled)
        XCTAssertNil(store.switchFeedback)
    }

    @MainActor
    func testHelperBecomingEnabledRetiresMatchingReconciliationError() async throws {
        let coordinator = SwitchCoordinatingStub()
        coordinator.switchOutcome = .success(.blocked(.needsApproval))
        let monitor = HostsDriftMonitoringStub()
        let store = makeStore(coordinator: coordinator, driftMonitor: monitor)
        monitor.report(true)

        store.reconcileHosts(.addDriftLinesToBaseHosts)
        await store.reconciliationTask?.value
        XCTAssertEqual(store.switchFeedback, .needsApproval)
        XCTAssertEqual(store.reconciliationError, SwitchFeedback.needsApproval.message)

        store.helperStatusDidChange(.enabled)
        XCTAssertNil(store.switchFeedback)
        XCTAssertNil(store.reconciliationError)
        XCTAssertTrue(store.hasHostsDrift, "retiring the helper verdict must not pretend the drift was reconciled")
    }

    @MainActor
    func testHelperBecomingEnabledKeepsAnUnrelatedReconciliationError() async throws {
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
        let flushError = try XCTUnwrap(store.reconciliationError)
        XCTAssertFalse(store.hasHostsDrift)

        // A later switch is blocked on approval; retiring that verdict must not erase the flush error.
        coordinator.switchOutcome = .success(.blocked(.needsApproval))
        let profileID = try XCTUnwrap(store.createStandaloneProfile())
        store.setProfileActive(profileID, true)
        await store.switchTask?.value
        XCTAssertEqual(store.switchFeedback, .needsApproval)

        store.helperStatusDidChange(.enabled)
        XCTAssertNil(store.switchFeedback)
        XCTAssertEqual(store.reconciliationError, flushError)
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
            return XCTFail("expected failure feedback, got: \(String(describing: store.switchFeedback))")
        }
    }

    // MARK: - Import / Export (#40)

    @MainActor
    func testImportAppendsFilesAsInactiveContentWithoutMerging() throws {
        let stub = SwitchCoordinatingStub()
        let store = makeStore(coordinator: stub)
        let snapshot = ExportSnapshot(
            standaloneProfiles: [.init(name: "Ad Block", content: "0.0.0.0 ads.example\n")],
            groups: [.init(name: "Staging", profiles: [
                .init(name: "API", content: "10.0.0.1 api.example\n")
            ])]
        )
        let urls = [
            try writeImportFile(named: "team.json", snapshot.encoded()),
            try writeImportFile(named: "Team DB.hosts", Data("10.0.0.3 db.example\n".utf8)),
        ]

        let outcome = store.importFiles(at: urls)

        XCTAssertEqual(outcome, .imported(ImportSummary(profileCount: 3, remoteSourceURLs: [])))
        XCTAssertEqual(store.standaloneProfiles.map(\.name), ["Ad Block", "Team DB"])
        XCTAssertEqual(store.groups.map(\.name), ["Staging"])
        XCTAssertEqual(store.groups.first?.profiles.map(\.name), ["API"])
        XCTAssertEqual(store.model?.activeProfileIDs, [])

        // Local-only: no follow-up merge is scheduled and nothing reaches the coordinator.
        XCTAssertNil(store.followUpMergeTask)
        XCTAssertTrue(stub.authorizedMerges.isEmpty)
        XCTAssertTrue(stub.performedSwitches.isEmpty)

        let reloaded = try reloadModel()
        XCTAssertEqual(reloaded.standaloneProfiles.map(\.name), ["Ad Block", "Team DB"])
        XCTAssertEqual(reloaded.groups.map(\.name), ["Staging"])
        XCTAssertEqual(reloaded.activeProfileIDs, [])
    }

    @MainActor
    func testImportOfSameNamedProfilesKeepsBothWithoutMerging() throws {
        let store = makeStore(coordinator: SwitchCoordinatingStub())
        _ = store.createStandaloneProfile()
        let snapshot = ExportSnapshot(
            standaloneProfiles: [.init(name: "New Profile", content: "0.0.0.0 ads.example\n")],
            groups: []
        )

        let outcome = store.importFiles(at: [
            try writeImportFile(named: "dup.json", snapshot.encoded())
        ])

        XCTAssertEqual(outcome, .imported(ImportSummary(profileCount: 1, remoteSourceURLs: [])))
        XCTAssertEqual(store.standaloneProfiles.map(\.name), ["New Profile", "New Profile"])
        let reloaded = try reloadModel()
        XCTAssertEqual(reloaded.standaloneProfiles.map(\.name), ["New Profile", "New Profile"])
        XCTAssertEqual(reloaded.standaloneProfiles.map(\.content).sorted(), [
            "# Add hosts entries here\n", "0.0.0.0 ads.example\n",
        ])
    }

    @MainActor
    func testImportRebuildsARemoteProfileInactiveAndSummarizesItsSourceURL() throws {
        let stub = SwitchCoordinatingStub()
        let store = makeStore(coordinator: stub)
        let content = "#!hostflip-remote https://hosts.example/list.txt interval=6h\n0.0.0.0 tracker.example\n"
        let url = try writeImportFile(named: "team.json", ExportSnapshot(
            standaloneProfiles: [.init(name: "Blocklist", content: content)],
            groups: []
        ).encoded())

        let outcome = store.importFiles(at: [url])

        XCTAssertEqual(outcome, .imported(ImportSummary(
            profileCount: 1,
            remoteSourceURLs: ["https://hosts.example/list.txt"]
        )))
        let imported = try XCTUnwrap(store.standaloneProfiles.first)
        XCTAssertTrue(imported.isRemote)
        XCTAssertEqual(imported.remoteHeader?.interval, .sixHours)
        XCTAssertEqual(store.model?.activeProfileIDs, [])
        // Offline and purely local: nothing reaches the coordinator, no follow-up merge.
        XCTAssertNil(store.followUpMergeTask)
        XCTAssertTrue(stub.authorizedMerges.isEmpty)
        XCTAssertTrue(stub.performedSwitches.isEmpty)
        // The rebuilt remote identity survives the workspace save/reload.
        XCTAssertTrue(try XCTUnwrap(reloadModel().standaloneProfiles.first).isRemote)
    }

    @MainActor
    func testImportAppliesNothingWhenAnyFileIsInvalid() throws {
        let store = makeStore(coordinator: SwitchCoordinatingStub())
        let valid = ExportSnapshot(
            standaloneProfiles: [.init(name: "Ad Block", content: "0.0.0.0 ads.example\n")],
            groups: []
        )
        let urls = [
            try writeImportFile(named: "good.json", valid.encoded()),
            try writeImportFile(named: "bad.json", Data(#"{"nope": 1}"#.utf8)),
        ]

        let outcome = store.importFiles(at: urls)

        guard case .failed(let message) = outcome else {
            return XCTFail("the import must fail as a whole, got: \(outcome)")
        }
        XCTAssertTrue(message.contains("bad.json"), message)
        XCTAssertTrue(store.standaloneProfiles.isEmpty)
        XCTAssertTrue(try reloadModel().standaloneProfiles.isEmpty)
    }

    @MainActor
    func testImportCommitsNothingInMemoryWhenSaveFails() throws {
        let store = makeStore(coordinator: SwitchCoordinatingStub())
        let url = try writeImportFile(named: "team.json", ExportSnapshot(
            standaloneProfiles: [.init(name: "Ad Block", content: "0.0.0.0 ads.example\n")],
            groups: []
        ).encoded())
        // Removing hosts.orig makes Workspace.save throw notInitialized after parsing succeeds.
        try FileManager.default.removeItem(at: rootDirectory.appendingPathComponent("hosts.orig"))

        let outcome = store.importFiles(at: [url])

        guard case .failed = outcome else {
            return XCTFail("the import must fail when saving fails, got: \(outcome)")
        }
        XCTAssertTrue(store.standaloneProfiles.isEmpty)
        XCTAssertNil(store.followUpMergeTask)
    }

    // MARK: - SwitchHosts import (#74)

    @MainActor
    func testSwitchHostsImportAppendsMappedContentInactiveWithoutMerging() throws {
        let stub = SwitchCoordinatingStub()
        let store = makeStore(coordinator: stub)
        let directory = try writeSwitchHostsV4Directory(
            tree: #"""
            [
             {"title": "dev", "id": "aaaa", "on": false},
             {"type": "remote", "title": "Blocklist", "id": "rrrr",
              "url": "https://rules.example/list.hosts", "refresh_interval": 86400, "on": false}
            ]
            """#,
            records: [
                "1": #"{"id": "aaaa", "content": "127.0.0.1 dev.example\n", "_id": "1"}"#,
                "2": #"{"id": "rrrr", "content": "0.0.0.0 tracker.example\n", "_id": "2"}"#,
            ]
        )

        let outcome = store.importSwitchHosts(at: directory)

        XCTAssertEqual(outcome, .imported(SwitchHostsImportSummary(
            profileCount: 2,
            remoteProfiles: [.init(
                profileName: "Blocklist",
                sourceURL: "https://rules.example/list.hosts",
                interval: .twentyFourHours
            )],
            detectedFormat: .v4
        )))
        XCTAssertEqual(store.standaloneProfiles.map(\.name), ["dev", "Blocklist"])
        XCTAssertTrue(try XCTUnwrap(store.standaloneProfiles.last).isRemote)
        XCTAssertEqual(store.model?.activeProfileIDs, [])
        // Offline and purely local: nothing reaches the coordinator, no follow-up merge.
        XCTAssertNil(store.followUpMergeTask)
        XCTAssertTrue(stub.authorizedMerges.isEmpty)
        XCTAssertTrue(stub.performedSwitches.isEmpty)
        XCTAssertEqual(try reloadModel().standaloneProfiles.map(\.name), ["dev", "Blocklist"])
    }

    @MainActor
    func testSwitchHostsImportAppliesNothingWhenTheDataIsMalformed() throws {
        let store = makeStore(coordinator: SwitchCoordinatingStub())
        let directory = try writeSwitchHostsV4Directory(
            tree: #"[{"title": "dev", "id": "aaaa"}]"#,
            records: ["1": "not json"]
        )

        let outcome = store.importSwitchHosts(at: directory)

        guard case .failed(let message) = outcome else {
            return XCTFail("the import must fail as a whole, got: \(outcome)")
        }
        XCTAssertTrue(message.contains("data/collection/hosts/data/1.json"), message)
        XCTAssertTrue(store.standaloneProfiles.isEmpty)
        XCTAssertTrue(try reloadModel().standaloneProfiles.isEmpty)
    }

    @MainActor
    func testSwitchHostsImportReportsAMissingDataDirectory() throws {
        let store = makeStore(coordinator: SwitchCoordinatingStub())

        let outcome = store.importSwitchHosts(
            at: rootDirectory.appendingPathComponent("no-switchhosts", isDirectory: true)
        )

        guard case .failed(let message) = outcome else {
            return XCTFail("the import must fail, got: \(outcome)")
        }
        XCTAssertTrue(message.contains("that folder"), message)
        XCTAssertTrue(store.standaloneProfiles.isEmpty)
    }

    /// A minimal v4 PotDb directory; record keys are the collection `_id`s listed in ids.json.
    private func writeSwitchHostsV4Directory(
        tree: String,
        records: [String: String]
    ) throws -> URL {
        let root = rootDirectory.appendingPathComponent("switchhosts-v4", isDirectory: true)
        let listDirectory = root.appendingPathComponent("data/list", isDirectory: true)
        let dataDirectory = root.appendingPathComponent("data/collection/hosts/data", isDirectory: true)
        try FileManager.default.createDirectory(at: listDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dataDirectory, withIntermediateDirectories: true)
        try Data(tree.utf8).write(to: listDirectory.appendingPathComponent("tree.json"))
        let ids = records.keys.sorted().map { "\"\($0)\"" }.joined(separator: ", ")
        try Data("[\(ids)]".utf8).write(
            to: dataDirectory.deletingLastPathComponent().appendingPathComponent("ids.json")
        )
        for (recordID, json) in records {
            try Data(json.utf8).write(to: dataDirectory.appendingPathComponent("\(recordID).json"))
        }
        return root
    }

    @MainActor
    func testExportedDataRoundTripsAsASnapshotOfCurrentProfiles() throws {
        let store = makeStore(coordinator: SwitchCoordinatingStub())
        _ = store.createStandaloneProfile()

        let data = try XCTUnwrap(store.exportSnapshotData())

        let read = try ImportReader.read(data: data, fileName: "export.json")
        XCTAssertEqual(read, .snapshot(ExportSnapshot(
            standaloneProfiles: [.init(name: "New Profile", content: "# Add hosts entries here\n")],
            groups: []
        )))
    }

    private func writeImportFile(named name: String, _ data: Data) throws -> URL {
        let directory = rootDirectory.appendingPathComponent("import-files", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    // MARK: - External-writer coexistence (#53, ADR-0010 ②③)

    @MainActor
    func testEditReplaysOnAForeignlyModifiedWorkspace() throws {
        let store = makeStore(coordinator: SwitchCoordinatingStub())
        foreignlyModifyWorkspace {
            try $0.addProfile(id: .init("cli"), name: "CLI", content: "# cli\n")
            try $0.toggleProfile(.init("cli"))
        }

        let profileID = try XCTUnwrap(store.createStandaloneProfile())

        XCTAssertEqual(store.standaloneProfiles.map(\.id), [.init("cli"), profileID])
        XCTAssertEqual(store.model?.activeProfileIDs, [.init("cli")])
        XCTAssertNil(store.saveError)
        let reloaded = try reloadModel()
        XCTAssertEqual(reloaded.standaloneProfiles.map(\.id), [.init("cli"), profileID])
        XCTAssertEqual(reloaded.activeProfileIDs, [.init("cli")])
        // The foreign profile's file must survive the save's stale-file cleanup
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: rootDirectory.appendingPathComponent("profiles/CLI.hosts").path
        ))
    }

    @MainActor
    func testEditOnAForeignlyDeletedProfileIsDroppedAndAdoptsTheLatestState() throws {
        let store = makeStore(coordinator: SwitchCoordinatingStub())
        let profileID = try XCTUnwrap(store.createStandaloneProfile())
        foreignlyModifyWorkspace { try $0.deleteProfile(profileID) }

        store.renameProfile(profileID, to: "Renamed")

        XCTAssertEqual(store.standaloneProfiles, [])
        XCTAssertNil(store.saveError)
        XCTAssertEqual(try reloadModel().standaloneProfiles, [])
    }

    @MainActor
    func testSwitchCommitReplaysOnForeignChangesMadeWhileInFlight() async throws {
        let stub = SwitchCoordinatingStub()
        let store = makeStore(coordinator: stub)
        let profileID = try XCTUnwrap(store.createStandaloneProfile())
        stub.whileSwitchInFlight = { [self] in
            foreignlyModifyWorkspace {
                try $0.addProfile(id: .init("cli"), name: "CLI", content: "# cli\n")
            }
        }

        store.setProfileActive(profileID, true)
        await store.switchTask?.value

        XCTAssertEqual(store.switchFeedback, .merged)
        XCTAssertEqual(store.standaloneProfiles.map(\.id), [profileID, .init("cli")])
        XCTAssertTrue(store.isActive(profileID))
        let reloaded = try reloadModel()
        XCTAssertEqual(reloaded.standaloneProfiles.map(\.id), [profileID, .init("cli")])
        XCTAssertEqual(reloaded.activeProfileIDs, [profileID])
    }

    @MainActor
    func testSwitchCommitOnAForeignlyDeletedProfileDropsTheCommit() async throws {
        let stub = SwitchCoordinatingStub()
        let store = makeStore(coordinator: stub)
        let profileID = try XCTUnwrap(store.createStandaloneProfile())
        stub.whileSwitchInFlight = { [self] in
            foreignlyModifyWorkspace { try $0.deleteProfile(profileID) }
        }

        store.setProfileActive(profileID, true)
        await store.switchTask?.value

        XCTAssertEqual(store.standaloneProfiles, [])
        XCTAssertEqual(store.model?.activeProfileIDs, [])
        XCTAssertEqual(try reloadModel().standaloneProfiles, [])
        // The system hosts was already written with the dropped state; the follow-up merge converges it back
        XCTAssertNotNil(store.followUpMergeTask)
    }

    @MainActor
    func testReconciliationReplaysOnForeignChangesMadeWhileInFlight() async throws {
        let actualHosts = Self.importedHosts + "1.2.3.4 external.local\n"
        let coordinator = SwitchCoordinatingStub()
        let monitor = HostsDriftMonitoringStub()
        let store = makeStore(
            coordinator: coordinator,
            driftMonitor: monitor,
            systemHosts: Data(actualHosts.utf8)
        )
        monitor.report(true)
        coordinator.whileReconciliationInFlight = { [self] in
            foreignlyModifyWorkspace {
                try $0.addProfile(id: .init("cli"), name: "CLI", content: "# cli\n")
            }
        }

        store.reconcileHosts(.addDriftLinesToBaseHosts)
        await store.reconciliationTask?.value

        XCTAssertEqual(store.baseHostsContent, Self.importedHosts + "1.2.3.4 external.local\n")
        XCTAssertEqual(store.standaloneProfiles.map(\.id), [.init("cli")])
        let reloaded = try reloadModel()
        XCTAssertEqual(reloaded.baseHosts.content, store.baseHostsContent)
        XCTAssertEqual(reloaded.standaloneProfiles.map(\.id), [.init("cli")])
    }

    @MainActor
    func testImportReplaysOnAForeignlyModifiedWorkspace() throws {
        let store = makeStore(coordinator: SwitchCoordinatingStub())
        foreignlyModifyWorkspace {
            try $0.addProfile(id: .init("cli"), name: "CLI", content: "# cli\n")
        }

        let outcome = store.importFiles(at: [
            try writeImportFile(named: "Team DB.hosts", Data("10.0.0.3 db.example\n".utf8))
        ])

        XCTAssertEqual(outcome, .imported(ImportSummary(profileCount: 1, remoteSourceURLs: [])))
        XCTAssertEqual(store.standaloneProfiles.map(\.name), ["CLI", "Team DB"])
        XCTAssertEqual(try reloadModel().standaloneProfiles.map(\.name), ["CLI", "Team DB"])
    }

    @MainActor
    func testDegradedSaveSelfHealsUnsavedEditsOnceTheDiskRecovers() throws {
        let store = makeStore(coordinator: SwitchCoordinatingStub())
        let profileID = try XCTUnwrap(store.createStandaloneProfile())
        let manifestURL = rootDirectory.appendingPathComponent("manifest.json")
        let validManifest = try Data(contentsOf: manifestURL)
        try Data("invalid manifest".utf8).write(to: manifestURL, options: .atomic)

        store.renameProfile(profileID, to: "First Edit")
        XCTAssertNotNil(store.saveError)
        XCTAssertEqual(store.standaloneProfiles.map(\.name), ["First Edit"])

        try validManifest.write(to: manifestURL, options: .atomic)
        store.updateProfileContent(profileID, content: "# healed\n")

        XCTAssertNil(store.saveError)
        let reloaded = try reloadModel()
        XCTAssertEqual(reloaded.standaloneProfiles.map(\.name), ["First Edit"])
        XCTAssertEqual(reloaded.standaloneProfiles.map(\.content), ["# healed\n"])
    }

    @MainActor
    func testRefreshFromExternalChangeReloadsTheModelWithoutMerging() throws {
        let stub = SwitchCoordinatingStub()
        let store = makeStore(coordinator: stub)
        foreignlyModifyWorkspace {
            try $0.addProfile(id: .init("cli"), name: "CLI", content: "# cli\n")
        }

        store.refreshFromExternalChange()

        XCTAssertEqual(store.standaloneProfiles.map(\.id), [.init("cli")])
        // Display refresh only: nothing reaches the coordinator and no follow-up merge is scheduled
        XCTAssertNil(store.followUpMergeTask)
        XCTAssertTrue(stub.authorizedMerges.isEmpty)
        XCTAssertTrue(stub.performedSwitches.isEmpty)
    }

    @MainActor
    func testRefreshFromExternalChangeRechecksTheDriftMonitor() throws {
        let monitor = HostsDriftMonitoringStub()
        let store = makeStore(coordinator: SwitchCoordinatingStub(), driftMonitor: monitor)
        foreignlyModifyWorkspace {
            try $0.addProfile(id: .init("cli"), name: "CLI", content: "# cli\n")
        }

        store.refreshFromExternalChange()

        // The external writer's hosts file event can outrun its manifest record, leaving a stale
        // drift verdict; the change notification arrives after the record, so it re-checks.
        XCTAssertEqual(monitor.recordedRechecks, 1)
    }

    @MainActor
    func testRefreshFromExternalChangeSkipsWhileASaveErrorKeepsUnsavedEdits() throws {
        let store = makeStore(coordinator: SwitchCoordinatingStub())
        let profileID = try XCTUnwrap(store.createStandaloneProfile())
        let manifestURL = rootDirectory.appendingPathComponent("manifest.json")
        let validManifest = try Data(contentsOf: manifestURL)
        try Data("invalid manifest".utf8).write(to: manifestURL, options: .atomic)
        store.renameProfile(profileID, to: "Kept Edit")
        XCTAssertNotNil(store.saveError)
        try validManifest.write(to: manifestURL, options: .atomic)
        foreignlyModifyWorkspace {
            try $0.addProfile(id: .init("cli"), name: "CLI", content: "# cli\n")
        }

        store.refreshFromExternalChange()

        XCTAssertEqual(store.standaloneProfiles.map(\.name), ["Kept Edit"])
        XCTAssertNotNil(store.saveError)
    }

    @MainActor
    func testRefreshFromExternalChangeSkipsWhileASwitchIsInFlight() async throws {
        let stub = SwitchCoordinatingStub()
        let store = makeStore(coordinator: stub)
        let profileID = try XCTUnwrap(store.createStandaloneProfile())
        var refreshedDuringSwitch = true
        stub.whileSwitchInFlight = { [self] in
            foreignlyModifyWorkspace {
                try $0.addProfile(id: .init("cli"), name: "CLI", content: "# cli\n")
            }
            store.refreshFromExternalChange()
            refreshedDuringSwitch = store.standaloneProfiles.contains { $0.id == .init("cli") }
        }

        store.setProfileActive(profileID, true)
        await store.switchTask?.value

        XCTAssertFalse(refreshedDuringSwitch)
        // The commit's own reload-and-replay picks the foreign change up afterwards
        XCTAssertEqual(store.standaloneProfiles.map(\.id), [profileID, .init("cli")])
    }

    // MARK: - Creating remote profiles (ADR-0012)

    @MainActor
    func testCreateRemoteProfileFetchesValidatesAndPersistsInactive() async throws {
        let store = makeStore(coordinator: SwitchCoordinatingStub(), fetchRemoteContent: { url in
            XCTAssertEqual(url.absoluteString, "https://example.com/hosts.txt")
            return "1.2.3.4 a.example.com\n"
        })

        let outcome = await store.createRemoteProfile(
            sourceURL: URL(string: "https://example.com/hosts.txt")!,
            name: "GitHub Accelerator",
            interval: .sixHours
        )

        guard case .created(let profileID) = outcome else {
            return XCTFail("expected creation, got \(outcome)")
        }
        let profile = try XCTUnwrap(store.profile(profileID))
        XCTAssertEqual(profile.name, "GitHub Accelerator")
        XCTAssertEqual(
            profile.content,
            "#!hostflip-remote https://example.com/hosts.txt interval=6h\n1.2.3.4 a.example.com\n"
        )
        XCTAssertFalse(store.isActive(profileID))

        let reloaded = try reloadModel()
        XCTAssertEqual(reloaded.standaloneProfiles.map(\.id), [profileID])
        XCTAssertEqual(reloaded.activeProfileIDs, [])
    }

    @MainActor
    func testCreateRemoteProfileFailureLeavesNothingBehind() async throws {
        let store = makeStore(coordinator: SwitchCoordinatingStub(), fetchRemoteContent: { _ in
            throw RemoteFetchError.httpStatus(404)
        })

        let outcome = await store.createRemoteProfile(
            sourceURL: URL(string: "https://example.com/hosts.txt")!,
            name: "",
            interval: .twentyFourHours
        )

        XCTAssertEqual(outcome, .failed("The server responded with HTTP 404."))
        XCTAssertEqual(store.standaloneProfiles, [])
        XCTAssertEqual(try reloadModel().standaloneProfiles, [])
    }

    @MainActor
    func testCreateRemoteProfileRejectsANonHTTPSURLBeforeFetching() async {
        let store = makeStore(coordinator: SwitchCoordinatingStub(), fetchRemoteContent: { _ in
            XCTFail("a rejected URL must never be fetched")
            return ""
        })

        let outcome = await store.createRemoteProfile(
            sourceURL: URL(string: "http://example.com/hosts.txt")!,
            name: "",
            interval: .twentyFourHours
        )

        XCTAssertEqual(outcome, .failed("The Source URL must be an HTTPS address."))
        XCTAssertEqual(store.standaloneProfiles, [])
    }

    @MainActor
    func testCreateRemoteProfileFailsWhenTheSaveFails() async throws {
        let store = makeStore(coordinator: SwitchCoordinatingStub(), fetchRemoteContent: { _ in
            "1.2.3.4 a.example.com\n"
        })
        // Sabotage persistence: without the first-capture backup the workspace refuses to save.
        try FileManager.default.removeItem(at: rootDirectory.appendingPathComponent("hosts.orig"))

        let outcome = await store.createRemoteProfile(
            sourceURL: URL(string: "https://example.com/hosts.txt")!,
            name: "",
            interval: .twentyFourHours
        )

        guard case .failed(let message) = outcome else {
            return XCTFail("expected a failure, got \(outcome)")
        }
        XCTAssertTrue(message.hasPrefix("Save failed:"), message)
        XCTAssertEqual(store.standaloneProfiles, [], "a failed save must not leave an in-memory profile")
    }

    @MainActor
    func testCreateRemoteProfileCancelledAfterTheFetchStoresNothing() async throws {
        let store = makeStore(coordinator: SwitchCoordinatingStub(), fetchRemoteContent: { _ in
            // Returns content only once the surrounding task is cancelled, pinning the
            // cancellation between the successful fetch and persistence.
            while !Task.isCancelled {
                await Task.yield()
            }
            return "1.2.3.4 a.example.com\n"
        })

        let creation = Task {
            await store.createRemoteProfile(
                sourceURL: URL(string: "https://example.com/hosts.txt")!,
                name: "",
                interval: .twentyFourHours
            )
        }
        creation.cancel()
        let outcome = await creation.value

        XCTAssertEqual(outcome, .failed("The fetch was cancelled."))
        XCTAssertEqual(store.standaloneProfiles, [])
        XCTAssertEqual(try reloadModel().standaloneProfiles, [])
    }

    @MainActor
    func testCreateRemoteProfileEscapesAnEmbeddedHeaderInFetchedContent() async throws {
        let store = makeStore(coordinator: SwitchCoordinatingStub(), fetchRemoteContent: { _ in
            "#!hostflip-remote https://other.example.com/hosts.txt\n1.2.3.4 a.example.com\n"
        })

        let outcome = await store.createRemoteProfile(
            sourceURL: URL(string: "https://example.com/hosts.txt")!,
            name: "Nested",
            interval: .manual
        )

        guard case .created(let profileID) = outcome else {
            return XCTFail("expected creation, got \(outcome)")
        }
        let profile = try XCTUnwrap(store.profile(profileID))
        XCTAssertEqual(profile.remoteHeader?.sourceURL.absoluteString, "https://example.com/hosts.txt")
        XCTAssertTrue(profile.content.contains("# #!hostflip-remote https://other.example.com/hosts.txt"))
    }

    @MainActor
    func testCreateRemoteProfileDefaultsTheNameToTheHost() async throws {
        let store = makeStore(coordinator: SwitchCoordinatingStub(), fetchRemoteContent: { _ in
            "1.2.3.4 a.example.com\n"
        })

        let first = await store.createRemoteProfile(
            sourceURL: URL(string: "https://example.com/hosts.txt")!,
            name: "  ",
            interval: .twentyFourHours
        )
        let second = await store.createRemoteProfile(
            sourceURL: URL(string: "https://example.com/other.txt")!,
            name: "",
            interval: .twentyFourHours
        )

        guard case .created = first, case .created = second else {
            return XCTFail("expected two creations, got \(first) and \(second)")
        }
        XCTAssertEqual(store.standaloneProfiles.map(\.name), ["example.com", "example.com 2"])
    }

    /// The in-app end of the provenance guarantee: activating a created Remote Profile hands the
    /// daemon a merge whose content carries the header line, so /etc/hosts shows the Source URL.
    @MainActor
    func testActivatingACreatedRemoteProfileMergesTheProvenanceLine() async throws {
        let stub = SwitchCoordinatingStub()
        let store = makeStore(coordinator: stub, fetchRemoteContent: { _ in
            "140.82.112.4 github.com\n"
        })
        let outcome = await store.createRemoteProfile(
            sourceURL: URL(string: "https://example.com/hosts.txt")!,
            name: "GitHub520",
            interval: .oneHour
        )
        guard case .created(let profileID) = outcome else {
            return XCTFail("expected creation, got \(outcome)")
        }

        store.setProfileActive(profileID, true)
        await store.switchTask?.value

        XCTAssertTrue(store.isActive(profileID))
        let merged = try XCTUnwrap(stub.performedSwitches.last)
        XCTAssertTrue(merged.content.contains(
            "#!hostflip-remote https://example.com/hosts.txt interval=1h"
        ))
        XCTAssertTrue(merged.content.contains("140.82.112.4 github.com"))
    }

    // MARK: - Refreshing remote profiles (#70)

    @MainActor
    func testCreateRemoteProfileRecordsTheValidationFetchAsTheFirstSuccess() async throws {
        let store = makeStore(coordinator: SwitchCoordinatingStub(), fetchRemoteContent: { _ in
            "1.2.3.4 a.example.com\n"
        })

        let profileID = try await createRemoteProfile(in: store)

        let expected = RemoteRefreshState(lastSuccessAt: Self.refreshClock, lastAttemptFailed: false)
        XCTAssertEqual(store.profile(profileID)?.remoteRefreshState, expected)
        XCTAssertEqual(try reloadModel().profile(profileID)?.remoteRefreshState, expected)
    }

    @MainActor
    func testRefreshUpdatesContentRecordsSuccessAndMergesThroughTheAuthorizedPath() async throws {
        let stub = SwitchCoordinatingStub()
        let content = RemoteContentStub()
        let url = URL(string: "https://example.com/hosts.txt")!
        content.set(url, .success("1.1.1.1 v1.example.com\n"))
        let store = makeStore(coordinator: stub, fetchRemoteContent: { try content.fetch($0) })
        let profileID = try await createRemoteProfile(in: store, url: url)
        store.setProfileActive(profileID, true)
        await store.switchTask?.value
        await store.followUpMergeTask?.value
        XCTAssertEqual(stub.performedSwitches.count, 1)

        content.set(url, .success("2.2.2.2 v2.example.com\n"))
        await store.refreshRemoteProfile(profileID)
        await store.followUpMergeTask?.value

        let profile = try XCTUnwrap(store.profile(profileID))
        XCTAssertEqual(RemoteHeader.storedBody(of: profile.content), "2.2.2.2 v2.example.com\n")
        XCTAssertEqual(
            profile.remoteRefreshState,
            RemoteRefreshState(lastSuccessAt: Self.refreshClock, lastAttemptFailed: false)
        )
        // The write went through mergeIfAuthorized only: no new switch, so registration and
        // approval prompting can never trigger.
        XCTAssertEqual(stub.performedSwitches.count, 1)
        let merged = try XCTUnwrap(stub.authorizedMerges.last)
        XCTAssertTrue(merged.content.contains("2.2.2.2 v2.example.com"))
        XCTAssertEqual(
            RemoteHeader.storedBody(of: try XCTUnwrap(reloadModel().profile(profileID)).content),
            "2.2.2.2 v2.example.com\n"
        )
    }

    @MainActor
    func testRefreshFailureKeepsTheOldContentAndRecordsThePassiveFailure() async throws {
        let stub = SwitchCoordinatingStub()
        let content = RemoteContentStub()
        let url = URL(string: "https://example.com/hosts.txt")!
        content.set(url, .success("1.1.1.1 v1.example.com\n"))
        let store = makeStore(coordinator: stub, fetchRemoteContent: { try content.fetch($0) })
        let profileID = try await createRemoteProfile(in: store, url: url)
        let contentBeforeRefresh = try XCTUnwrap(store.profile(profileID)).content

        content.set(url, .failure(RemoteFetchError.httpStatus(500)))
        await store.refreshRemoteProfile(profileID)

        let profile = try XCTUnwrap(store.profile(profileID))
        XCTAssertEqual(profile.content, contentBeforeRefresh)
        XCTAssertEqual(
            profile.remoteRefreshState,
            RemoteRefreshState(lastSuccessAt: Self.refreshClock, lastAttemptFailed: true)
        )
        XCTAssertEqual(store.remoteRefreshErrors[profileID], "The server responded with HTTP 500.")
        XCTAssertNil(store.followUpMergeTask)
        XCTAssertEqual(stub.authorizedMerges, [])
        XCTAssertEqual(stub.performedSwitches, [])
        // The failed flag survives a relaunch; the detailed copy is in-memory only.
        XCTAssertEqual(
            try reloadModel().profile(profileID)?.remoteRefreshState,
            RemoteRefreshState(lastSuccessAt: Self.refreshClock, lastAttemptFailed: true)
        )
    }

    @MainActor
    func testRefreshSendsTheStoredValidatorsAndStoresTheResponseValidators() async throws {
        let outcomes = RemoteOutcomeStub()
        let url = URL(string: "https://example.com/hosts.txt")!
        let creationValidators = RemoteContentValidators(etag: "\"v1\"")
        outcomes.set(url, .success(.content("1.1.1.1 v1.example.com\n", validators: creationValidators)))
        let store = makeStore(
            coordinator: SwitchCoordinatingStub(),
            fetchRemote: { try outcomes.fetch($0, sending: $1) }
        )
        let profileID = try await createRemoteProfile(in: store, url: url)

        let refreshValidators = RemoteContentValidators(
            etag: "\"v2\"",
            lastModified: "Mon, 17 Aug 2026 00:00:00 GMT"
        )
        outcomes.set(url, .success(.content("2.2.2.2 v2.example.com\n", validators: refreshValidators)))
        await store.refreshRemoteProfile(profileID)

        // The dialog's validation fetch is unconditional; the refresh echoes the validators
        // the creation stored, and stores the response's validators for the next fetch.
        XCTAssertEqual(outcomes.sentValidators, [nil, creationValidators])
        let expected = RemoteRefreshState(
            lastSuccessAt: Self.refreshClock,
            lastAttemptFailed: false,
            validators: refreshValidators
        )
        XCTAssertEqual(store.profile(profileID)?.remoteRefreshState, expected)
        XCTAssertEqual(try reloadModel().profile(profileID)?.remoteRefreshState, expected)
    }

    @MainActor
    func testA304AnswerKeepsTheContentAndOnlyAdvancesTheSuccessTime() async throws {
        let stub = SwitchCoordinatingStub()
        let outcomes = RemoteOutcomeStub()
        let clock = MutableClock(Self.refreshClock)
        let url = URL(string: "https://example.com/hosts.txt")!
        let validators = RemoteContentValidators(etag: "\"v1\"")
        outcomes.set(url, .success(.content("1.1.1.1 v1.example.com\n", validators: validators)))
        let store = WorkspaceStore(
            workspace: Workspace(rootDirectory: rootDirectory),
            coordinator: stub,
            readSystemHosts: { Data(Self.importedHosts.utf8) },
            fetchRemote: { try outcomes.fetch($0, sending: $1) },
            now: { clock.now }
        )
        store.loadIfNeeded()
        let profileID = try await createRemoteProfile(in: store, url: url)
        // A failure in between proves the 304 clears the marker like a full success would.
        outcomes.set(url, .failure(RemoteFetchError.httpStatus(500)))
        await store.refreshRemoteProfile(profileID)
        XCTAssertNotNil(store.remoteRefreshErrors[profileID])
        let contentBeforeRefresh = try XCTUnwrap(store.profile(profileID)).content

        clock.advance(by: 600)
        outcomes.set(url, .success(.notModified(validators: nil)))
        await store.refreshRemoteProfile(profileID)

        let profile = try XCTUnwrap(store.profile(profileID))
        XCTAssertEqual(profile.content, contentBeforeRefresh)
        let expected = RemoteRefreshState(
            lastSuccessAt: Self.refreshClock.addingTimeInterval(600),
            lastAttemptFailed: false,
            validators: validators
        )
        XCTAssertEqual(profile.remoteRefreshState, expected)
        XCTAssertNil(store.remoteRefreshErrors[profileID])
        // Nothing was downloaded and nothing changed, so nothing merges.
        XCTAssertNil(store.followUpMergeTask)
        XCTAssertEqual(stub.authorizedMerges, [])
        XCTAssertEqual(try reloadModel().profile(profileID)?.remoteRefreshState, expected)

        // A later 304 carrying refreshed validators replaces the stored ones.
        clock.advance(by: 600)
        let refreshed = RemoteContentValidators(etag: "\"v1-refreshed\"")
        outcomes.set(url, .success(.notModified(validators: refreshed)))
        await store.refreshRemoteProfile(profileID)

        XCTAssertEqual(store.profile(profileID)?.content, contentBeforeRefresh)
        XCTAssertEqual(
            store.profile(profileID)?.remoteRefreshState,
            RemoteRefreshState(
                lastSuccessAt: Self.refreshClock.addingTimeInterval(1200),
                lastAttemptFailed: false,
                validators: refreshed
            )
        )
    }

    @MainActor
    func testARefreshOvertakenByAConcurrentWriterIsDropped() async throws {
        let stub = SwitchCoordinatingStub()
        let outcomes = RemoteOutcomeStub()
        let url = URL(string: "https://example.com/hosts.txt")!
        outcomes.set(url, .success(.content("1.1.1.1 v1.example.com\n", validators: nil)))
        let store = makeStore(coordinator: stub, fetchRemote: { try outcomes.fetch($0, sending: $1) })
        let profileID = try await createRemoteProfile(in: store, url: url)
        let header = try XCTUnwrap(store.profile(profileID)?.remoteHeader)
        // While this refresh's fetch is in flight, a foreign writer (the CLI) refreshes the
        // same URL and saves newer content; the possibly older response landing afterwards
        // must not overwrite it — the moved success-time baseline marks it stale.
        let root: URL = rootDirectory
        let foreignSuccessAt = Self.refreshClock.addingTimeInterval(300)
        let foreignContent = header.storedContent(forFetched: "2.2.2.2 v2.example.com\n")
        outcomes.setBeforeFetch {
            let workspace = Workspace(rootDirectory: root)
            var model = try workspace.openReadOnly()
            try model.updateProfileContent(profileID, content: foreignContent)
            try model.recordRemoteRefreshSuccess(profileID, at: foreignSuccessAt)
            try workspace.save(model)
        }
        outcomes.set(url, .success(.content("1.1.1.1 v1-stale.example.com\n", validators: nil)))

        await store.refreshRemoteProfile(profileID)

        let profile = try XCTUnwrap(store.profile(profileID))
        XCTAssertEqual(RemoteHeader.storedBody(of: profile.content), "2.2.2.2 v2.example.com\n")
        XCTAssertEqual(
            profile.remoteRefreshState,
            RemoteRefreshState(lastSuccessAt: foreignSuccessAt, lastAttemptFailed: false)
        )
        XCTAssertNil(store.remoteRefreshErrors[profileID])
        XCTAssertEqual(
            RemoteHeader.storedBody(of: try XCTUnwrap(reloadModel().profile(profileID)).content),
            "2.2.2.2 v2.example.com\n"
        )
    }

    @MainActor
    func testRefreshesWithAFractionalSecondClockKeepApplying() async throws {
        // The production clock is Date() with fractional seconds, unlike the whole-second
        // refreshClock every other test injects. The recorded date must survive the
        // manifest's whole-second ISO8601 round trip, or the in-memory baseline never
        // matches the replayed disk state and every refresh after the first drops as stale
        // (found on a verification machine, 2026-08-18).
        let url = URL(string: "https://example.com/hosts.txt")!
        let outcomes = RemoteOutcomeStub()
        outcomes.set(url, .success(.content("1.1.1.1 v1.example.com\n", validators: nil)))
        let store = WorkspaceStore(
            workspace: Workspace(rootDirectory: rootDirectory),
            coordinator: SwitchCoordinatingStub(),
            readSystemHosts: { Data(Self.importedHosts.utf8) },
            fetchRemote: { try outcomes.fetch($0, sending: $1) },
            now: { Date(timeIntervalSince1970: 1_755_505_332.734) }
        )
        store.loadIfNeeded()
        let profileID = try await createRemoteProfile(in: store, url: url)

        outcomes.set(url, .success(.content("2.2.2.2 v2.example.com\n", validators: nil)))
        await store.refreshRemoteProfile(profileID)
        XCTAssertEqual(
            RemoteHeader.storedBody(of: try XCTUnwrap(store.profile(profileID)).content),
            "2.2.2.2 v2.example.com\n"
        )

        outcomes.set(url, .success(.content("3.3.3.3 v3.example.com\n", validators: nil)))
        await store.refreshRemoteProfile(profileID)
        XCTAssertEqual(
            RemoteHeader.storedBody(of: try XCTUnwrap(store.profile(profileID)).content),
            "3.3.3.3 v3.example.com\n"
        )
    }

    @MainActor
    func testASameSecondConcurrentRefreshIsStillDetectedAsStale() async throws {
        // The manifest stores whole seconds and the injected clock is fixed, so the foreign
        // refresh's success time equals this refresh's baseline: the stored body is what
        // marks the older in-flight response stale.
        let outcomes = RemoteOutcomeStub()
        let url = URL(string: "https://example.com/hosts.txt")!
        outcomes.set(url, .success(.content("1.1.1.1 v1.example.com\n", validators: nil)))
        let store = makeStore(
            coordinator: SwitchCoordinatingStub(),
            fetchRemote: { try outcomes.fetch($0, sending: $1) }
        )
        let profileID = try await createRemoteProfile(in: store, url: url)
        let header = try XCTUnwrap(store.profile(profileID)?.remoteHeader)
        let root: URL = rootDirectory
        let foreignContent = header.storedContent(forFetched: "3.3.3.3 newer.example.com\n")
        let sameSecond = Self.refreshClock
        outcomes.setBeforeFetch {
            let workspace = Workspace(rootDirectory: root)
            var model = try workspace.openReadOnly()
            try model.updateProfileContent(profileID, content: foreignContent)
            try model.recordRemoteRefreshSuccess(profileID, at: sameSecond)
            try workspace.save(model)
        }
        outcomes.set(url, .success(.content("2.2.2.2 stale.example.com\n", validators: nil)))

        await store.refreshRemoteProfile(profileID)

        XCTAssertEqual(
            RemoteHeader.storedBody(of: try XCTUnwrap(store.profile(profileID)).content),
            "3.3.3.3 newer.example.com\n"
        )
        XCTAssertEqual(
            RemoteHeader.storedBody(of: try XCTUnwrap(reloadModel().profile(profileID)).content),
            "3.3.3.3 newer.example.com\n"
        )
    }

    @MainActor
    func testA304ResendingOneValidatorKeepsTheOtherStoredField() async throws {
        let outcomes = RemoteOutcomeStub()
        let url = URL(string: "https://example.com/hosts.txt")!
        outcomes.set(url, .success(.content(
            "1.1.1.1 v1.example.com\n",
            validators: RemoteContentValidators(
                etag: "\"v1\"",
                lastModified: "Mon, 17 Aug 2026 00:00:00 GMT"
            )
        )))
        let store = makeStore(
            coordinator: SwitchCoordinatingStub(),
            fetchRemote: { try outcomes.fetch($0, sending: $1) }
        )
        let profileID = try await createRemoteProfile(in: store, url: url)

        // RFC 7232 lets the 304 resend any subset: the resent field replaces the stored
        // one, the omitted field must keep its stored value.
        outcomes.set(url, .success(.notModified(
            validators: RemoteContentValidators(etag: "\"v1-refreshed\"")
        )))
        await store.refreshRemoteProfile(profileID)

        XCTAssertEqual(
            store.profile(profileID)?.remoteRefreshState?.validators,
            RemoteContentValidators(
                etag: "\"v1-refreshed\"",
                lastModified: "Mon, 17 Aug 2026 00:00:00 GMT"
            )
        )
    }

    @MainActor
    func testRemoteScheduleEntriesDeriveFromTheHeadersAndRefreshState() async throws {
        let store = makeStore(coordinator: SwitchCoordinatingStub(), fetchRemoteContent: { _ in
            "1.1.1.1 v1.example.com\n"
        })
        store.createStandaloneProfile()
        let url = URL(string: "https://example.com/hosts.txt")!
        let outcome = await store.createRemoteProfile(sourceURL: url, name: "Remote", interval: .oneHour)
        guard case .created(let profileID) = outcome else {
            return XCTFail("expected creation, got \(outcome)")
        }

        XCTAssertEqual(
            store.remoteScheduleEntries,
            [RemoteRefreshSchedule.Entry(
                profileID: profileID,
                interval: .oneHour,
                lastSuccessAt: Self.refreshClock
            )]
        )

        // Every started refresh — manual and scheduled alike — records its attempt time,
        // which the entries surface so the scheduler can space retries.
        await store.refreshRemoteProfile(profileID)
        XCTAssertEqual(store.remoteScheduleEntries.first?.lastAttemptAt, Self.refreshClock)
    }

    @MainActor
    func testModelChangesPokeTheRemoteScheduleHook() {
        let store = makeStore(coordinator: SwitchCoordinatingStub())
        var pokes = 0
        store.remoteScheduleChanged = { pokes += 1 }

        store.createStandaloneProfile()

        XCTAssertGreaterThan(pokes, 0)
    }

    @MainActor
    func testRefreshWithUnchangedContentDoesNotTouchTheSystemHosts() async throws {
        let stub = SwitchCoordinatingStub()
        let content = RemoteContentStub()
        let url = URL(string: "https://example.com/hosts.txt")!
        content.set(url, .success("1.1.1.1 v1.example.com\n"))
        let store = makeStore(coordinator: stub, fetchRemoteContent: { try content.fetch($0) })
        let profileID = try await createRemoteProfile(in: store, url: url)
        store.setProfileActive(profileID, true)
        await store.switchTask?.value
        await store.followUpMergeTask?.value
        // A failure in between proves the unchanged refresh still records a fresh success.
        content.set(url, .failure(RemoteFetchError.httpStatus(500)))
        await store.refreshRemoteProfile(profileID)
        let mergeCount = stub.authorizedMerges.count
        let contentBeforeRefresh = try XCTUnwrap(store.profile(profileID)).content

        content.set(url, .success("1.1.1.1 v1.example.com\n"))
        await store.refreshRemoteProfile(profileID)

        let profile = try XCTUnwrap(store.profile(profileID))
        XCTAssertEqual(profile.content, contentBeforeRefresh)
        XCTAssertEqual(
            profile.remoteRefreshState,
            RemoteRefreshState(lastSuccessAt: Self.refreshClock, lastAttemptFailed: false)
        )
        XCTAssertNil(store.remoteRefreshErrors[profileID])
        XCTAssertEqual(stub.authorizedMerges.count, mergeCount)
    }

    @MainActor
    func testRefreshingAnInactiveProfileOnlyUpdatesTheWorkspace() async throws {
        let stub = SwitchCoordinatingStub()
        let content = RemoteContentStub()
        let url = URL(string: "https://example.com/hosts.txt")!
        content.set(url, .success("1.1.1.1 v1.example.com\n"))
        let store = makeStore(coordinator: stub, fetchRemoteContent: { try content.fetch($0) })
        let profileID = try await createRemoteProfile(in: store, url: url)

        content.set(url, .success("2.2.2.2 v2.example.com\n"))
        await store.refreshRemoteProfile(profileID)

        XCTAssertEqual(
            RemoteHeader.storedBody(of: try XCTUnwrap(store.profile(profileID)).content),
            "2.2.2.2 v2.example.com\n"
        )
        XCTAssertNil(store.followUpMergeTask)
        XCTAssertEqual(stub.authorizedMerges, [])
        XCTAssertEqual(stub.performedSwitches, [])
        XCTAssertEqual(
            RemoteHeader.storedBody(of: try XCTUnwrap(reloadModel().profile(profileID)).content),
            "2.2.2.2 v2.example.com\n"
        )
    }

    @MainActor
    func testRefreshingWhilePausedOnlyUpdatesTheWorkspace() async throws {
        let stub = SwitchCoordinatingStub()
        let content = RemoteContentStub()
        let url = URL(string: "https://example.com/hosts.txt")!
        content.set(url, .success("1.1.1.1 v1.example.com\n"))
        let store = makeStore(coordinator: stub, fetchRemoteContent: { try content.fetch($0) })
        let profileID = try await createRemoteProfile(in: store, url: url)
        store.setProfileActive(profileID, true)
        await store.switchTask?.value
        store.setPaused(true)
        await store.switchTask?.value
        await store.followUpMergeTask?.value
        let mergeCount = stub.authorizedMerges.count

        content.set(url, .success("2.2.2.2 v2.example.com\n"))
        await store.refreshRemoteProfile(profileID)

        XCTAssertEqual(
            RemoteHeader.storedBody(of: try XCTUnwrap(store.profile(profileID)).content),
            "2.2.2.2 v2.example.com\n"
        )
        XCTAssertEqual(stub.authorizedMerges.count, mergeCount)
    }

    @MainActor
    func testRefreshingUnderDriftUpdatesTheWorkspaceAndTheDaemonGateRejectsTheWrite() async throws {
        let stub = SwitchCoordinatingStub()
        let driftMonitor = HostsDriftMonitoringStub()
        let content = RemoteContentStub()
        let url = URL(string: "https://example.com/hosts.txt")!
        content.set(url, .success("1.1.1.1 v1.example.com\n"))
        let store = makeStore(
            coordinator: stub,
            driftMonitor: driftMonitor,
            fetchRemoteContent: { try content.fetch($0) }
        )
        let profileID = try await createRemoteProfile(in: store, url: url)
        store.setProfileActive(profileID, true)
        await store.switchTask?.value
        await store.followUpMergeTask?.value
        driftMonitor.report(true)
        XCTAssertTrue(store.hasHostsDrift)
        stub.authorizedMergeOutcome = .success(
            .channelFailed(
                .mergeRejected(.hostsDrift(expected: "expected", actual: "actual")),
                statusAfterError: .enabled
            )
        )
        let mergeCount = stub.authorizedMerges.count

        content.set(url, .success("2.2.2.2 v2.example.com\n"))
        await store.refreshRemoteProfile(profileID)
        await store.followUpMergeTask?.value

        // The workspace holds the refreshed content; the daemon's drift gate rejected the
        // write, so the system hosts stays untouched until reconciliation carries it over.
        XCTAssertEqual(
            RemoteHeader.storedBody(of: try XCTUnwrap(store.profile(profileID)).content),
            "2.2.2.2 v2.example.com\n"
        )
        XCTAssertEqual(stub.authorizedMerges.count, mergeCount + 1)
        XCTAssertEqual(stub.performedSwitches.count, 1)
        XCTAssertNotNil(store.backgroundSyncError)
        XCTAssertEqual(
            RemoteHeader.storedBody(of: try XCTUnwrap(reloadModel().profile(profileID)).content),
            "2.2.2.2 v2.example.com\n"
        )
    }

    @MainActor
    func testRefreshAllRefreshesEveryRemoteProfileAndSkipsLocalOnes() async throws {
        let stub = SwitchCoordinatingStub()
        let content = RemoteContentStub()
        let firstURL = URL(string: "https://example.com/hosts.txt")!
        let secondURL = URL(string: "https://other.example.com/hosts.txt")!
        content.set(firstURL, .success("1.1.1.1 v1.example.com\n"))
        content.set(secondURL, .success("1.1.1.1 v1.other.example.com\n"))
        let store = makeStore(coordinator: stub, fetchRemoteContent: { try content.fetch($0) })
        let firstID = try await createRemoteProfile(in: store, url: firstURL)
        let secondID = try await createRemoteProfile(in: store, url: secondURL, name: "Other")
        let localID = try XCTUnwrap(store.createStandaloneProfile())
        let localContent = try XCTUnwrap(store.profile(localID)).content

        content.set(firstURL, .success("2.2.2.2 v2.example.com\n"))
        content.set(secondURL, .success("2.2.2.2 v2.other.example.com\n"))
        await store.refreshAllRemoteProfiles()

        XCTAssertEqual(
            RemoteHeader.storedBody(of: try XCTUnwrap(store.profile(firstID)).content),
            "2.2.2.2 v2.example.com\n"
        )
        XCTAssertEqual(
            RemoteHeader.storedBody(of: try XCTUnwrap(store.profile(secondID)).content),
            "2.2.2.2 v2.other.example.com\n"
        )
        XCTAssertEqual(store.profile(localID)?.content, localContent)
    }

    @MainActor
    func testARefreshResultForAReplacedSourceURLIsDropped() async throws {
        let stub = SwitchCoordinatingStub()
        let content = RemoteContentStub()
        let url = URL(string: "https://example.com/hosts.txt")!
        content.set(url, .success("1.1.1.1 v1.example.com\n"))
        let store = makeStore(coordinator: stub, fetchRemoteContent: { try content.fetch($0) })
        let profileID = try await createRemoteProfile(in: store, url: url)
        // While the fetch is in flight, a foreign writer retargets the profile to another
        // Source URL; the fetched result belongs to the old URL and must be dropped.
        let foreignContent = RemoteHeader(sourceURL: URL(string: "https://other.example.com/hosts.txt")!)!
            .storedContent(forFetched: "9.9.9.9 foreign.example.com\n")
        let root: URL = rootDirectory
        content.setBeforeFetch {
            let workspace = Workspace(rootDirectory: root)
            var model = try workspace.openReadOnly()
            try model.updateProfileContent(profileID, content: foreignContent)
            try workspace.save(model)
        }
        content.set(url, .success("2.2.2.2 stale.example.com\n"))

        await store.refreshRemoteProfile(profileID)

        XCTAssertEqual(store.profile(profileID)?.content, foreignContent)
        XCTAssertNil(store.followUpMergeTask)
        XCTAssertEqual(stub.authorizedMerges, [])
        XCTAssertEqual(try reloadModel().profile(profileID)?.content, foreignContent)
    }

    @MainActor
    func testARefreshFailureForAReplacedSourceURLIsDropped() async throws {
        let stub = SwitchCoordinatingStub()
        let content = RemoteContentStub()
        let url = URL(string: "https://example.com/hosts.txt")!
        content.set(url, .success("1.1.1.1 v1.example.com\n"))
        let store = makeStore(coordinator: stub, fetchRemoteContent: { try content.fetch($0) })
        let profileID = try await createRemoteProfile(in: store, url: url)
        // The profile is retargeted while the failing fetch is in flight: the old URL's
        // failure must not mark the new subscription as failed.
        let foreignContent = RemoteHeader(sourceURL: URL(string: "https://other.example.com/hosts.txt")!)!
            .storedContent(forFetched: "9.9.9.9 foreign.example.com\n")
        let root: URL = rootDirectory
        content.setBeforeFetch {
            let workspace = Workspace(rootDirectory: root)
            var model = try workspace.openReadOnly()
            try model.updateProfileContent(profileID, content: foreignContent)
            try workspace.save(model)
        }
        content.set(url, .failure(RemoteFetchError.httpStatus(500)))

        await store.refreshRemoteProfile(profileID)

        XCTAssertEqual(store.profile(profileID)?.content, foreignContent)
        XCTAssertNil(store.profile(profileID)?.remoteRefreshState)
        XCTAssertNil(store.remoteRefreshErrors[profileID])
        XCTAssertNil(try reloadModel().profile(profileID)?.remoteRefreshState)
    }

    @MainActor
    func testARefreshSaveFailureCancelsThePendingFollowUpMerge() async throws {
        let stub = SwitchCoordinatingStub()
        let content = RemoteContentStub()
        let url = URL(string: "https://example.com/hosts.txt")!
        content.set(url, .success("1.1.1.1 v1.example.com\n"))
        let store = makeStore(coordinator: stub, fetchRemoteContent: { try content.fetch($0) })
        let profileID = try await createRemoteProfile(in: store, url: url)
        // An ordinary edit leaves a debounced follow-up merge pending…
        store.createStandaloneProfile()
        XCTAssertNotNil(store.followUpMergeTask)
        // …then persistence breaks and a refresh comes back with new content. The refreshed
        // content lives only in memory now, so the pending merge must not fire with it.
        try FileManager.default.removeItem(at: rootDirectory.appendingPathComponent("hosts.orig"))
        content.set(url, .success("2.2.2.2 v2.example.com\n"))

        await store.refreshRemoteProfile(profileID)
        await store.followUpMergeTask?.value

        XCTAssertNotNil(store.saveError)
        XCTAssertEqual(stub.authorizedMerges, [])
        XCTAssertEqual(stub.performedSwitches, [])
    }

    @MainActor
    func testARefreshFailureRecomputesTheDriftComparisonAfterAbsorbingExternalChanges() async throws {
        let stub = SwitchCoordinatingStub()
        let driftMonitor = HostsDriftMonitoringStub()
        let content = RemoteContentStub()
        let url = URL(string: "https://example.com/hosts.txt")!
        content.set(url, .success("1.1.1.1 v1.example.com\n"))
        let store = makeStore(
            coordinator: stub,
            driftMonitor: driftMonitor,
            fetchRemoteContent: { try content.fetch($0) }
        )
        let localID = try XCTUnwrap(store.createStandaloneProfile())
        store.setProfileActive(localID, true)
        await store.switchTask?.value
        await store.followUpMergeTask?.value
        // The coordinator stub bypasses the real MergeCoordinator's hash recording; record it
        // so the drift review diffs against the merged output, as it does after a real write (#82).
        try Workspace(rootDirectory: rootDirectory).recordLastWrittenHash("stub")
        let remoteID = try await createRemoteProfile(in: store, url: url)
        driftMonitor.report(true)
        let comparisonBefore = try XCTUnwrap(store.hostsDriftComparison)
        // A foreign writer changes the active profile's content on disk; the failure replay
        // absorbs it, so the reviewed diff must be recomputed against the new model.
        let root: URL = rootDirectory
        content.setBeforeFetch {
            let workspace = Workspace(rootDirectory: root)
            var model = try workspace.openReadOnly()
            try model.updateProfileContent(localID, content: "5.5.5.5 foreign.example.com\n")
            try workspace.save(model)
        }
        content.set(url, .failure(RemoteFetchError.httpStatus(500)))

        await store.refreshRemoteProfile(remoteID)

        XCTAssertEqual(store.profile(localID)?.content, "5.5.5.5 foreign.example.com\n")
        XCTAssertNotEqual(store.hostsDriftComparison, comparisonBefore)
    }

    @MainActor
    func testRefreshingALocalProfileDoesNothing() async throws {
        let store = makeStore(coordinator: SwitchCoordinatingStub())
        let profileID = try XCTUnwrap(store.createStandaloneProfile())
        await store.followUpMergeTask?.value
        let contentBefore = try XCTUnwrap(store.profile(profileID)).content

        await store.refreshRemoteProfile(profileID)

        XCTAssertEqual(store.profile(profileID)?.content, contentBefore)
        XCTAssertNil(store.profile(profileID)?.remoteRefreshState)
        XCTAssertNil(store.remoteRefreshErrors[profileID])
    }

    // MARK: - Converting between local and remote (ADR-0012)

    @MainActor
    func testEditingALocalProfileToARemoteHeaderIsHeldForConfirmation() throws {
        let store = makeStore(coordinator: SwitchCoordinatingStub())
        let profileID = try XCTUnwrap(store.createStandaloneProfile())
        let original = try XCTUnwrap(store.profile(profileID)).content
        let draft = "#!hostflip-remote https://example.com/hosts.txt interval=6h\n"

        store.updateProfileContent(profileID, content: draft)

        // The stored content is untouched until the conversion is confirmed and validated.
        XCTAssertEqual(store.profile(profileID)?.content, original)
        XCTAssertEqual(try reloadModel().profile(profileID)?.content, original)
        let pending = try XCTUnwrap(store.pendingRemoteConversion)
        XCTAssertEqual(pending.profileID, profileID)
        XCTAssertEqual(pending.header.sourceURL.absoluteString, "https://example.com/hosts.txt")
        // The editor keeps showing the held draft while the confirmation is up.
        XCTAssertEqual(store.editedProfileContent(profileID), draft)
    }

    @MainActor
    func testBreakingTheHeldHeaderDraftAppliesTheEditAsAPlainLocalEdit() throws {
        let store = makeStore(coordinator: SwitchCoordinatingStub())
        let profileID = try XCTUnwrap(store.createStandaloneProfile())
        store.updateProfileContent(profileID, content: "#!hostflip-remote https://example.com/x\n")

        // The next keystroke breaks the would-be header; the flip is off the table.
        store.updateProfileContent(profileID, content: "# #!hostflip-remote https://example.com/x\n")

        XCTAssertNil(store.pendingRemoteConversion)
        let profile = try XCTUnwrap(store.profile(profileID))
        XCTAssertEqual(profile.content, "# #!hostflip-remote https://example.com/x\n")
        XCTAssertFalse(profile.isRemote)
    }

    @MainActor
    func testCancellingTheConversionKeepsTheContentAsItWas() throws {
        let store = makeStore(coordinator: SwitchCoordinatingStub())
        let profileID = try XCTUnwrap(store.createStandaloneProfile())
        let original = try XCTUnwrap(store.profile(profileID)).content
        store.updateProfileContent(profileID, content: "#!hostflip-remote https://example.com/x\n")

        store.cancelRemoteConversion()

        XCTAssertNil(store.pendingRemoteConversion)
        XCTAssertEqual(store.profile(profileID)?.content, original)
        XCTAssertEqual(store.editedProfileContent(profileID), original)
        XCTAssertFalse(try XCTUnwrap(store.profile(profileID)).isRemote)
    }

    @MainActor
    func testConfirmingTheConversionFetchesValidatesAndConverts() async throws {
        let store = makeStore(coordinator: SwitchCoordinatingStub(), fetchRemoteContent: { _ in
            "9.9.9.9 fetched.example.com\n"
        })
        let profileID = try XCTUnwrap(store.createStandaloneProfile())
        store.updateProfileContent(
            profileID,
            content: "#!hostflip-remote https://example.com/hosts.txt interval=6h\n# typed\n"
        )

        let outcome = await store.confirmRemoteConversion()

        XCTAssertEqual(outcome, .converted)
        XCTAssertNil(store.pendingRemoteConversion)
        let profile = try XCTUnwrap(store.profile(profileID))
        XCTAssertTrue(profile.isRemote)
        // Converting stores like creation: the validated fetch becomes the body — the
        // draft below the typed header was the request to go remote, not content to keep.
        XCTAssertEqual(
            profile.content,
            "#!hostflip-remote https://example.com/hosts.txt interval=6h\n9.9.9.9 fetched.example.com\n"
        )
        // The validation fetch is the first successful refresh (ADR-0012).
        XCTAssertEqual(
            profile.remoteRefreshState,
            RemoteRefreshState(lastSuccessAt: Self.refreshClock, lastAttemptFailed: false)
        )
        XCTAssertEqual(try reloadModel().profile(profileID)?.content, profile.content)
    }

    @MainActor
    func testAFailedConversionFetchKeepsTheContentAndTheDraftForRetry() async throws {
        let store = makeStore(coordinator: SwitchCoordinatingStub(), fetchRemoteContent: { _ in
            throw RemoteFetchError.httpStatus(404)
        })
        let profileID = try XCTUnwrap(store.createStandaloneProfile())
        let original = try XCTUnwrap(store.profile(profileID)).content
        store.updateProfileContent(profileID, content: "#!hostflip-remote https://example.com/x\n")

        let outcome = await store.confirmRemoteConversion()

        XCTAssertEqual(outcome, .failed("The server responded with HTTP 404."))
        let profile = try XCTUnwrap(store.profile(profileID))
        XCTAssertEqual(profile.content, original)
        XCTAssertFalse(profile.isRemote)
        // The draft stays held: the dialog offers retry or cancel, like the creation dialog.
        XCTAssertNotNil(store.pendingRemoteConversion)
    }

    @MainActor
    func testConvertingAnActiveProfileMergesTheHeaderLineThroughTheAuthorizedPath() async throws {
        let stub = SwitchCoordinatingStub()
        let store = makeStore(coordinator: stub, fetchRemoteContent: { _ in
            "1.2.3.4 a.example.com\n"
        })
        let profileID = try XCTUnwrap(store.createStandaloneProfile())
        store.setProfileActive(profileID, true)
        await store.switchTask?.value
        let switchCount = stub.performedSwitches.count
        store.updateProfileContent(
            profileID, content: "#!hostflip-remote https://example.com/x interval=1h\n"
        )

        let outcome = await store.confirmRemoteConversion()
        await store.followUpMergeTask?.value

        XCTAssertEqual(outcome, .converted)
        // The conversion is an edit, not a switch: no registration or approval can trigger.
        XCTAssertEqual(stub.performedSwitches.count, switchCount)
        let merged = try XCTUnwrap(stub.authorizedMerges.last)
        XCTAssertTrue(merged.content.contains("#!hostflip-remote https://example.com/x interval=1h"))
        XCTAssertTrue(merged.content.contains("1.2.3.4 a.example.com"))
    }

    @MainActor
    func testConvertToLocalStripsTheHeaderKeepsTheContentAndClearsTheRefreshState() async throws {
        let stub = SwitchCoordinatingStub()
        let content = RemoteContentStub()
        let url = URL(string: "https://example.com/hosts.txt")!
        content.set(url, .success("1.1.1.1 v1.example.com\n"))
        let store = makeStore(coordinator: stub, fetchRemoteContent: { try content.fetch($0) })
        let profileID = try await createRemoteProfile(in: store, url: url)
        // A stale failure marker and its copy must not survive Convert to Local.
        content.set(url, .failure(RemoteFetchError.httpStatus(500)))
        await store.refreshRemoteProfile(profileID)
        XCTAssertNotNil(store.remoteRefreshErrors[profileID])

        store.convertRemoteProfileToLocal(profileID)

        let profile = try XCTUnwrap(store.profile(profileID))
        XCTAssertFalse(profile.isRemote)
        XCTAssertEqual(profile.content, "1.1.1.1 v1.example.com\n")
        XCTAssertNil(profile.remoteRefreshState)
        XCTAssertNil(store.remoteRefreshErrors[profileID])
        let reloaded = try XCTUnwrap(reloadModel().profile(profileID))
        XCTAssertEqual(reloaded.content, "1.1.1.1 v1.example.com\n")
        XCTAssertNil(reloaded.remoteRefreshState)
    }

    @MainActor
    func testConvertToLocalKeepsGroupingAndActiveStateAndDropsTheProvenanceLine() async throws {
        let stub = SwitchCoordinatingStub()
        let store = makeStore(coordinator: stub, fetchRemoteContent: { _ in
            "2.2.2.2 b.example.com\n"
        })
        let groupID = try XCTUnwrap(store.createGroup())
        let profileID = try await createRemoteProfile(in: store)
        store.moveProfile(profileID, toGroup: groupID, at: 0)
        store.setProfileActive(profileID, true)
        await store.switchTask?.value

        store.convertRemoteProfileToLocal(profileID)
        await store.followUpMergeTask?.value

        XCTAssertTrue(store.isActive(profileID))
        XCTAssertEqual(store.group(containing: profileID)?.id, groupID)
        // The merged output loses the provenance line along with the Remote Header.
        let merged = try XCTUnwrap(stub.authorizedMerges.last)
        XCTAssertFalse(merged.content.contains("#!hostflip-remote"))
        XCTAssertTrue(merged.content.contains("2.2.2.2 b.example.com"))
    }

    @MainActor
    func testConvertToLocalKeepsAnEscapedEmbeddedHeaderEscaped() async throws {
        let embedded = "#!hostflip-remote https://other.example.com/x interval=1h\n3.3.3.3 c.example.com\n"
        let store = makeStore(coordinator: SwitchCoordinatingStub(), fetchRemoteContent: { _ in
            embedded
        })
        let profileID = try await createRemoteProfile(in: store)

        store.convertRemoteProfileToLocal(profileID)

        // Q17③ regression: stripping the header must not expose the escaped embedded token —
        // the escape stays, so the profile stays local instead of flipping straight back.
        let profile = try XCTUnwrap(store.profile(profileID))
        XCTAssertFalse(profile.isRemote)
        XCTAssertEqual(profile.content, "# " + embedded)
        XCTAssertNil(store.pendingRemoteConversion)
    }

    @MainActor
    func testEditingTheIntervalOnlyRewritesTheHeaderWithoutFetching() async throws {
        let content = RemoteContentStub()
        let url = URL(string: "https://example.com/hosts.txt")!
        content.set(url, .success("1.1.1.1 v1.example.com\n"))
        let store = makeStore(coordinator: SwitchCoordinatingStub(), fetchRemoteContent: {
            try content.fetch($0)
        })
        let profileID = try await createRemoteProfile(in: store, url: url)
        // Any fetch from here on would fail the edit, proving the interval change never fetches.
        content.set(url, .failure(RemoteFetchError.httpStatus(500)))

        let outcome = await store.editRemoteProfile(profileID, sourceURL: url, interval: .sixHours)

        XCTAssertEqual(outcome, .updated)
        let profile = try XCTUnwrap(store.profile(profileID))
        XCTAssertEqual(
            profile.content,
            "#!hostflip-remote https://example.com/hosts.txt interval=6h\n1.1.1.1 v1.example.com\n"
        )
        // An interval edit keeps the same Source URL: the refresh state survives.
        XCTAssertEqual(
            profile.remoteRefreshState,
            RemoteRefreshState(lastSuccessAt: Self.refreshClock, lastAttemptFailed: false)
        )
        XCTAssertEqual(try reloadModel().profile(profileID)?.content, profile.content)
    }

    @MainActor
    func testEditingTheSourceURLFetchesTheNewURLAndResetsTheState() async throws {
        let content = RemoteContentStub()
        let oldURL = URL(string: "https://example.com/hosts.txt")!
        let newURL = URL(string: "https://mirror.example.net/hosts.txt")!
        content.set(oldURL, .success("1.1.1.1 old.example.com\n"))
        content.set(newURL, .success("2.2.2.2 new.example.com\n"))
        let store = makeStore(coordinator: SwitchCoordinatingStub(), fetchRemoteContent: {
            try content.fetch($0)
        })
        let profileID = try await createRemoteProfile(in: store, url: oldURL)
        // A failure marker on the old Source URL must not follow the new one.
        content.set(oldURL, .failure(RemoteFetchError.httpStatus(500)))
        await store.refreshRemoteProfile(profileID)
        XCTAssertNotNil(store.remoteRefreshErrors[profileID])

        let outcome = await store.editRemoteProfile(profileID, sourceURL: newURL, interval: .oneHour)

        XCTAssertEqual(outcome, .updated)
        let profile = try XCTUnwrap(store.profile(profileID))
        XCTAssertEqual(
            profile.content,
            "#!hostflip-remote https://mirror.example.net/hosts.txt interval=1h\n2.2.2.2 new.example.com\n"
        )
        // The edit's validation fetch is the new Source URL's first success (ADR-0012).
        XCTAssertEqual(
            profile.remoteRefreshState,
            RemoteRefreshState(lastSuccessAt: Self.refreshClock, lastAttemptFailed: false)
        )
        XCTAssertNil(store.remoteRefreshErrors[profileID])
        XCTAssertEqual(try reloadModel().profile(profileID)?.content, profile.content)
    }

    @MainActor
    func testEditingTheSourceURLOfAnActiveProfileMergesTheNewSourceContent() async throws {
        let stub = SwitchCoordinatingStub()
        let content = RemoteContentStub()
        let oldURL = URL(string: "https://example.com/hosts.txt")!
        let newURL = URL(string: "https://mirror.example.net/hosts.txt")!
        content.set(oldURL, .success("1.1.1.1 old.example.com\n"))
        content.set(newURL, .success("2.2.2.2 new.example.com\n"))
        let store = makeStore(coordinator: stub, fetchRemoteContent: { try content.fetch($0) })
        let profileID = try await createRemoteProfile(in: store, url: oldURL)
        store.setProfileActive(profileID, true)
        await store.switchTask?.value
        await store.followUpMergeTask?.value

        let outcome = await store.editRemoteProfile(profileID, sourceURL: newURL, interval: .oneHour)
        await store.followUpMergeTask?.value

        XCTAssertEqual(outcome, .updated)
        let merged = try XCTUnwrap(stub.authorizedMerges.last)
        XCTAssertTrue(merged.content.contains(
            "#!hostflip-remote https://mirror.example.net/hosts.txt interval=1h"
        ))
        XCTAssertTrue(merged.content.contains("2.2.2.2 new.example.com"))
        XCTAssertFalse(merged.content.contains("https://example.com/hosts.txt"))
    }

    @MainActor
    func testAFailedSourceURLEditKeepsTheOldSourceContentUntouched() async throws {
        let content = RemoteContentStub()
        let oldURL = URL(string: "https://example.com/hosts.txt")!
        let newURL = URL(string: "https://mirror.example.net/hosts.txt")!
        content.set(oldURL, .success("1.1.1.1 old.example.com\n"))
        content.set(newURL, .failure(RemoteFetchError.looksLikeHTML))
        let store = makeStore(coordinator: SwitchCoordinatingStub(), fetchRemoteContent: {
            try content.fetch($0)
        })
        let profileID = try await createRemoteProfile(in: store, url: oldURL)
        let contentBefore = try XCTUnwrap(store.profile(profileID)).content

        let outcome = await store.editRemoteProfile(profileID, sourceURL: newURL, interval: .oneHour)

        XCTAssertEqual(outcome, .failed("The URL returned a web page, not hosts content."))
        let profile = try XCTUnwrap(store.profile(profileID))
        XCTAssertEqual(profile.content, contentBefore)
        XCTAssertEqual(
            profile.remoteRefreshState,
            RemoteRefreshState(lastSuccessAt: Self.refreshClock, lastAttemptFailed: false)
        )
        XCTAssertEqual(try reloadModel().profile(profileID)?.content, contentBefore)
    }

    @MainActor
    func testACancelledConversionFetchStoresNothing() async throws {
        let store = makeStore(coordinator: SwitchCoordinatingStub(), fetchRemoteContent: { _ in
            // Parks until the surrounding task is cancelled, like an in-flight network fetch.
            try await Task.sleep(for: .seconds(30))
            return "9.9.9.9 fetched.example.com\n"
        })
        let profileID = try XCTUnwrap(store.createStandaloneProfile())
        let original = try XCTUnwrap(store.profile(profileID)).content
        store.updateProfileContent(profileID, content: "#!hostflip-remote https://example.com/x\n")

        let conversion = Task { await store.confirmRemoteConversion() }
        conversion.cancel()
        let outcome = await conversion.value

        XCTAssertEqual(outcome, .failed("The fetch was cancelled."))
        let profile = try XCTUnwrap(store.profile(profileID))
        XCTAssertEqual(profile.content, original)
        XCTAssertFalse(profile.isRemote)
        XCTAssertEqual(try reloadModel().profile(profileID)?.content, original)
    }

    @MainActor
    func testACancelledSourceURLEditStoresNothing() async throws {
        let content = RemoteContentStub()
        let oldURL = URL(string: "https://example.com/hosts.txt")!
        content.set(oldURL, .success("1.1.1.1 old.example.com\n"))
        let store = makeStore(coordinator: SwitchCoordinatingStub(), fetchRemoteContent: { url in
            if url == oldURL { return try content.fetch(url) }
            // The edited URL's fetch parks until the surrounding task is cancelled.
            try await Task.sleep(for: .seconds(30))
            return "2.2.2.2 new.example.com\n"
        })
        let profileID = try await createRemoteProfile(in: store, url: oldURL)
        let contentBefore = try XCTUnwrap(store.profile(profileID)).content

        let edit = Task {
            await store.editRemoteProfile(
                profileID,
                sourceURL: URL(string: "https://mirror.example.net/hosts.txt")!,
                interval: .oneHour
            )
        }
        edit.cancel()
        let outcome = await edit.value

        XCTAssertEqual(outcome, .failed("The fetch was cancelled."))
        let profile = try XCTUnwrap(store.profile(profileID))
        XCTAssertEqual(profile.content, contentBefore)
        XCTAssertEqual(try reloadModel().profile(profileID)?.content, contentBefore)
    }

    @MainActor
    func testConfirmingAgainstAnExternallyEditedProfileRefusesAndKeepsTheirContent() async throws {
        let content = RemoteContentStub()
        let url = URL(string: "https://example.com/hosts.txt")!
        content.set(url, .success("9.9.9.9 fetched.example.com\n"))
        let store = makeStore(coordinator: SwitchCoordinatingStub(), fetchRemoteContent: {
            try content.fetch($0)
        })
        let profileID = try XCTUnwrap(store.createStandaloneProfile())
        store.updateProfileContent(profileID, content: "#!hostflip-remote https://example.com/hosts.txt\n")
        // While the validation fetch is in flight, a foreign writer saves its own local edit;
        // the confirmed conversion is stale and must not overwrite it.
        let root: URL = rootDirectory
        content.setBeforeFetch {
            let workspace = Workspace(rootDirectory: root)
            var model = try workspace.openReadOnly()
            try model.updateProfileContent(profileID, content: "5.5.5.5 foreign.example.com\n")
            try workspace.save(model)
        }

        let outcome = await store.confirmRemoteConversion()

        XCTAssertEqual(outcome, .failed("The profile was changed outside this dialog."))
        XCTAssertEqual(store.profile(profileID)?.content, "5.5.5.5 foreign.example.com\n")
        XCTAssertEqual(try reloadModel().profile(profileID)?.content, "5.5.5.5 foreign.example.com\n")
        // The draft stays held so the dialog can show the copy; Keep as Local drops it.
        XCTAssertNotNil(store.pendingRemoteConversion)
    }

    @MainActor
    func testAConversionSaveFailureStoresNothing() async throws {
        let store = makeStore(coordinator: SwitchCoordinatingStub(), fetchRemoteContent: { _ in
            "9.9.9.9 fetched.example.com\n"
        })
        let profileID = try XCTUnwrap(store.createStandaloneProfile())
        let original = try XCTUnwrap(store.profile(profileID)).content
        store.updateProfileContent(profileID, content: "#!hostflip-remote https://example.com/x\n")
        try FileManager.default.removeItem(at: rootDirectory.appendingPathComponent("hosts.orig"))

        let outcome = await store.confirmRemoteConversion()

        // The creation precedent: fetched content is re-fetchable, so a disk failure fails
        // the dialog whole instead of leaving a converted profile only in memory.
        guard case .failed(let message) = outcome else {
            return XCTFail("expected a save failure, got \(outcome)")
        }
        XCTAssertTrue(message.hasPrefix("Save failed:"))
        let profile = try XCTUnwrap(store.profile(profileID))
        XCTAssertEqual(profile.content, original)
        XCTAssertFalse(profile.isRemote)
        XCTAssertNotNil(store.pendingRemoteConversion)
    }

    @MainActor
    func testConvertToLocalKeepsAForeignlyRefreshedBody() async throws {
        let content = RemoteContentStub()
        let url = URL(string: "https://example.com/hosts.txt")!
        content.set(url, .success("1.1.1.1 v1.example.com\n"))
        let store = makeStore(coordinator: SwitchCoordinatingStub(), fetchRemoteContent: {
            try content.fetch($0)
        })
        let profileID = try await createRemoteProfile(in: store, url: url)
        // A foreign writer (e.g. the CLI) refreshed the content; the GUI model is stale. The
        // conversion must keep the genuinely last fetched content, not the stale snapshot.
        let freshContent = RemoteHeader(sourceURL: url, interval: .manual)!
            .storedContent(forFetched: "7.7.7.7 fresh.example.com\n")
        foreignlyModifyWorkspace { try $0.updateProfileContent(profileID, content: freshContent) }

        store.convertRemoteProfileToLocal(profileID)

        XCTAssertEqual(store.profile(profileID)?.content, "7.7.7.7 fresh.example.com\n")
        XCTAssertEqual(try reloadModel().profile(profileID)?.content, "7.7.7.7 fresh.example.com\n")
    }

    @MainActor
    func testAnIntervalEditRewritesTheHeaderAboveTheLatestSavedBody() async throws {
        let content = RemoteContentStub()
        let url = URL(string: "https://example.com/hosts.txt")!
        content.set(url, .success("1.1.1.1 v1.example.com\n"))
        let store = makeStore(coordinator: SwitchCoordinatingStub(), fetchRemoteContent: {
            try content.fetch($0)
        })
        let profileID = try await createRemoteProfile(in: store, url: url)
        // The body under the rewritten header must be the latest saved one, not the GUI's
        // stale snapshot from before this foreign refresh.
        let freshContent = RemoteHeader(sourceURL: url, interval: .manual)!
            .storedContent(forFetched: "7.7.7.7 fresh.example.com\n")
        foreignlyModifyWorkspace { try $0.updateProfileContent(profileID, content: freshContent) }

        let outcome = await store.editRemoteProfile(profileID, sourceURL: url, interval: .sixHours)

        XCTAssertEqual(outcome, .updated)
        XCTAssertEqual(
            store.profile(profileID)?.content,
            "#!hostflip-remote https://example.com/hosts.txt interval=6h\n7.7.7.7 fresh.example.com\n"
        )
    }

    @MainActor
    func testASourceURLEditAgainstAForeignRetargetIsRefused() async throws {
        let content = RemoteContentStub()
        let oldURL = URL(string: "https://example.com/hosts.txt")!
        let newURL = URL(string: "https://mirror.example.net/hosts.txt")!
        content.set(oldURL, .success("1.1.1.1 old.example.com\n"))
        content.set(newURL, .success("2.2.2.2 new.example.com\n"))
        let store = makeStore(coordinator: SwitchCoordinatingStub(), fetchRemoteContent: {
            try content.fetch($0)
        })
        let profileID = try await createRemoteProfile(in: store, url: oldURL)
        // A foreign writer retargets the profile while the edit's validation fetch is in
        // flight; the edit was confirmed against the old header and must not overwrite.
        let foreignContent = RemoteHeader(sourceURL: URL(string: "https://third.example.org/x")!)!
            .storedContent(forFetched: "9.9.9.9 foreign.example.com\n")
        let root: URL = rootDirectory
        content.setBeforeFetch {
            let workspace = Workspace(rootDirectory: root)
            var model = try workspace.openReadOnly()
            try model.updateProfileContent(profileID, content: foreignContent)
            try workspace.save(model)
        }

        let outcome = await store.editRemoteProfile(profileID, sourceURL: newURL, interval: .oneHour)

        XCTAssertEqual(outcome, .failed("The profile was changed outside this dialog."))
        XCTAssertEqual(store.profile(profileID)?.content, foreignContent)
        XCTAssertEqual(try reloadModel().profile(profileID)?.content, foreignContent)
    }

    @MainActor
    func testEditRemoteProfileRefusesWhenTheProfileIsNoLongerRemote() async throws {
        let content = RemoteContentStub()
        let url = URL(string: "https://example.com/hosts.txt")!
        content.set(url, .success("1.1.1.1 v1.example.com\n"))
        let store = makeStore(coordinator: SwitchCoordinatingStub(), fetchRemoteContent: {
            try content.fetch($0)
        })
        let profileID = try await createRemoteProfile(in: store, url: url)
        store.convertRemoteProfileToLocal(profileID)
        let contentBefore = try XCTUnwrap(store.profile(profileID)).content

        let outcome = await store.editRemoteProfile(profileID, sourceURL: url, interval: .oneHour)

        guard case .failed = outcome else {
            return XCTFail("expected a refusal, got \(outcome)")
        }
        XCTAssertEqual(store.profile(profileID)?.content, contentBefore)
    }

    @MainActor
    private func createRemoteProfile(
        in store: WorkspaceStore,
        url: URL = URL(string: "https://example.com/hosts.txt")!,
        name: String = "Remote"
    ) async throws -> Profile.ID {
        let outcome = await store.createRemoteProfile(sourceURL: url, name: name, interval: .manual)
        guard case .created(let profileID) = outcome else {
            XCTFail("expected creation, got \(outcome)")
            throw StubError()
        }
        return profileID
    }

    /// Simulates a foreign writer (e.g. the CLI): mutates the on-disk state through an independent
    /// Workspace instance, bypassing the store's in-memory model.
    private func foreignlyModifyWorkspace(_ change: (inout ActivationModel) throws -> Void) {
        do {
            let workspace = Workspace(rootDirectory: rootDirectory)
            var model = try workspace.open(systemHosts: {
                XCTFail("an initialized workspace must not capture the system hosts again")
                return ""
            })
            try change(&model)
            try workspace.save(model)
        } catch {
            XCTFail("foreign workspace modification failed: \(error)")
        }
    }

    // MARK: - Helpers

    @MainActor
    private func makeStore(
        coordinator: some SwitchCoordinating,
        fetchRemoteContent: @escaping @Sendable (URL) async throws -> String = { _ in
            throw StubError()
        }
    ) -> WorkspaceStore {
        makeStore(coordinator: coordinator, driftMonitor: nil, fetchRemoteContent: fetchRemoteContent)
    }

    @MainActor
    private func makeStore(
        coordinator: some SwitchCoordinating,
        driftMonitor: (any HostsDriftMonitoring)?,
        systemHosts: Data = Data(WorkspaceStoreTests.importedHosts.utf8),
        fetchRemoteContent: @escaping @Sendable (URL) async throws -> String = { _ in
            throw StubError()
        }
    ) -> WorkspaceStore {
        // Content-only fetches wrap into the conditional seam; tests that exercise the
        // conditional protocol itself inject a full outcome through the overload below.
        makeStore(
            coordinator: coordinator,
            driftMonitor: driftMonitor,
            systemHosts: systemHosts,
            fetchRemote: { url, _ in .content(try await fetchRemoteContent(url), validators: nil) }
        )
    }

    @MainActor
    private func makeStore(
        coordinator: some SwitchCoordinating,
        driftMonitor: (any HostsDriftMonitoring)? = nil,
        systemHosts: Data = Data(WorkspaceStoreTests.importedHosts.utf8),
        fetchRemote: @escaping @Sendable (URL, RemoteContentValidators?) async throws -> RemoteFetchOutcome
    ) -> WorkspaceStore {
        let store = WorkspaceStore(
            workspace: Workspace(rootDirectory: rootDirectory),
            coordinator: coordinator,
            driftMonitor: driftMonitor,
            readSystemHosts: { systemHosts },
            fetchRemote: fetchRemote,
            now: { Self.refreshClock }
        )
        store.loadIfNeeded()
        return store
    }

    /// Reloads with a fresh Workspace instance to verify persisted state; at this point the system hosts must never be imported again.
    private func reloadModel() throws -> ActivationModel {
        try Workspace(rootDirectory: rootDirectory).open(systemHosts: {
            XCTFail("an initialized workspace must not capture the system hosts again")
            return ""
        })
    }
}
