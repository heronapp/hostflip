import XCTest
@testable import HostflipCore

final class ActivationModelTests: XCTestCase {
    func testSelectingAProfileInAGroupMakesItActive() throws {
        let staging = makeProfile("staging")
        let production = makeProfile("production")
        var model = try makeModel(groups: [makeGroup("environment", profiles: [staging, production])])

        try model.toggleProfile(staging.id)

        XCTAssertEqual(model.activeProfileIDs, [staging.id])
        assertEffectiveProfiles([staging], in: model)
    }

    func testSelectingAnotherProfileInTheSameGroupReplacesTheActiveProfile() throws {
        let staging = makeProfile("staging")
        let production = makeProfile("production")
        var model = try makeModel(groups: [makeGroup("environment", profiles: [staging, production])])

        try model.toggleProfile(staging.id)
        try model.toggleProfile(production.id)

        XCTAssertEqual(model.activeProfileIDs, [production.id])
        assertEffectiveProfiles([production], in: model)
    }

    func testSelectingTheActiveProfileAgainClosesItsGroup() throws {
        let staging = makeProfile("staging")
        var model = try makeModel(groups: [makeGroup("environment", profiles: [staging])])

        try model.toggleProfile(staging.id)
        try model.toggleProfile(staging.id)

        XCTAssertEqual(model.activeProfileIDs, [])
        assertEffectiveProfiles([], in: model)
    }

    func testProfilesAcrossGroupsAndAStandaloneProfileCanBeActiveTogether() throws {
        let blocker = makeProfile("blocker")
        let staging = makeProfile("staging")
        let office = makeProfile("office")
        var model = try makeModel(
            standaloneProfiles: [blocker],
            groups: [
                makeGroup("environment", profiles: [staging]),
                makeGroup("network", profiles: [office]),
            ]
        )

        try model.toggleProfile(staging.id)
        try model.toggleProfile(office.id)
        try model.toggleProfile(blocker.id)

        XCTAssertEqual(model.activeProfileIDs, [blocker.id, staging.id, office.id])
        assertEffectiveProfiles([blocker, staging, office], in: model)

        try model.toggleProfile(blocker.id)

        XCTAssertEqual(model.activeProfileIDs, [staging.id, office.id])
    }

    func testRemoteHeaderContentFollowsTheSameActivationRulesAsLocalContent() throws {
        // Remote identity lives in the content's first line only (ADR-0012); activation, group
        // exclusivity, and standalone stacking never look at it.
        let headerLine = "#!hostflip-remote https://example.com/hosts.txt interval=1h\n"
        let groupedRemote = Profile(id: .init("grouped-remote"), name: "Grouped Remote", content: headerLine + "1.2.3.4 a.example.com\n")
        let sibling = makeProfile("sibling")
        let standaloneRemote = Profile(id: .init("standalone-remote"), name: "Standalone Remote", content: headerLine)
        var model = try makeModel(
            standaloneProfiles: [standaloneRemote],
            groups: [makeGroup("environment", profiles: [groupedRemote, sibling])]
        )

        try model.toggleProfile(groupedRemote.id)
        try model.toggleProfile(standaloneRemote.id)

        XCTAssertEqual(model.activeProfileIDs, [groupedRemote.id, standaloneRemote.id])
        assertEffectiveProfiles([standaloneRemote, groupedRemote], in: model)

        try model.toggleProfile(sibling.id)

        XCTAssertEqual(model.activeProfileIDs, [sibling.id, standaloneRemote.id])
        assertEffectiveProfiles([standaloneRemote, sibling], in: model)
    }

    func testPausingKeepsActivationStateWhileOnlyBaseHostsAreEffective() throws {
        let blocker = makeProfile("blocker")
        var model = try makeModel(standaloneProfiles: [blocker])
        try model.toggleProfile(blocker.id)

        model.setPaused(true)

        XCTAssertTrue(model.isPaused)
        XCTAssertEqual(model.activeProfileIDs, [blocker.id])
        assertEffectiveProfiles([], in: model)

        model.setPaused(false)

        XCTAssertFalse(model.isPaused)
        XCTAssertEqual(model.activeProfileIDs, [blocker.id])
        assertEffectiveProfiles([blocker], in: model)
    }

