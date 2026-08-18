import Foundation
import HostflipCore
import HostflipXPC
import XCTest
@testable import HostflipCLI

/// `hostflip refresh` (#73, ADR-0012): the two independently reported layers — fetched
/// content always commits to the workspace, the system hosts write happens only for a
/// changed active profile and its refusals exit 3/4 with the content kept — plus the
/// conditional-request path, the addressing contract, and the per-profile `--json` results.
final class RefreshCommandTests: XCTestCase {
    private var rootDirectory: URL!
    private var workspaceRootDirectory: URL!
    private var systemHostsURL: URL!

    private let capturedHosts = "127.0.0.1 localhost\n"
    private let remoteURL = URL(string: "https://one.example.com/hosts.txt")!
    private let otherURL = URL(string: "https://two.example.com/hosts.txt")!
    /// A whole second: the manifest stores ISO8601, which carries no sub-second precision.
    private let recordedSuccessAt = Date(timeIntervalSince1970: 1_755_000_000)

    override func setUpWithError() throws {
        rootDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("hostflip-refresh-tests-\(UUID().uuidString)", isDirectory: true)
        workspaceRootDirectory = rootDirectory.appendingPathComponent("workspace", isDirectory: true)
        systemHostsURL = rootDirectory.appendingPathComponent("hosts")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: rootDirectory)
    }

    // MARK: - Refreshing all remote profiles

    func testRefreshAllUpdatesRemoteProfilesAndLeavesLocalOnesAlone() async throws {
        try makeWorkspace(includeSecondRemote: true)
        let fetch = FetchStub()
        fetch.set(remoteURL, .success(.content("2.2.2.2 one.example.com\n", validators: nil)))
        fetch.set(otherURL, .success(.content("1.1.1.1 two.example.com\n", validators: nil)))

        let result = await invoke("refresh", fetch: fetch)

        XCTAssertEqual(result.exitCode, .success)
        XCTAssertEqual(result.standardError, "")
        XCTAssertTrue(result.standardOutput.hasPrefix("Refreshed 2 of 2 remote profiles.\n"))
        let persisted = try reloadModel()
        XCTAssertEqual(
            RemoteHeader.storedBody(of: persisted.profile(.init("remote-id"))!.content),
            "2.2.2.2 one.example.com\n"
        )
        // The second source already matches the stored body: unchanged, but a fresh success.
        XCTAssertEqual(
            RemoteHeader.storedBody(of: persisted.profile(.init("second-id"))!.content),
            "1.1.1.1 two.example.com\n"
        )
        XCTAssertEqual(persisted.profile(.init("solo-id"))!.content, "# solo")
        XCTAssertNotNil(persisted.profile(.init("remote-id"))!.remoteRefreshState?.lastSuccessAt)
    }

    func testRefreshJSONReportsPerProfileResults() async throws {
        try makeWorkspace(includeSecondRemote: true)
        let fetch = FetchStub()
        fetch.set(remoteURL, .success(.content("2.2.2.2 one.example.com\n", validators: nil)))
        fetch.set(otherURL, .success(.content("1.1.1.1 two.example.com\n", validators: nil)))

        let result = await invoke("--json", "refresh", fetch: fetch)

        XCTAssertEqual(result.exitCode, .success)
        let object = try jsonObject(result.standardOutput)
        let profiles = try XCTUnwrap(object["profiles"] as? [[String: Any]])
        XCTAssertEqual(profiles.count, 2)
        XCTAssertEqual(profiles[0]["id"] as? String, "remote-id")
        XCTAssertEqual(profiles[0]["status"] as? String, "updated")
        XCTAssertEqual(profiles[0]["url"] as? String, remoteURL.absoluteString)
        XCTAssertNil(profiles[0]["error"])
        XCTAssertEqual(profiles[1]["id"] as? String, "second-id")
        XCTAssertEqual(profiles[1]["status"] as? String, "unchanged")
        let write = try XCTUnwrap(object["write"] as? [String: Any])
        XCTAssertEqual(write["status"] as? String, "not-needed")
    }

    func testWithoutRemoteProfilesRefreshIsACleanNoOp() async throws {
        try makeWorkspace(includeRemote: false)
        let merger = MergerStub()
        let spy = WorkspaceChangeSpy()

        let result = await invoke("refresh", fetch: FetchStub(), merger: merger, spy: spy)

        XCTAssertEqual(result.exitCode, .success)
        XCTAssertEqual(result.standardOutput, "No remote profiles.\n")
        XCTAssertEqual(merger.recordedRequests.count, 0)
        XCTAssertEqual(spy.postCount, 0, "nothing was saved, so nothing is announced")
    }

    // MARK: - The system hosts write layer

    func testAnUpdatedActiveProfileRewritesTheSystemHosts() async throws {
        try makeWorkspace(activeRemote: true)
        let merger = MergerStub()
        let fetch = FetchStub()
        fetch.set(remoteURL, .success(.content("2.2.2.2 one.example.com\n", validators: nil)))

        let result = await invoke("refresh", fetch: fetch, merger: merger)

        XCTAssertEqual(result.exitCode, .success)
        XCTAssertTrue(result.standardOutput.hasSuffix("The system hosts was updated.\n"))
        XCTAssertEqual(merger.recordedRequests.count, 1)
        XCTAssertTrue(merger.recordedRequests[0].merged.content.contains("2.2.2.2 one.example.com"))
    }

    func testAChangedInactiveProfileNeverTouchesTheDaemon() async throws {
        try makeWorkspace(activeRemote: false)
        let merger = MergerStub()
        let fetch = FetchStub()
        fetch.set(remoteURL, .success(.content("2.2.2.2 one.example.com\n", validators: nil)))

        let result = await invoke("--json", "refresh", fetch: fetch, merger: merger)

        XCTAssertEqual(result.exitCode, .success)
        XCTAssertEqual(merger.recordedRequests.count, 0)
        let write = try XCTUnwrap(try jsonObject(result.standardOutput)["write"] as? [String: Any])
        XCTAssertEqual(write["status"] as? String, "not-needed")
    }

    func testAnUnchangedActiveProfileNeverTouchesTheDaemon() async throws {
        try makeWorkspace(activeRemote: true)
        let merger = MergerStub()
        let fetch = FetchStub()
        fetch.set(remoteURL, .success(.content("1.1.1.1 one.example.com\n", validators: nil)))

        let result = await invoke("refresh", fetch: fetch, merger: merger)

        XCTAssertEqual(result.exitCode, .success)
        XCTAssertEqual(merger.recordedRequests.count, 0)
    }

    func testDriftBlocksTheWriteButKeepsTheFetchedContent() async throws {
        try makeWorkspace(activeRemote: true)
        try Data("6.6.6.6 foreign.example.com\n".utf8).write(to: systemHostsURL)
        let merger = MergerStub()
        let fetch = FetchStub()
        fetch.set(remoteURL, .success(.content("2.2.2.2 one.example.com\n", validators: nil)))

        let result = await invoke("refresh", fetch: fetch, merger: merger)

        XCTAssertEqual(result.exitCode, .drift)
        XCTAssertTrue(result.standardOutput.contains("updated"), "the content layer still reports")
        XCTAssertTrue(result.standardError.contains("the system hosts was not updated"))
        XCTAssertTrue(result.standardError.contains("changed outside hostflip"))
        XCTAssertEqual(merger.recordedRequests.count, 0)
        // Never rolled back: the fetched content is saved even though the write was blocked.
        XCTAssertEqual(
            RemoteHeader.storedBody(of: try reloadModel().profile(.init("remote-id"))!.content),
            "2.2.2.2 one.example.com\n"
        )
    }

    func testDriftJSONCarriesBothLayers() async throws {
        try makeWorkspace(activeRemote: true)
        try Data("6.6.6.6 foreign.example.com\n".utf8).write(to: systemHostsURL)
        let fetch = FetchStub()
        fetch.set(remoteURL, .success(.content("2.2.2.2 one.example.com\n", validators: nil)))

        let result = await invoke("--json", "refresh", fetch: fetch)

        XCTAssertEqual(result.exitCode, .drift)
        XCTAssertEqual(result.standardError, "", "JSON mode carries the report in the result object")
        let object = try jsonObject(result.standardOutput)
        XCTAssertEqual((object["profiles"] as? [[String: Any]])?.first?["status"] as? String, "updated")
        let write = try XCTUnwrap(object["write"] as? [String: Any])
        XCTAssertEqual(write["status"] as? String, "failed")
        let error = try XCTUnwrap(write["error"] as? [String: Any])
        XCTAssertEqual(error["code"] as? String, "hosts-drift")
    }

    func testAnUnavailableDaemonExitsFourAndKeepsTheContent() async throws {
        try makeWorkspace(activeRemote: true)
        let merger = MergerStub(script: [{ _ in throw DaemonChannelError.unavailable }])
        let fetch = FetchStub()
        fetch.set(remoteURL, .success(.content("2.2.2.2 one.example.com\n", validators: nil)))

        let result = await invoke("--json", "refresh", fetch: fetch, merger: merger)

        XCTAssertEqual(result.exitCode, .daemonUnavailable)
        let write = try XCTUnwrap(try jsonObject(result.standardOutput)["write"] as? [String: Any])
        XCTAssertEqual(write["status"] as? String, "failed")
        XCTAssertEqual((write["error"] as? [String: Any])?["code"] as? String, "daemon-unavailable")
        XCTAssertEqual(
            RemoteHeader.storedBody(of: try reloadModel().profile(.init("remote-id"))!.content),
            "2.2.2.2 one.example.com\n"
        )
    }

    func testABlockedWriteOutranksAPartialSourceFailure() async throws {
        // Both at once: one source failed (exit 1 alone) and the write of the other's
        // changed content is blocked by drift (exit 3 alone). The blocked write demands
        // human action on the live system state, so 3 wins; the per-profile results still
        // carry the fetch failure.
        try makeWorkspace(activeRemote: true, includeSecondRemote: true)
        try Data("6.6.6.6 foreign.example.com\n".utf8).write(to: systemHostsURL)
        let fetch = FetchStub()
        fetch.set(remoteURL, .success(.content("2.2.2.2 one.example.com\n", validators: nil)))
        fetch.set(otherURL, .failure(RemoteFetchError.httpStatus(500)))

        let result = await invoke("--json", "refresh", fetch: fetch)

        XCTAssertEqual(result.exitCode, .drift)
        let object = try jsonObject(result.standardOutput)
        let profiles = try XCTUnwrap(object["profiles"] as? [[String: Any]])
        XCTAssertEqual(profiles[0]["status"] as? String, "updated")
        XCTAssertEqual(profiles[1]["status"] as? String, "failed")
        let write = try XCTUnwrap(object["write"] as? [String: Any])
        XCTAssertEqual((write["error"] as? [String: Any])?["code"] as? String, "hosts-drift")
    }

    // MARK: - Fetch failures

    func testAPartialSourceFailureExitsOneWithPerProfileResults() async throws {
        try makeWorkspace(includeSecondRemote: true)
        let fetch = FetchStub()
        fetch.set(remoteURL, .success(.content("2.2.2.2 one.example.com\n", validators: nil)))
        fetch.set(otherURL, .failure(RemoteFetchError.httpStatus(500)))

        let result = await invoke("--json", "refresh", fetch: fetch)

        XCTAssertEqual(result.exitCode, .failure)
        let profiles = try XCTUnwrap(try jsonObject(result.standardOutput)["profiles"] as? [[String: Any]])
        XCTAssertEqual(profiles[0]["status"] as? String, "updated")
        XCTAssertEqual(profiles[1]["status"] as? String, "failed")
        let error = try XCTUnwrap(profiles[1]["error"] as? [String: Any])
        XCTAssertEqual(error["code"] as? String, "http-status")
        let persisted = try reloadModel()
        // The failed source keeps its old content; the failure marker persists.
        XCTAssertEqual(
            RemoteHeader.storedBody(of: persisted.profile(.init("second-id"))!.content),
            "1.1.1.1 two.example.com\n"
        )
        XCTAssertEqual(persisted.profile(.init("second-id"))!.remoteRefreshState?.lastAttemptFailed, true)
    }

    // MARK: - Conditional requests

    func testStoredValidatorsMakeTheFetchConditionalAndA304OnlyAdvancesTheTimestamp() async throws {
        let validators = RemoteContentValidators(etag: "\"v1\"")
        try makeWorkspace(remoteState: RemoteRefreshState(
            lastSuccessAt: recordedSuccessAt,
            lastAttemptFailed: true,
            validators: validators
        ))
        let fetch = FetchStub()
        fetch.set(remoteURL, .success(.notModified(validators: nil)))

        let result = await invoke("--json", "refresh", fetch: fetch)

        XCTAssertEqual(result.exitCode, .success)
        XCTAssertEqual(fetch.sentValidators, [validators])
        let persisted = try XCTUnwrap(try reloadModel().profile(.init("remote-id")))
        XCTAssertEqual(RemoteHeader.storedBody(of: persisted.content), "1.1.1.1 one.example.com\n")
        let state = try XCTUnwrap(persisted.remoteRefreshState)
        XCTAssertEqual(state.lastAttemptFailed, false)
        XCTAssertEqual(state.validators, validators)
        XCTAssertNotEqual(state.lastSuccessAt, recordedSuccessAt, "the 304 advances the success time")
    }

    // MARK: - Concurrent writers

    func testAConcurrentRefreshMidFetchWinsOverTheOlderResponse() async throws {
        try makeWorkspace()
        let fetch = FetchStub()
        let root: URL = workspaceRootDirectory
        let foreignSuccessAt = recordedSuccessAt.addingTimeInterval(300)
        let foreignContent = RemoteHeader(sourceURL: remoteURL, interval: .oneHour)!
            .storedContent(forFetched: "3.3.3.3 newer.example.com\n")
        fetch.setBeforeFetch {
            let workspace = Workspace(rootDirectory: root)
            var model = try workspace.openReadOnly()
            try model.updateProfileContent(.init("remote-id"), content: foreignContent)
            try model.recordRemoteRefreshSuccess(.init("remote-id"), at: foreignSuccessAt)
            try workspace.save(model)
        }
        fetch.set(remoteURL, .success(.content("2.2.2.2 stale.example.com\n", validators: nil)))

        let result = await invoke("--json", "refresh", fetch: fetch)

        XCTAssertEqual(result.exitCode, .success, "a dropped stale result is not a source failure")
        let profiles = try XCTUnwrap(try jsonObject(result.standardOutput)["profiles"] as? [[String: Any]])
        XCTAssertEqual(profiles[0]["status"] as? String, "stale")
        let persisted = try XCTUnwrap(try reloadModel().profile(.init("remote-id")))
        XCTAssertEqual(RemoteHeader.storedBody(of: persisted.content), "3.3.3.3 newer.example.com\n")
        XCTAssertEqual(persisted.remoteRefreshState?.lastSuccessAt, foreignSuccessAt)
    }

    func testASameSecondConcurrentRefreshIsStillDetectedAsStale() async throws {
        // The manifest stores whole seconds: a peer refresh landing within the same second
        // leaves lastSuccessAt equal, so the stored body is what marks this response stale.
        try makeWorkspace()
        let fetch = FetchStub()
        let root: URL = workspaceRootDirectory
        let foreignContent = RemoteHeader(sourceURL: remoteURL, interval: .oneHour)!
            .storedContent(forFetched: "3.3.3.3 newer.example.com\n")
        let sameSecond = recordedSuccessAt
        fetch.setBeforeFetch {
            let workspace = Workspace(rootDirectory: root)
            var model = try workspace.openReadOnly()
            try model.updateProfileContent(.init("remote-id"), content: foreignContent)
            try model.recordRemoteRefreshSuccess(.init("remote-id"), at: sameSecond)
            try workspace.save(model)
        }
        fetch.set(remoteURL, .success(.content("2.2.2.2 stale.example.com\n", validators: nil)))

        let result = await invoke("--json", "refresh", fetch: fetch)

        let profiles = try XCTUnwrap(try jsonObject(result.standardOutput)["profiles"] as? [[String: Any]])
        XCTAssertEqual(profiles[0]["status"] as? String, "stale")
        XCTAssertEqual(
            RemoteHeader.storedBody(of: try reloadModel().profile(.init("remote-id"))!.content),
            "3.3.3.3 newer.example.com\n"
        )
    }

    func testAnUnavailableDaemonOutranksAPartialSourceFailure() async throws {
        try makeWorkspace(activeRemote: true, includeSecondRemote: true)
        let merger = MergerStub(script: [{ _ in throw DaemonChannelError.unavailable }])
        let fetch = FetchStub()
        fetch.set(remoteURL, .success(.content("2.2.2.2 one.example.com\n", validators: nil)))
        fetch.set(otherURL, .failure(RemoteFetchError.httpStatus(500)))

        let result = await invoke("--json", "refresh", fetch: fetch, merger: merger)

        XCTAssertEqual(result.exitCode, .daemonUnavailable)
        let object = try jsonObject(result.standardOutput)
        XCTAssertEqual(
            (object["profiles"] as? [[String: Any]])?.last?["status"] as? String, "failed"
        )
        XCTAssertEqual(
            ((object["write"] as? [String: Any])?["error"] as? [String: Any])?["code"] as? String,
            "daemon-unavailable"
        )
    }

    // MARK: - Addressing

    func testRefreshingOneTargetByNameAndByID() async throws {
        try makeWorkspace(includeSecondRemote: true)
        let fetch = FetchStub()
        fetch.set(remoteURL, .success(.content("2.2.2.2 one.example.com\n", validators: nil)))

        let byName = await invoke("refresh", "Remote", fetch: fetch)
        XCTAssertEqual(byName.exitCode, .success)
        XCTAssertTrue(byName.standardOutput.hasPrefix("Refreshed 1 of 1 remote profile.\n"))

        let byID = await invoke("refresh", "--id", "remote-id", fetch: fetch)
        XCTAssertEqual(byID.exitCode, .success)
        // The second remote was never fetched: only the target refreshes.
        XCTAssertTrue(fetch.requestedURLs.allSatisfy { $0 == remoteURL })
    }

    func testANonRemoteTargetFailsWithAStableCode() async throws {
        try makeWorkspace()
        let result = await invoke("--json", "refresh", "Solo", fetch: FetchStub())

        XCTAssertEqual(result.exitCode, .failure)
        let details = try XCTUnwrap(try jsonObject(result.standardError)["error"] as? [String: Any])
        XCTAssertEqual(details["code"] as? String, "profile-not-remote")
    }

    func testAMissingTargetExitsFive() async throws {
        try makeWorkspace()
        let result = await invoke("refresh", "Nope", fetch: FetchStub())

        XCTAssertEqual(result.exitCode, .notFound)
    }

    func testAnAmbiguousNameExitsSixWithCandidates() async throws {
        try makeAmbiguousWorkspace()
        let result = await invoke("--json", "refresh", "Dup", fetch: FetchStub())

        XCTAssertEqual(result.exitCode, .ambiguous)
        let details = try XCTUnwrap(try jsonObject(result.standardError)["error"] as? [String: Any])
        XCTAssertEqual(details["code"] as? String, "profile-ambiguous")
        XCTAssertEqual((details["candidates"] as? [[String: Any]])?.count, 2)
    }

    func testASecondPositionalArgumentIsAUsageError() async throws {
        try makeWorkspace()
        let result = await invoke("refresh", "Remote", "Extra", fetch: FetchStub())

        XCTAssertEqual(result.exitCode, .usage)
    }

    // MARK: - Change notification

    func testRefreshPostsOneWorkspaceChangeNotificationAfterSaving() async throws {
        try makeWorkspace()
        let fetch = FetchStub()
        fetch.set(remoteURL, .success(.content("2.2.2.2 one.example.com\n", validators: nil)))
        let spy = WorkspaceChangeSpy()

        let result = await invoke("refresh", fetch: fetch, spy: spy)

        XCTAssertEqual(result.exitCode, .success)
        XCTAssertEqual(spy.postCount, 1)
    }

    // MARK: - Doubles

    /// Canned conditional-fetch outcomes keyed by Source URL, recording the validators each
    /// fetch sent and supporting a one-shot pre-fetch side effect (a racing peer writer);
    /// @unchecked because access is locked.
    private final class FetchStub: @unchecked Sendable {
        private let lock = NSLock()
        private var results: [URL: Result<RemoteFetchOutcome, any Error>] = [:]
        private var received: [RemoteContentValidators?] = []
        private var urls: [URL] = []
        private var beforeFetch: (@Sendable () throws -> Void)?

        var sentValidators: [RemoteContentValidators?] { lock.withLock { received } }
        var requestedURLs: [URL] { lock.withLock { urls } }

        func set(_ url: URL, _ result: Result<RemoteFetchOutcome, any Error>) {
            lock.withLock { results[url] = result }
        }

        func setBeforeFetch(_ effect: @escaping @Sendable () throws -> Void) {
            lock.withLock { beforeFetch = effect }
        }

        func fetch(_ url: URL, sending validators: RemoteContentValidators?) throws -> RemoteFetchOutcome {
            let (effect, result) = lock.withLock { () -> (
                (@Sendable () throws -> Void)?, Result<RemoteFetchOutcome, any Error>?
            ) in
                received.append(validators)
                urls.append(url)
                defer { beforeFetch = nil }
                return (beforeFetch, results[url])
            }
            try effect?()
            guard let result else { throw RemoteFetchError.httpStatus(599) }
            return try result.get()
        }
    }

    /// Scripted stand-in for the daemon channel seam, mirroring SwitchCommandTests' stub.
    private final class MergerStub: HostsMerging, @unchecked Sendable {
        struct Request {
            let merged: MergedHosts
            let mergeID: UUID
            let isInterruptedRetry: Bool
        }

        private let lock = NSLock()
        private var script: [(MergedHosts) throws -> String]
        private var requests: [Request] = []

        init(script: [(MergedHosts) throws -> String] = []) {
            self.script = script
        }

        func merge(_ merged: MergedHosts, mergeID: UUID, isInterruptedRetry: Bool) async throws -> String {
            let reply = lock.withLock {
                requests.append(Request(merged: merged, mergeID: mergeID, isInterruptedRetry: isInterruptedRetry))
                return script.isEmpty ? { $0.hash } : script.removeFirst()
            }
            return try reply(merged)
        }

        var recordedRequests: [Request] {
            lock.withLock { requests }
        }
    }

    private final class WorkspaceChangeSpy: @unchecked Sendable {
        private let lock = NSLock()
        private var posts = 0

        func record() {
            lock.withLock { posts += 1 }
        }

        var postCount: Int { lock.withLock { posts } }
    }

    // MARK: - Helpers

    private func invoke(
        _ arguments: String...,
        fetch: FetchStub,
        merger: MergerStub = MergerStub(),
        spy: WorkspaceChangeSpy? = nil
    ) async -> CLIResult {
        await CLI.run(
            arguments: arguments,
            workspaceRootDirectory: workspaceRootDirectory,
            systemHostsURL: systemHostsURL,
            makeHostsMerger: { _ in merger },
            fetchRemote: { try fetch.fetch($0, sending: $1) },
            postWorkspaceChanged: { _ in spy?.record() }
        )
    }

    private func reloadModel() throws -> ActivationModel {
        try Workspace(rootDirectory: workspaceRootDirectory).openReadOnly()
    }

    /// One local standalone profile plus (by default) one remote standalone profile whose
    /// stored body matches its Source URL's canned v1 content; a drift-free system hosts file.
    private func makeWorkspace(
        includeRemote: Bool = true,
        activeRemote: Bool = false,
        remoteState: RemoteRefreshState? = nil,
        includeSecondRemote: Bool = false
    ) throws {
        let workspace = Workspace(rootDirectory: workspaceRootDirectory)
        _ = try workspace.open(systemHosts: { capturedHosts })
        var standalone = [Profile(id: .init("solo-id"), name: "Solo", content: "# solo")]
        if includeRemote {
            standalone.append(Profile(
                id: .init("remote-id"),
                name: "Remote",
                content: RemoteHeader(sourceURL: remoteURL, interval: .oneHour)!
                    .storedContent(forFetched: "1.1.1.1 one.example.com\n"),
                remoteRefreshState: remoteState ?? RemoteRefreshState(lastSuccessAt: recordedSuccessAt)
            ))
        }
        var groups: [HostflipCore.Group] = []
        if includeSecondRemote {
            groups.append(Group(id: .init("work-id"), name: "Work", profiles: [
                Profile(
                    id: .init("second-id"),
                    name: "Second",
                    content: RemoteHeader(sourceURL: otherURL, interval: .manual)!
                        .storedContent(forFetched: "1.1.1.1 two.example.com\n"),
                    remoteRefreshState: RemoteRefreshState(lastSuccessAt: recordedSuccessAt)
                ),
            ]))
        }
        let model = try ActivationModel(
            baseHosts: BaseHosts(content: capturedHosts),
            standaloneProfiles: standalone,
            groups: groups,
            activeProfileIDs: activeRemote ? [.init("remote-id")] : []
        )
        try workspace.save(model)
        try Data(capturedHosts.utf8).write(to: systemHostsURL)
    }

    /// Two remote profiles both named "Dup": a standalone one and a group member.
    private func makeAmbiguousWorkspace() throws {
        let workspace = Workspace(rootDirectory: workspaceRootDirectory)
        _ = try workspace.open(systemHosts: { capturedHosts })
        let model = try ActivationModel(
            baseHosts: BaseHosts(content: capturedHosts),
            standaloneProfiles: [Profile(
                id: .init("dup-solo-id"),
                name: "Dup",
                content: RemoteHeader(sourceURL: remoteURL, interval: .oneHour)!
                    .storedContent(forFetched: "1.1.1.1 one.example.com\n")
            )],
            groups: [Group(id: .init("work-id"), name: "Work", profiles: [
                Profile(
                    id: .init("dup-work-id"),
                    name: "Dup",
                    content: RemoteHeader(sourceURL: otherURL, interval: .oneHour)!
                        .storedContent(forFetched: "1.1.1.1 two.example.com\n")
                ),
            ])]
        )
        try workspace.save(model)
        try Data(capturedHosts.utf8).write(to: systemHostsURL)
    }

    private func jsonObject(_ text: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }
}
