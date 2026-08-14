import Foundation
import HostflipCore
import HostflipXPC
import XCTest
@testable import HostflipCLI

/// The activation commands (activate / deactivate / pause / resume) against a scripted stand-in
/// of the daemon channel seam: success, drift, daemon-not-ready, addressing failures, and the
/// cross-process persistence contract.
final class SwitchCommandTests: XCTestCase {
    private var rootDirectory: URL!
    private var workspaceRootDirectory: URL!
    private var systemHostsURL: URL!

    private let capturedHosts = "127.0.0.1 localhost\n"

    override func setUpWithError() throws {
        rootDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("hostflip-switch-tests-\(UUID().uuidString)", isDirectory: true)
        workspaceRootDirectory = rootDirectory.appendingPathComponent("workspace", isDirectory: true)
        systemHostsURL = rootDirectory.appendingPathComponent("hosts")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: rootDirectory)
    }

    // MARK: - activate

    func testActivateMergesThePreviewAndPersistsTheState() async throws {
        try makeInitializedWorkspace()
        let merger = MergerStub()

        let result = await invoke("activate", "Solo", merger: merger)

        XCTAssertEqual(result.exitCode, .success)
        XCTAssertEqual(result.standardError, "")
        XCTAssertEqual(result.standardOutput, "Activated Solo.\n")
        let requests = merger.recordedRequests
        XCTAssertEqual(requests.count, 1)
        XCTAssertTrue(requests[0].merged.content.contains("# solo"))
        XCTAssertTrue(requests[0].merged.content.contains(MergedHosts.appendedBlockBegin))
        let persisted = try reloadModel()
        XCTAssertTrue(persisted.activeProfileIDs.contains(.init("solo-id")))
        XCTAssertTrue(persisted.activeProfileIDs.contains(.init("dev-id")), "unrelated active state is kept")
    }

    func testActivateJSONReportsTheResolvedProfileAndTheChange() async throws {
        try makeInitializedWorkspace()

        let result = await invoke("--json", "activate", "Solo", merger: MergerStub())

        XCTAssertEqual(result.exitCode, .success)
        let object = try jsonObject(result.standardOutput)
        XCTAssertEqual(object["action"] as? String, "activate")
        XCTAssertEqual(object["id"] as? String, "solo-id")
        XCTAssertEqual(object["name"] as? String, "Solo")
        XCTAssertNil(object["group"])
        XCTAssertEqual(object["changed"] as? Bool, true)
    }

    func testActivateAnAlreadyActiveProfileIsAnIdempotentNoOp() async throws {
        try makeInitializedWorkspace()
        let merger = MergerStub()
        let spy = WorkspaceChangeSpy()

        let result = await invoke("--json", "activate", "Work/Dev", merger: merger, onWorkspaceChanged: spy)

        XCTAssertEqual(result.exitCode, .success)
        XCTAssertEqual(try jsonObject(result.standardOutput)["changed"] as? Bool, false)
        XCTAssertEqual(merger.recordedRequests.count, 0, "an unchanged state never touches the daemon")
        XCTAssertEqual(spy.postCount, 0, "no write, no change notification")
    }

    func testActivateAGroupMemberDeactivatesTheActiveSibling() async throws {
        try makeInitializedWorkspace()
        let merger = MergerStub()

        let result = await invoke("activate", "Work/Staging", merger: merger)

        XCTAssertEqual(result.exitCode, .success)
        let merged = merger.recordedRequests[0].merged.content
        XCTAssertTrue(merged.contains("# staging"))
        XCTAssertFalse(merged.contains("# dev"), "in-group mutual exclusion applies to the merge preview")
        let persisted = try reloadModel()
        XCTAssertTrue(persisted.activeProfileIDs.contains(.init("staging-id")))
        XCTAssertFalse(persisted.activeProfileIDs.contains(.init("dev-id")))
    }

    func testActivateWhilePausedWritesBaseHostsOnlyButRecordsTheState() async throws {
        try makeInitializedWorkspace(paused: true)
        let merger = MergerStub()

        let result = await invoke("activate", "Solo", merger: merger)

        XCTAssertEqual(result.exitCode, .success)
        XCTAssertEqual(merger.recordedRequests[0].merged.content, capturedHosts)
        let persisted = try reloadModel()
        XCTAssertTrue(persisted.isPaused)
        XCTAssertTrue(persisted.activeProfileIDs.contains(.init("solo-id")))
    }

    // MARK: - deactivate

    func testDeactivateMergesWithoutTheProfileAndPersists() async throws {
        try makeInitializedWorkspace()
        let merger = MergerStub()

        let result = await invoke("deactivate", "Work/Dev", merger: merger)

        XCTAssertEqual(result.exitCode, .success)
        XCTAssertEqual(result.standardOutput, "Deactivated Work/Dev.\n")
        // Dev was the only active profile, so the merge preview is Base Hosts alone: no fence.
        XCTAssertEqual(merger.recordedRequests[0].merged.content, capturedHosts)
        XCTAssertFalse(try reloadModel().activeProfileIDs.contains(.init("dev-id")))
    }

    func testDeactivateAnInactiveProfileIsAnIdempotentNoOp() async throws {
        try makeInitializedWorkspace()
        let merger = MergerStub()

        let result = await invoke("deactivate", "Solo", merger: merger)

        XCTAssertEqual(result.exitCode, .success)
        XCTAssertEqual(result.standardOutput, "Solo is not active.\n")
        XCTAssertEqual(merger.recordedRequests.count, 0)
    }

    // MARK: - pause / resume

    func testPauseWritesBaseHostsOnlyAndKeepsEveryActiveProfile() async throws {
        try makeInitializedWorkspace()
        let merger = MergerStub()

        let result = await invoke("pause", merger: merger)

        XCTAssertEqual(result.exitCode, .success)
        XCTAssertEqual(result.standardOutput, "Paused. The system hosts now carries Base Hosts only.\n")
        XCTAssertEqual(merger.recordedRequests[0].merged.content, capturedHosts)
        let persisted = try reloadModel()
        XCTAssertTrue(persisted.isPaused)
        XCTAssertTrue(persisted.activeProfileIDs.contains(.init("dev-id")), "pausing preserves active state")
    }

    func testResumeRestoresTheKeptActiveProfilesIntoTheMerge() async throws {
        try makeInitializedWorkspace(paused: true)
        let merger = MergerStub()

        let result = await invoke("resume", merger: merger)

        XCTAssertEqual(result.exitCode, .success)
        XCTAssertTrue(merger.recordedRequests[0].merged.content.contains("# dev"))
        XCTAssertFalse(try reloadModel().isPaused)
    }

    func testPauseWhenAlreadyPausedIsAnIdempotentNoOp() async throws {
        try makeInitializedWorkspace(paused: true)
        let merger = MergerStub()

        let result = await invoke("--json", "pause", merger: merger)

        XCTAssertEqual(result.exitCode, .success)
        XCTAssertEqual(try jsonObject(result.standardOutput)["changed"] as? Bool, false)
        XCTAssertEqual(merger.recordedRequests.count, 0)
    }

    func testResumeWhenRunningIsAnIdempotentNoOp() async throws {
        try makeInitializedWorkspace()
        let merger = MergerStub()

        let result = await invoke("resume", merger: merger)

        XCTAssertEqual(result.exitCode, .success)
        XCTAssertEqual(result.standardOutput, "Not paused.\n")
        XCTAssertEqual(merger.recordedRequests.count, 0)
    }

    func testPauseWithAnArgumentFailsWithUsageExitCode() async throws {
        let result = await invoke("pause", "Dev", merger: MergerStub())

        XCTAssertEqual(result.exitCode, .usage)
        XCTAssertTrue(result.standardError.contains("unexpected argument 'Dev'"))
    }

    // MARK: - Aliases

    func testOnAliasActivatesButReportsTheCanonicalAction() async throws {
        try makeInitializedWorkspace()

        let result = await invoke("--json", "on", "Solo", merger: MergerStub())

        XCTAssertEqual(result.exitCode, .success)
        XCTAssertEqual(try jsonObject(result.standardOutput)["action"] as? String, "activate")
        XCTAssertTrue(try reloadModel().activeProfileIDs.contains(.init("solo-id")))
    }

    func testOffAliasDeactivates() async throws {
        try makeInitializedWorkspace()

        let result = await invoke("off", "Work/Dev", merger: MergerStub())

        XCTAssertEqual(result.exitCode, .success)
        XCTAssertFalse(try reloadModel().activeProfileIDs.contains(.init("dev-id")))
    }

    func testBareOnFailsWithUsageExitCode() async throws {
        try makeInitializedWorkspace()
        let merger = MergerStub()

        let result = await invoke("on", merger: merger)

        XCTAssertEqual(result.exitCode, .usage)
        XCTAssertTrue(result.standardError.contains("'on' needs a profile name"))
        XCTAssertEqual(merger.recordedRequests.count, 0)
    }

    func testBareOffFailsWithUsageExitCodeInsteadOfActingAsPause() async throws {
        try makeInitializedWorkspace()
        let merger = MergerStub()

        let result = await invoke("off", merger: merger)

        XCTAssertEqual(result.exitCode, .usage)
        XCTAssertTrue(result.standardError.contains("'off' needs a profile name"))
        XCTAssertEqual(merger.recordedRequests.count, 0)
        XCTAssertFalse(try reloadModel().isPaused, "a bare 'off' must never pause")
    }

    func testHelpShowsTheCanonicalVerbsButNotTheAliases() {
        let commandLines = CLI.usageText
            .split(separator: "\n")
            .filter { $0.hasPrefix("  ") }
            .map { $0.split(separator: " ", omittingEmptySubsequences: true).first.map(String.init) }
        for verb in ["activate", "deactivate", "pause", "resume"] {
            XCTAssertTrue(commandLines.contains(verb), "help must list '\(verb)'")
        }
        for alias in ["on", "off"] {
            XCTAssertFalse(commandLines.contains(alias), "help must not list the '\(alias)' alias")
        }
    }

    // MARK: - Drift (exit code 3)

    func testActivateWithLocalDriftRefusesBeforeTouchingTheDaemon() async throws {
        try makeInitializedWorkspace()
        try Data("tampered\n".utf8).write(to: systemHostsURL)
        let merger = MergerStub()

        let result = await invoke("activate", "Solo", merger: merger)

        XCTAssertEqual(result.exitCode, .drift)
        XCTAssertEqual(result.standardOutput, "")
        XCTAssertTrue(result.standardError.contains("reconcile in the Hostflip app"))
        XCTAssertEqual(merger.recordedRequests.count, 0, "the CLI reports drift, it never merges over it")
        XCTAssertFalse(try reloadModel().activeProfileIDs.contains(.init("solo-id")))
    }

    func testLocalDriftJSONErrorCarriesTheHostsDriftCode() async throws {
        try makeInitializedWorkspace()
        try Data("tampered\n".utf8).write(to: systemHostsURL)

        let result = await invoke("--json", "activate", "Solo", merger: MergerStub())

        XCTAssertEqual(result.exitCode, .drift)
        let details = try XCTUnwrap(try jsonObject(result.standardError)["error"] as? [String: Any])
        XCTAssertEqual(details["code"] as? String, "hosts-drift")
    }

    func testDriftBeatsTheIdempotentNoOpForActivate() async throws {
        try makeInitializedWorkspace()
        try Data("tampered\n".utf8).write(to: systemHostsURL)
        let merger = MergerStub()

        // Dev is already active per the manifest, but under drift the actual hosts content is
        // unknown — "already active" would vouch for a state the CLI cannot see, so the drift
        // verdict (stop, hand back to a human) must win over the no-op.
        let result = await invoke("activate", "Work/Dev", merger: merger)

        XCTAssertEqual(result.exitCode, .drift)
        XCTAssertEqual(merger.recordedRequests.count, 0)
    }

    func testDriftBeatsTheIdempotentNoOpForPause() async throws {
        try makeInitializedWorkspace(paused: true)
        try Data("tampered\n".utf8).write(to: systemHostsURL)

        let result = await invoke("pause", merger: MergerStub())

        XCTAssertEqual(result.exitCode, .drift)
    }

    func testADaemonDriftRejectionAlsoExitsThreeWithoutPersisting() async throws {
        try makeInitializedWorkspace()
        let merger = MergerStub(script: [{ _ in
            throw DaemonChannelError.mergeRejected(.hostsDrift(expected: "a", actual: "b"))
        }])

        let result = await invoke("--json", "activate", "Solo", merger: merger)

        XCTAssertEqual(result.exitCode, .drift)
        let details = try XCTUnwrap(try jsonObject(result.standardError)["error"] as? [String: Any])
        XCTAssertEqual(details["code"] as? String, "hosts-drift")
        XCTAssertFalse(try reloadModel().activeProfileIDs.contains(.init("solo-id")))
    }

    // MARK: - Daemon not ready (exit code 4)

    func testAnUnavailableDaemonExitsFourWithoutPersisting() async throws {
        try makeInitializedWorkspace()
        let merger = MergerStub(script: [{ _ in throw DaemonChannelError.unavailable }])
        let spy = WorkspaceChangeSpy()

        let result = await invoke("--json", "activate", "Solo", merger: merger, onWorkspaceChanged: spy)

        XCTAssertEqual(result.exitCode, .daemonUnavailable)
        let details = try XCTUnwrap(try jsonObject(result.standardError)["error"] as? [String: Any])
        XCTAssertEqual(details["code"] as? String, "daemon-unavailable")
        XCTAssertFalse(try reloadModel().activeProfileIDs.contains(.init("solo-id")))
        XCTAssertEqual(spy.postCount, 0)
    }

    func testAnInterruptedMergeIsRetriedOnceWithTheSameMergeID() async throws {
        try makeInitializedWorkspace()
        let merger = MergerStub(script: [
            { _ in throw DaemonChannelError.interrupted },
            { $0.hash },
        ])

        let result = await invoke("activate", "Solo", merger: merger)

        XCTAssertEqual(result.exitCode, .success)
        let requests = merger.recordedRequests
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests[0].mergeID, requests[1].mergeID, "the retry replays the same logical merge")
        XCTAssertEqual(requests.map(\.isInterruptedRetry), [false, true])
        XCTAssertTrue(try reloadModel().activeProfileIDs.contains(.init("solo-id")))
    }

    func testASecondInterruptionExitsFour() async throws {
        try makeInitializedWorkspace()
        let merger = MergerStub(script: [
            { _ in throw DaemonChannelError.interrupted },
            { _ in throw DaemonChannelError.interrupted },
        ])

        let result = await invoke("activate", "Solo", merger: merger)

        XCTAssertEqual(result.exitCode, .daemonUnavailable)
        XCTAssertEqual(merger.recordedRequests.count, 2, "exactly one retry")
    }

    // MARK: - Addressing failures

    func testActivateAnUnknownProfileExitsFiveWithoutTouchingTheDaemon() async throws {
        try makeInitializedWorkspace()
        let merger = MergerStub()

        let result = await invoke("--json", "activate", "Missing", merger: merger)

        XCTAssertEqual(result.exitCode, .notFound)
        let details = try XCTUnwrap(try jsonObject(result.standardError)["error"] as? [String: Any])
        XCTAssertEqual(details["code"] as? String, "profile-not-found")
        XCTAssertEqual(merger.recordedRequests.count, 0)
    }

    func testActivateAnAmbiguousNameExitsSixListingTheCandidates() async throws {
        try makeAmbiguousWorkspace()
        let merger = MergerStub()

        let result = await invoke("--json", "activate", "Dev", merger: merger)

        XCTAssertEqual(result.exitCode, .ambiguous)
        let details = try XCTUnwrap(try jsonObject(result.standardError)["error"] as? [String: Any])
        XCTAssertEqual(details["code"] as? String, "profile-ambiguous")
        let candidates = try XCTUnwrap(details["candidates"] as? [[String: Any]])
        XCTAssertEqual(candidates.map { $0["id"] as? String }, ["solo-dev-id", "work-dev-id"])
        XCTAssertEqual(merger.recordedRequests.count, 0)
    }

    func testActivateByIDBypassesTheAmbiguousName() async throws {
        try makeAmbiguousWorkspace()

        let result = await invoke("activate", "--id", "solo-dev-id", merger: MergerStub())

        XCTAssertEqual(result.exitCode, .success)
        XCTAssertTrue(try reloadModel().activeProfileIDs.contains(.init("solo-dev-id")))
    }

    // MARK: - Cross-process persistence (ADR-0010)

    func testTheChangeNotificationFiresAfterTheStateIsPersisted() async throws {
        try makeInitializedWorkspace()
        let spy = WorkspaceChangeSpy()

        let result = await invoke("activate", "Solo", merger: MergerStub(), onWorkspaceChanged: spy)

        XCTAssertEqual(result.exitCode, .success)
        XCTAssertEqual(spy.postCount, 1)
        XCTAssertEqual(
            spy.observedActiveIDs.first?.contains("solo-id"),
            true,
            "at post time the manifest must already carry the switched state"
        )
    }

    func testAConcurrentExternalEditSurvivesTheSwitchPersistence() async throws {
        try makeInitializedWorkspace()
        let workspace = Workspace(rootDirectory: workspaceRootDirectory)
        // A peer writer (the GUI) adds a profile while the daemon call is in flight; the
        // reload-and-replay save must keep it (ADR-0010 ②).
        let merger = MergerStub(script: [{ merged in
            _ = try workspace.save(applying: {
                try $0.addProfile(id: .init("injected-id"), name: "Injected", content: "# injected")
            })
            return merged.hash
        }])

        let result = await invoke("activate", "Solo", merger: merger)

        XCTAssertEqual(result.exitCode, .success)
        let persisted = try reloadModel()
        XCTAssertTrue(persisted.standaloneProfiles.contains { $0.id == .init("injected-id") })
        XCTAssertTrue(persisted.activeProfileIDs.contains(.init("solo-id")))
    }

    // MARK: - Landed write with a failed flush

    func testAFlushFailureAfterALandedWriteStillPersistsTheSwitch() async throws {
        try makeInitializedWorkspace()
        let workspace = Workspace(rootDirectory: workspaceRootDirectory)
        let merger = MergerStub(script: [{ merged in
            throw DaemonChannelError.mergeWriteFailed(
                HostsWriteError(stage: .flushDNS, message: "boom", writtenHash: merged.hash)
            )
        }])
        let spy = WorkspaceChangeSpy()

        let result = await invoke("--json", "activate", "Solo", merger: merger, onWorkspaceChanged: spy)

        // The replacement physically landed, so the switch is committed and the baseline hash
        // recorded — not committing would misreport the very next status as drift.
        XCTAssertEqual(result.exitCode, .failure)
        let details = try XCTUnwrap(try jsonObject(result.standardError)["error"] as? [String: Any])
        XCTAssertEqual(details["code"] as? String, "dns-flush-failed")
        let persisted = try reloadModel()
        XCTAssertTrue(persisted.activeProfileIDs.contains(.init("solo-id")))
        XCTAssertEqual(try workspace.lastWrittenHash(), merger.recordedRequests[0].merged.hash)
        XCTAssertEqual(spy.postCount, 1)
    }

    func testAFailedReplacementDoesNotPersistAnything() async throws {
        try makeInitializedWorkspace()
        let workspace = Workspace(rootDirectory: workspaceRootDirectory)
        let merger = MergerStub(script: [{ _ in
            throw DaemonChannelError.mergeWriteFailed(
                HostsWriteError(stage: .replace, message: "boom", writtenHash: nil)
            )
        }])

        let result = await invoke("--json", "activate", "Solo", merger: merger)

        XCTAssertEqual(result.exitCode, .failure)
        let details = try XCTUnwrap(try jsonObject(result.standardError)["error"] as? [String: Any])
        XCTAssertEqual(details["code"] as? String, "hosts-write-failed")
        XCTAssertFalse(try reloadModel().activeProfileIDs.contains(.init("solo-id")))
        XCTAssertNil(try workspace.lastWrittenHash())
    }

    // MARK: - Doubles

    /// Scripted stand-in for the daemon channel seam: replies (or throws) per call in script
    /// order — an empty script confirms every merge with its own hash — and records every
    /// request for assertions.
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

    /// Records every workspace-change notification post, capturing the on-disk active state at
    /// post time so tests can assert the persist-then-notify ordering.
    private final class WorkspaceChangeSpy: @unchecked Sendable {
        private let lock = NSLock()
        private var observations: [Set<String>] = []

        func record(_ workspace: Workspace) {
            let ids = (try? workspace.openReadOnly())
                .map { Set($0.activeProfileIDs.map(\.rawValue)) } ?? []
            lock.withLock { observations.append(ids) }
        }

        var postCount: Int { lock.withLock { observations.count } }
        var observedActiveIDs: [Set<String>] { lock.withLock { observations } }
    }

    // MARK: - Helpers

    private func invoke(
        _ arguments: String...,
        merger: MergerStub,
        onWorkspaceChanged spy: WorkspaceChangeSpy? = nil
    ) async -> CLIResult {
        await CLI.run(
            arguments: arguments,
            workspaceRootDirectory: workspaceRootDirectory,
            systemHostsURL: systemHostsURL,
            makeHostsMerger: { _ in merger },
            postWorkspaceChanged: { spy?.record($0) }
        )
    }

    private func reloadModel() throws -> ActivationModel {
        try Workspace(rootDirectory: workspaceRootDirectory).openReadOnly()
    }

    /// Same fixture as CLITests: one standalone profile and one two-member group with its first
    /// profile active, plus a matching (drift-free) system hosts file.
    private func makeInitializedWorkspace(paused: Bool = false) throws {
        let workspace = Workspace(rootDirectory: workspaceRootDirectory)
        _ = try workspace.open(systemHosts: { capturedHosts })
        let model = try ActivationModel(
            baseHosts: BaseHosts(content: capturedHosts),
            standaloneProfiles: [Profile(id: .init("solo-id"), name: "Solo", content: "# solo")],
            groups: [
                Group(id: .init("work-id"), name: "Work", profiles: [
                    Profile(id: .init("dev-id"), name: "Dev", content: "# dev"),
                    Profile(id: .init("staging-id"), name: "Staging", content: "# staging"),
                ]),
            ],
            activeProfileIDs: [.init("dev-id")],
            isPaused: paused
        )
        try workspace.save(model)
        try Data(capturedHosts.utf8).write(to: systemHostsURL)
    }

    /// A workspace where the bare name "Dev" is ambiguous between a standalone profile and a
    /// group member, with a matching system hosts file so switches pass the drift gate.
    private func makeAmbiguousWorkspace() throws {
        let workspace = Workspace(rootDirectory: workspaceRootDirectory)
        _ = try workspace.open(systemHosts: { capturedHosts })
        let model = try ActivationModel(
            baseHosts: BaseHosts(content: capturedHosts),
            standaloneProfiles: [Profile(id: .init("solo-dev-id"), name: "Dev", content: "# solo dev")],
            groups: [
                Group(id: .init("work-id"), name: "Work", profiles: [
                    Profile(id: .init("work-dev-id"), name: "Dev", content: "# work dev"),
                ]),
            ]
        )
        try workspace.save(model)
        try Data(capturedHosts.utf8).write(to: systemHostsURL)
    }

    private func jsonObject(_ text: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }
}