    func testTogglingAnUnknownProfileIsRejectedWithoutChangingState() throws {
        let unknownProfileID = Profile.ID("unknown")
        var model = try makeModel()

        XCTAssertThrowsError(try model.toggleProfile(unknownProfileID)) { error in
            XCTAssertEqual(error as? ActivationModelError, .unknownProfile(unknownProfileID))
        }
        XCTAssertEqual(model.activeProfileIDs, [])
    }

    func testDuplicateProfileIDsAreRejected() {
        let duplicateID = Profile.ID("duplicate")
        let standaloneProfile = Profile(id: duplicateID, name: "Free", content: "Free hosts")
        let groupedProfile = Profile(id: duplicateID, name: "Grouped", content: "Grouped hosts")

        XCTAssertThrowsError(
            try makeModel(
                standaloneProfiles: [standaloneProfile],
                groups: [makeGroup("group", profiles: [groupedProfile])]
            )
        ) { error in
            XCTAssertEqual(error as? ActivationModelError, .duplicateProfileID(duplicateID))
        }
    }

    func testRestoringActivationStateReproducesActiveProfilesAndPause() throws {
        let blocker = makeProfile("blocker")
        let staging = makeProfile("staging")
        let model = try ActivationModel(
            baseHosts: BaseHosts(content: "127.0.0.1 localhost"),
            standaloneProfiles: [blocker],
            groups: [makeGroup("environment", profiles: [staging])],
            activeProfileIDs: [blocker.id, staging.id],
            isPaused: true
        )

        XCTAssertEqual(model.activeProfileIDs, [blocker.id, staging.id])
        XCTAssertTrue(model.isPaused)
    }

    func testRestoringAnUnknownActiveProfileIsRejected() {
        let unknownProfileID = Profile.ID("unknown")

        XCTAssertThrowsError(
            try ActivationModel(
                baseHosts: BaseHosts(content: ""),
                standaloneProfiles: [],
                groups: [],
                activeProfileIDs: [unknownProfileID]
            )
        ) { error in
            XCTAssertEqual(error as? ActivationModelError, .unknownProfile(unknownProfileID))
        }
    }

    func testRestoringTwoActiveProfilesInOneGroupIsRejected() {
        let staging = makeProfile("staging")
        let production = makeProfile("production")
        let group = makeGroup("environment", profiles: [staging, production])

        XCTAssertThrowsError(
            try ActivationModel(
                baseHosts: BaseHosts(content: ""),
                standaloneProfiles: [],
                groups: [group],
                activeProfileIDs: [staging.id, production.id]
            )
        ) { error in
            XCTAssertEqual(
                error as? ActivationModelError,
                .conflictingActiveProfiles(group.id)
            )
        }
    }

    func testAddedProfileIsAStandaloneProfileAndInactiveByDefault() throws {
        var model = try makeModel()

        try model.addProfile(id: .init("blocker"), name: "Blocker", content: "# blocker")

        XCTAssertEqual(
            model.standaloneProfiles,
            [Profile(id: .init("blocker"), name: "Blocker", content: "# blocker")]
        )
        XCTAssertEqual(model.activeProfileIDs, [])
    }

    func testAddingAProfileWithADuplicateIDIsRejected() throws {
        let existing = makeProfile("blocker")
        var model = try makeModel(standaloneProfiles: [existing])

        XCTAssertThrowsError(
            try model.addProfile(id: existing.id, name: "Other", content: "")
        ) { error in
            XCTAssertEqual(error as? ActivationModelError, .duplicateProfileID(existing.id))
        }
        XCTAssertEqual(model.standaloneProfiles, [existing])
    }

    func testAProfileCanBeRenamedAndItsContentEdited() throws {
        let staging = makeProfile("staging")
        var model = try makeModel(groups: [makeGroup("environment", profiles: [staging])])

        try model.renameProfile(staging.id, to: "Staging EU")
        try model.updateProfileContent(staging.id, content: "10.0.0.9 api.example.com")

        XCTAssertEqual(
            model.groups.first?.profiles,
            [Profile(id: staging.id, name: "Staging EU", content: "10.0.0.9 api.example.com")]
        )
    }

    func testDeletingAProfileRemovesItAndClearsItsActivation() throws {
        let blocker = makeProfile("blocker")
        let staging = makeProfile("staging")
        var model = try makeModel(
            standaloneProfiles: [blocker],
            groups: [makeGroup("environment", profiles: [staging])]
        )
        try model.toggleProfile(blocker.id)
        try model.toggleProfile(staging.id)

        try model.deleteProfile(blocker.id)
        try model.deleteProfile(staging.id)

        XCTAssertEqual(model.standaloneProfiles, [])
        XCTAssertEqual(model.groups.first?.profiles, [])
        XCTAssertEqual(model.activeProfileIDs, [])
    }

    func testMutatingAnUnknownProfileIsRejected() throws {
        let unknownID = Profile.ID("unknown")
        var model = try makeModel()

        for operation: (inout ActivationModel) throws -> Void in [
            { try $0.renameProfile(unknownID, to: "New") },
            { try $0.updateProfileContent(unknownID, content: "") },
            { try $0.deleteProfile(unknownID) },
        ] {
            XCTAssertThrowsError(try operation(&model)) { error in
                XCTAssertEqual(error as? ActivationModelError, .unknownProfile(unknownID))
            }
        }
    }

    func testAGroupCanBeCreatedEmptyAndRenamed() throws {
        var model = try makeModel()

        try model.addGroup(id: .init("environment"), name: "Environment")
        try model.renameGroup(.init("environment"), to: "Environments")

        XCTAssertEqual(model.groups, [Group(id: .init("environment"), name: "Environments", profiles: [])])
    }

    func testAddingAGroupWithADuplicateIDIsRejected() throws {
        var model = try makeModel(groups: [makeGroup("environment", profiles: [])])

        XCTAssertThrowsError(
            try model.addGroup(id: .init("environment"), name: "Other")
        ) { error in
            XCTAssertEqual(error as? ActivationModelError, .duplicateGroupID(.init("environment")))
        }
        XCTAssertEqual(model.groups.count, 1)
    }

    func testDuplicateGroupIDsAreRejectedAtRestore() {
        XCTAssertThrowsError(
            try makeModel(groups: [
                makeGroup("environment", profiles: []),
                Group(id: .init("environment"), name: "Other", profiles: []),
            ])
        ) { error in
            XCTAssertEqual(error as? ActivationModelError, .duplicateGroupID(.init("environment")))
        }
    }

    func testDeletingAGroupDissolvesItsProfilesToTheStandaloneAreaKeepingActivation() throws {
        let blocker = makeProfile("blocker")
        let staging = makeProfile("staging")
        let production = makeProfile("production")
        var model = try makeModel(
            standaloneProfiles: [blocker],
            groups: [makeGroup("environment", profiles: [staging, production])]
        )
        try model.toggleProfile(staging.id)

        try model.deleteGroup(.init("environment"))

        XCTAssertEqual(model.groups, [])
        XCTAssertEqual(model.standaloneProfiles, [blocker, staging, production])
        XCTAssertEqual(model.activeProfileIDs, [staging.id])
        assertEffectiveProfiles([staging], in: model)
    }

    func testMutatingAnUnknownGroupIsRejected() throws {
        let unknownID = Group.ID("unknown")
        var model = try makeModel()

        for operation: (inout ActivationModel) throws -> Void in [
            { try $0.renameGroup(unknownID, to: "New") },
            { try $0.deleteGroup(unknownID) },
        ] {
            XCTAssertThrowsError(try operation(&model)) { error in
                XCTAssertEqual(error as? ActivationModelError, .unknownGroup(unknownID))
            }
        }
    }

    func testMovingAProfileBetweenContainersKeepsItsActivation() throws {
        let blocker = makeProfile("blocker")
        let staging = makeProfile("staging")
        var model = try makeModel(
            standaloneProfiles: [blocker],
            groups: [
                makeGroup("environment", profiles: [staging]),
                makeGroup("network", profiles: []),
            ]
        )
        try model.toggleProfile(blocker.id)
        try model.toggleProfile(staging.id)

        try model.moveProfile(blocker.id, toGroup: .init("network"))
        try model.moveProfile(staging.id, toGroup: nil)

        XCTAssertEqual(model.groups.last?.profiles, [blocker])
        XCTAssertEqual(model.standaloneProfiles, [staging])
        XCTAssertEqual(model.groups.first?.profiles, [])
        XCTAssertEqual(model.activeProfileIDs, [blocker.id, staging.id])
    }

    func testMovingAnActiveProfileIntoAGroupWithAnActiveProfileDeactivatesTheMovedOne() throws {
        let blocker = makeProfile("blocker")
        let staging = makeProfile("staging")
        var model = try makeModel(
            standaloneProfiles: [blocker],
            groups: [makeGroup("environment", profiles: [staging])]
        )
        try model.toggleProfile(blocker.id)
        try model.toggleProfile(staging.id)

        try model.moveProfile(blocker.id, toGroup: .init("environment"))

        XCTAssertEqual(model.groups.first?.profiles, [staging, blocker])
        XCTAssertEqual(model.activeProfileIDs, [staging.id])
    }

    func testMovingAProfileToAnUnknownGroupIsRejectedWithoutChangingState() throws {
        let blocker = makeProfile("blocker")
        var model = try makeModel(standaloneProfiles: [blocker])

        XCTAssertThrowsError(
            try model.moveProfile(blocker.id, toGroup: .init("unknown"))
        ) { error in
            XCTAssertEqual(error as? ActivationModelError, .unknownGroup(.init("unknown")))
        }
        XCTAssertEqual(model.standaloneProfiles, [blocker])
    }

    func testAProfileCanBeReorderedWithinItsContainer() throws {
        let blocker = makeProfile("blocker")
        let adguard = makeProfile("adguard")
        let staging = makeProfile("staging")
        let production = makeProfile("production")
        var model = try makeModel(
            standaloneProfiles: [blocker, adguard],
            groups: [makeGroup("environment", profiles: [staging, production])]
        )

        try model.moveProfile(blocker.id, toIndex: 1)
        try model.moveProfile(production.id, toIndex: 0)

        XCTAssertEqual(model.standaloneProfiles, [adguard, blocker])
        XCTAssertEqual(model.groups.first?.profiles, [production, staging])
    }

    func testAGroupCanBeReorderedAndOutOfRangeIndicesAreClamped() throws {
        let environment = makeGroup("environment", profiles: [])
        let network = makeGroup("network", profiles: [])
        var model = try makeModel(groups: [environment, network])

        try model.moveGroup(environment.id, toIndex: 99)
        XCTAssertEqual(model.groups, [network, environment])

        try model.moveGroup(environment.id, toIndex: -5)
        XCTAssertEqual(model.groups, [environment, network])
    }

    // MARK: - Remote refresh state (ADR-0012)

    func testProfileLookupFindsStandaloneAndGroupedProfiles() throws {
        let standalone = makeProfile("standalone")
        let grouped = makeProfile("grouped")
        let model = try makeModel(
            standaloneProfiles: [standalone],
            groups: [makeGroup("environment", profiles: [grouped])]
        )

        XCTAssertEqual(model.profile(standalone.id), standalone)
        XCTAssertEqual(model.profile(grouped.id), grouped)
        XCTAssertNil(model.profile(.init("missing")))
    }

    func testRecordingARefreshSuccessReplacesTheStateAndClearsTheFailureMarker() throws {
        let remote = makeRemoteProfile("remote")
        var model = try makeModel(standaloneProfiles: [remote])
        let succeededAt = Date(timeIntervalSince1970: 1_755_000_000)

        try model.recordRemoteRefreshFailure(remote.id)
        try model.recordRemoteRefreshSuccess(remote.id, at: succeededAt)

        XCTAssertEqual(
            model.profile(remote.id)?.remoteRefreshState,
            RemoteRefreshState(lastSuccessAt: succeededAt, lastAttemptFailed: false)
        )
    }

    func testRecordingARefreshSuccessFloorsTheDateToWholeSeconds() throws {
        // The manifest's ISO8601 encoding truncates fractional seconds; a recorded date
        // must equal its persisted round trip, or refresh staleness baselines would treat
        // every follow-up refresh as stale.
        let remote = makeRemoteProfile("remote")
        var model = try makeModel(standaloneProfiles: [remote])

        try model.recordRemoteRefreshSuccess(
            remote.id,
            at: Date(timeIntervalSince1970: 1_755_505_332.734)
        )

        XCTAssertEqual(
            model.profile(remote.id)?.remoteRefreshState?.lastSuccessAt,
            Date(timeIntervalSince1970: 1_755_505_332)
        )
    }

    func testRecordingARefreshSuccessStoresTheValidators() throws {
        let remote = makeRemoteProfile("remote")
        var model = try makeModel(standaloneProfiles: [remote])
        let succeededAt = Date(timeIntervalSince1970: 1_755_000_000)
        let validators = RemoteContentValidators(
            etag: "\"abc123\"",
            lastModified: "Mon, 17 Aug 2026 00:00:00 GMT"
        )

        try model.recordRemoteRefreshSuccess(remote.id, at: succeededAt, validators: validators)

        XCTAssertEqual(
            model.profile(remote.id)?.remoteRefreshState,
            RemoteRefreshState(
                lastSuccessAt: succeededAt,
                lastAttemptFailed: false,
                validators: validators
            )
        )
    }

    func testRecordingARefreshFailureKeepsTheValidators() throws {
        // A failed attempt keeps the last successful content, and with it the validators
        // that describe that content: the next conditional fetch must still be able to
        // answer 304 for it.
        let remote = makeRemoteProfile("remote")
        var model = try makeModel(standaloneProfiles: [remote])
        let validators = RemoteContentValidators(etag: "\"abc123\"")
        try model.recordRemoteRefreshSuccess(
            remote.id,
            at: Date(timeIntervalSince1970: 1_755_000_000),
            validators: validators
        )

        try model.recordRemoteRefreshFailure(remote.id)

        XCTAssertEqual(model.profile(remote.id)?.remoteRefreshState?.validators, validators)
    }

    func testRecordingARefreshFailureKeepsTheLastSuccessTime() throws {
        let remote = makeRemoteProfile("remote")
        var model = try makeModel(standaloneProfiles: [remote])
        let succeededAt = Date(timeIntervalSince1970: 1_755_000_000)

        try model.recordRemoteRefreshSuccess(remote.id, at: succeededAt)
        try model.recordRemoteRefreshFailure(remote.id)

        XCTAssertEqual(
            model.profile(remote.id)?.remoteRefreshState,
            RemoteRefreshState(lastSuccessAt: succeededAt, lastAttemptFailed: true)
        )
    }

    func testRecordingAFailureWithoutAPriorSuccessMarksTheStateFailed() throws {
        let remote = makeRemoteProfile("remote")
        var model = try makeModel(standaloneProfiles: [remote])

        try model.recordRemoteRefreshFailure(remote.id)

        XCTAssertEqual(
            model.profile(remote.id)?.remoteRefreshState,
            RemoteRefreshState(lastSuccessAt: nil, lastAttemptFailed: true)
        )
    }

    func testRecordingARefreshOnAnUnknownProfileIsRejected() throws {
        var model = try makeModel()

        XCTAssertThrowsError(try model.recordRemoteRefreshSuccess(.init("missing"), at: .now)) {
            XCTAssertEqual($0 as? ActivationModelError, .unknownProfile(.init("missing")))
        }
    }

    func testABodyOnlyContentUpdateKeepsTheRefreshState() throws {
        let remote = makeRemoteProfile("remote")
        var model = try makeModel(standaloneProfiles: [remote])
        try model.recordRemoteRefreshSuccess(remote.id, at: Date(timeIntervalSince1970: 1_755_000_000))
        let state = model.profile(remote.id)?.remoteRefreshState

        try model.updateProfileContent(
            remote.id,
            content: remote.remoteHeader!.storedContent(forFetched: "9.9.9.9 changed.example.com\n")
        )

        XCTAssertNotNil(state)
        XCTAssertEqual(model.profile(remote.id)?.remoteRefreshState, state)
    }

    func testAnIntervalOnlyHeaderEditKeepsTheRefreshState() throws {
        let remote = makeRemoteProfile("remote")
        var model = try makeModel(standaloneProfiles: [remote])
        try model.recordRemoteRefreshSuccess(remote.id, at: Date(timeIntervalSince1970: 1_755_000_000))
        let state = model.profile(remote.id)?.remoteRefreshState
        let retimed = RemoteHeader(sourceURL: remote.remoteHeader!.sourceURL, interval: .oneHour)!

        try model.updateProfileContent(remote.id, content: retimed.line + "\nbody\n")

        XCTAssertEqual(model.profile(remote.id)?.remoteRefreshState, state)
    }

    func testChangingTheSourceURLClearsTheRefreshState() throws {
        let remote = makeRemoteProfile("remote")
        var model = try makeModel(standaloneProfiles: [remote])
        try model.recordRemoteRefreshSuccess(remote.id, at: Date(timeIntervalSince1970: 1_755_000_000))
        let retargeted = RemoteHeader(sourceURL: URL(string: "https://other.example.com/hosts.txt")!)!

        try model.updateProfileContent(remote.id, content: retargeted.line + "\nbody\n")

        XCTAssertNil(model.profile(remote.id)?.remoteRefreshState)
    }

    func testRemovingTheRemoteHeaderClearsTheRefreshState() throws {
        // Convert to Local (#72) strips the header via updateProfileContent, so the runtime
        // state clears without a dedicated call.
        let remote = makeRemoteProfile("remote")
        var model = try makeModel(standaloneProfiles: [remote])
        try model.recordRemoteRefreshSuccess(remote.id, at: Date(timeIntervalSince1970: 1_755_000_000))

        try model.updateProfileContent(remote.id, content: "1.2.3.4 kept.example.com\n")

        XCTAssertNil(model.profile(remote.id)?.remoteRefreshState)
    }

    private func makeProfile(_ id: String) -> Profile {
        Profile(id: .init(id), name: id.capitalized, content: "\(id.capitalized) hosts")
    }

    private func makeRemoteProfile(_ id: String) -> Profile {
        let header = RemoteHeader(sourceURL: URL(string: "https://example.com/hosts.txt")!)!
        return Profile(
            id: .init(id),
            name: id.capitalized,
            content: header.storedContent(forFetched: "1.2.3.4 a.example.com\n")
        )
    }

    private func makeGroup(_ id: String, profiles: [Profile]) -> Group {
        Group(id: .init(id), name: id.capitalized, profiles: profiles)
    }

    private func makeModel(
        standaloneProfiles: [Profile] = [],
        groups: [Group] = []
    ) throws -> ActivationModel {
        try ActivationModel(
            baseHosts: BaseHosts(content: "127.0.0.1 localhost"),
            standaloneProfiles: standaloneProfiles,
            groups: groups
        )
    }

    private func assertEffectiveProfiles(
        _ profiles: [Profile],
        in model: ActivationModel,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(
            model.effectiveCombination,
            HostsCombination(baseHosts: model.baseHosts, profiles: profiles),
            file: file,
            line: line
        )
    }
}
