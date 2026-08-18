import Foundation
import HostflipCore
import HostflipXPC
import XCTest
@testable import HostflipCLI

/// The content commands (create / write / delete): creation addressing and its duplicate-name
/// rejection, whole-content replacement from stdin or --file with syntax validation, and the
/// merge-before-remove discipline for deleting an active profile.
final class ContentCommandTests: XCTestCase {
    private var rootDirectory: URL!
    private var workspaceRootDirectory: URL!
    private var systemHostsURL: URL!

    private let capturedHosts = "127.0.0.1 localhost\n"

    override func setUpWithError() throws {
        rootDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("hostflip-content-tests-\(UUID().uuidString)", isDirectory: true)
        workspaceRootDirectory = rootDirectory.appendingPathComponent("workspace", isDirectory: true)
        systemHostsURL = rootDirectory.appendingPathComponent("hosts")
        try FileManager.default.createDirectory(at: rootDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: rootDirectory)
    }

    // MARK: - create

    func testCreateMakesAnInactiveEmptyStandaloneProfileByDefault() async throws {
        try makeInitializedWorkspace()
        let merger = MergerStub()
        let spy = WorkspaceChangeSpy()

        let result = await invoke("create", "Fresh", merger: merger, onWorkspaceChanged: spy)

        XCTAssertEqual(result.exitCode, .success)
        XCTAssertEqual(result.standardError, "")
        XCTAssertEqual(result.standardOutput, "Created Fresh.\n")
        let persisted = try reloadModel()
        let fresh = try XCTUnwrap(persisted.standaloneProfiles.first { $0.name == "Fresh" })
        XCTAssertEqual(fresh.content, "", "a CLI-created profile starts empty")
        XCTAssertFalse(persisted.activeProfileIDs.contains(fresh.id))
        XCTAssertEqual(merger.recordedRequests.count, 0, "creating never touches the daemon")
        XCTAssertEqual(spy.postCount, 1)
        XCTAssertEqual(
            spy.observedProfileNames.first?.contains("Fresh"),
            true,
            "at post time the manifest must already carry the new profile"
        )
    }

    func testCreateJSONReportsTheNewProfile() async throws {
        try makeInitializedWorkspace()

        let result = await invoke("--json", "create", "Fresh", merger: MergerStub())

        XCTAssertEqual(result.exitCode, .success)
        let object = try jsonObject(result.standardOutput)
        XCTAssertEqual(object["name"] as? String, "Fresh")
        XCTAssertNil(object["group"])
        let id = try XCTUnwrap(object["id"] as? String)
        XCTAssertTrue(try reloadModel().standaloneProfiles.contains { $0.id.rawValue == id })
    }

    func testCreateWithAGroupPathLandsInThatGroup() async throws {
        try makeInitializedWorkspace()

        let result = await invoke("--json", "create", "Work/Fresh", merger: MergerStub())

        XCTAssertEqual(result.exitCode, .success)
        XCTAssertEqual(try jsonObject(result.standardOutput)["group"] as? String, "Work")
        let group = try XCTUnwrap(try reloadModel().groups.first { $0.name == "Work" })
        XCTAssertTrue(group.profiles.contains { $0.name == "Fresh" })
    }

    func testCreateInAMissingGroupExitsFiveWithoutSideEffects() async throws {
        try makeInitializedWorkspace()
        let spy = WorkspaceChangeSpy()

        let result = await invoke("--json", "create", "Missing/Fresh", merger: MergerStub(), onWorkspaceChanged: spy)

        XCTAssertEqual(result.exitCode, .notFound)
        let details = try XCTUnwrap(try jsonObject(result.standardError)["error"] as? [String: Any])
        XCTAssertEqual(details["code"] as? String, "group-not-found")
        XCTAssertFalse(try allProfileNames().contains("Fresh"), "the CLI never auto-creates groups")
        XCTAssertEqual(spy.postCount, 0)
    }

    func testCreateADuplicateStandaloneNameIsRejectedWithoutSideEffects() async throws {
        try makeInitializedWorkspace()
        let spy = WorkspaceChangeSpy()

        let result = await invoke("--json", "create", "Solo", merger: MergerStub(), onWorkspaceChanged: spy)

        XCTAssertEqual(result.exitCode, .failure)
        let details = try XCTUnwrap(try jsonObject(result.standardError)["error"] as? [String: Any])
        XCTAssertEqual(details["code"] as? String, "profile-exists")
        XCTAssertEqual(try reloadModel().standaloneProfiles.count, 1, "a retry must not pollute the addressing space")
        XCTAssertEqual(spy.postCount, 0)
    }

    func testCreateADuplicateNameInsideTheSameGroupIsRejected() async throws {
        try makeInitializedWorkspace()

        let result = await invoke("--json", "create", "Work/Dev", merger: MergerStub())

        XCTAssertEqual(result.exitCode, .failure)
        let details = try XCTUnwrap(try jsonObject(result.standardError)["error"] as? [String: Any])
        XCTAssertEqual(details["code"] as? String, "profile-exists")
        let group = try XCTUnwrap(try reloadModel().groups.first { $0.name == "Work" })
        XCTAssertEqual(group.profiles.filter { $0.name == "Dev" }.count, 1)
    }

    func testCreateTheSameNameInADifferentLocationSucceeds() async throws {
        try makeInitializedWorkspace()

        // "Dev" exists in the Work group; only a namesake in the same location is rejected.
        let result = await invoke("create", "Dev", merger: MergerStub())

        XCTAssertEqual(result.exitCode, .success)
        XCTAssertTrue(try reloadModel().standaloneProfiles.contains { $0.name == "Dev" })
    }

    func testCreateInAnAmbiguousGroupNameExitsSix() async throws {
        try makeDuplicateGroupsWorkspace()

        let result = await invoke("--json", "create", "Work/Fresh", merger: MergerStub())

        XCTAssertEqual(result.exitCode, .ambiguous)
        let details = try XCTUnwrap(try jsonObject(result.standardError)["error"] as? [String: Any])
        XCTAssertEqual(details["code"] as? String, "group-ambiguous")
        XCTAssertFalse(try allProfileNames().contains("Fresh"))
    }

    func testCreateWithAnEmptyPathHalfFailsWithUsageExitCode() async throws {
        try makeInitializedWorkspace()

        // Either half of a group/name path coming out empty is a malformed target, not a
        // lookup miss: usage, never not-found.
        let bare = await invoke("create", "", merger: MergerStub())
        let emptyName = await invoke("create", "Work/", merger: MergerStub())
        let emptyGroup = await invoke("create", "/Fresh", merger: MergerStub())

        XCTAssertEqual(bare.exitCode, .usage)
        XCTAssertEqual(emptyName.exitCode, .usage)
        XCTAssertEqual(emptyGroup.exitCode, .usage)
    }

    func testCreateWithoutANameFailsWithUsageExitCode() async throws {
        let result = await invoke("create", merger: MergerStub())

        XCTAssertEqual(result.exitCode, .usage)
        XCTAssertTrue(result.standardError.contains("'create' needs a profile name"))
    }

    func testCreateRejectsTheIDOption() async throws {
        try makeInitializedWorkspace()

        let result = await invoke("create", "--id", "some-id", "Fresh", merger: MergerStub())

        XCTAssertEqual(result.exitCode, .usage)
        XCTAssertTrue(result.standardError.contains("unexpected option '--id'"))
    }

    // MARK: - write

    func testWriteFromStdinReplacesAnInactiveProfilesContent() async throws {
        try makeInitializedWorkspace()
        let merger = MergerStub()
        let spy = WorkspaceChangeSpy()
        let content = "0.0.0.0 ads.example.com\n"

        let result = await invoke(
            "write", "Solo",
            standardInput: Data(content.utf8),
            merger: merger,
            onWorkspaceChanged: spy
        )

        XCTAssertEqual(result.exitCode, .success)
        XCTAssertEqual(result.standardOutput, "Wrote Solo.\n")
        XCTAssertEqual(try reloadProfile("solo-id").content, content)
        XCTAssertEqual(merger.recordedRequests.count, 0, "an inactive profile is a purely local edit")
        XCTAssertEqual(spy.postCount, 1)
    }

    func testWriteJSONReportsTheResolvedProfileAndTheChange() async throws {
        try makeInitializedWorkspace()

        let result = await invoke(
            "--json", "write", "Solo",
            standardInput: Data("0.0.0.0 ads.example.com\n".utf8),
            merger: MergerStub()
        )

        XCTAssertEqual(result.exitCode, .success)
        let object = try jsonObject(result.standardOutput)
        XCTAssertEqual(object["id"] as? String, "solo-id")
        XCTAssertEqual(object["name"] as? String, "Solo")
        XCTAssertNil(object["group"])
        XCTAssertEqual(object["changed"] as? Bool, true)
    }

    func testWriteFromAFileReplacesContent() async throws {
        try makeInitializedWorkspace()
        let content = "0.0.0.0 tracker.example.com\n"
        let fileURL = rootDirectory.appendingPathComponent("new-content.hosts")
        try Data(content.utf8).write(to: fileURL)

        let result = await invoke("write", "Solo", "--file", fileURL.path, merger: MergerStub())

        XCTAssertEqual(result.exitCode, .success)
        XCTAssertEqual(try reloadProfile("solo-id").content, content)
    }

    func testWriteToAnActiveProfileMergesTheNewContentThenPersists() async throws {
        try makeInitializedWorkspace()
        let workspace = Workspace(rootDirectory: workspaceRootDirectory)
        // At merge time the daemon call sees the new content in the preview while the old
        // content is still what is persisted: the system hosts write lands first.
        let merger = MergerStub(script: [{ merged in
            XCTAssertTrue(merged.content.contains("tracker.example.com"))
            XCTAssertFalse(merged.content.contains("# dev"))
            let persisted = try workspace.openReadOnly()
            XCTAssertEqual(
                persisted.groups.first { $0.name == "Work" }?.profiles.first { $0.name == "Dev" }?.content,
                "# dev"
            )
            return merged.hash
        }])
        let spy = WorkspaceChangeSpy()

        let result = await invoke(
            "write", "Work/Dev",
            standardInput: Data("0.0.0.0 tracker.example.com\n".utf8),
            merger: merger,
            onWorkspaceChanged: spy
        )

        XCTAssertEqual(result.exitCode, .success)
        XCTAssertEqual(merger.recordedRequests.count, 1)
        XCTAssertEqual(try reloadProfile("dev-id").content, "0.0.0.0 tracker.example.com\n")
        XCTAssertEqual(spy.postCount, 1)
    }

    func testWriteInvalidSyntaxIsRejectedLeavingTheContentUntouched() async throws {
        try makeInitializedWorkspace()
        let merger = MergerStub()
        let spy = WorkspaceChangeSpy()

        // Line 2 has an IP address without any hostname.
        let result = await invoke(
            "--json", "write", "Work/Dev",
            standardInput: Data("0.0.0.0 ads.example.com\n127.0.0.1\n".utf8),
            merger: merger,
            onWorkspaceChanged: spy
        )

        XCTAssertEqual(result.exitCode, .failure)
        let details = try XCTUnwrap(try jsonObject(result.standardError)["error"] as? [String: Any])
        XCTAssertEqual(details["code"] as? String, "invalid-hosts-syntax")
        XCTAssertEqual((details["message"] as? String)?.contains("line 2"), true)
        XCTAssertEqual(try reloadProfile("dev-id").content, "# dev", "a rejected write leaves the content untouched")
        XCTAssertEqual(merger.recordedRequests.count, 0)
        XCTAssertEqual(spy.postCount, 0)
    }

    func testWriteToAnActiveProfileUnderDriftExitsThree() async throws {
        try makeInitializedWorkspace()
        try Data("tampered\n".utf8).write(to: systemHostsURL)
        let merger = MergerStub()

        let result = await invoke(
            "write", "Work/Dev",
            standardInput: Data("0.0.0.0 ads.example.com\n".utf8),
            merger: merger
        )

        XCTAssertEqual(result.exitCode, .drift)
        XCTAssertEqual(try reloadProfile("dev-id").content, "# dev")
        XCTAssertEqual(merger.recordedRequests.count, 0)
    }

    func testWriteToAnInactiveProfileUnderDriftIsALocalEditThatSucceeds() async throws {
        try makeInitializedWorkspace()
        try Data("tampered\n".utf8).write(to: systemHostsURL)

        // An inactive profile's content is outside the merged output, so the write never
        // vouches for the system hosts and the drift gate does not apply.
        let result = await invoke(
            "write", "Solo",
            standardInput: Data("0.0.0.0 ads.example.com\n".utf8),
            merger: MergerStub()
        )

        XCTAssertEqual(result.exitCode, .success)
        XCTAssertEqual(try reloadProfile("solo-id").content, "0.0.0.0 ads.example.com\n")
    }

    func testWriteIdenticalContentIsAnIdempotentNoOp() async throws {
        try makeInitializedWorkspace()
        let merger = MergerStub()
        let spy = WorkspaceChangeSpy()

        let result = await invoke(
            "--json", "write", "Work/Dev",
            standardInput: Data("# dev".utf8),
            merger: merger,
            onWorkspaceChanged: spy
        )

        XCTAssertEqual(result.exitCode, .success)
        XCTAssertEqual(try jsonObject(result.standardOutput)["changed"] as? Bool, false)
        XCTAssertEqual(merger.recordedRequests.count, 0, "unchanged content never touches the daemon")
        XCTAssertEqual(spy.postCount, 0, "no write, no change notification")
    }

    func testWriteNonUTF8InputIsRejected() async throws {
        try makeInitializedWorkspace()

        let result = await invoke(
            "--json", "write", "Solo",
            standardInput: Data([0xFF, 0xFE, 0xFD]),
            merger: MergerStub()
        )

        XCTAssertEqual(result.exitCode, .failure)
        let details = try XCTUnwrap(try jsonObject(result.standardError)["error"] as? [String: Any])
        XCTAssertEqual(details["code"] as? String, "invalid-encoding")
        XCTAssertEqual(try reloadProfile("solo-id").content, "# solo")
    }

    func testWriteAnUnreadableFileIsRejected() async throws {
        try makeInitializedWorkspace()

        let result = await invoke(
            "--json", "write", "Solo",
            "--file", rootDirectory.appendingPathComponent("missing.hosts").path,
            merger: MergerStub()
        )

        XCTAssertEqual(result.exitCode, .failure)
        let details = try XCTUnwrap(try jsonObject(result.standardError)["error"] as? [String: Any])
        XCTAssertEqual(details["code"] as? String, "file-unreadable")
        XCTAssertEqual(try reloadProfile("solo-id").content, "# solo")
    }

    func testWriteToARemoteProfileIsRefusedLeavingTheContentUntouched() async throws {
        try makeInitializedWorkspace()
        let workspace = Workspace(rootDirectory: workspaceRootDirectory)
        let remoteContent = "#!hostflip-remote https://example.com/hosts.txt interval=6h\n1.2.3.4 a.example.com\n"
        _ = try workspace.save(applying: {
            try $0.addProfile(id: .init("remote-id"), name: "Remote", content: remoteContent)
        })
        let merger = MergerStub()
        let spy = WorkspaceChangeSpy()

        // Remote content is read-only everywhere (ADR-0012); the CLI must not offer the write
        // path the GUI editor already withholds.
        let result = await invoke(
            "--json", "write", "Remote",
            standardInput: Data("0.0.0.0 ads.example.com\n".utf8),
            merger: merger,
            onWorkspaceChanged: spy
        )

        XCTAssertEqual(result.exitCode, .failure)
        let details = try XCTUnwrap(try jsonObject(result.standardError)["error"] as? [String: Any])
        XCTAssertEqual(details["code"] as? String, "profile-is-remote")
        XCTAssertEqual(try reloadProfile("remote-id").content, remoteContent)
        XCTAssertEqual(merger.recordedRequests.count, 0)
        XCTAssertEqual(spy.postCount, 0)
    }

    func testWriteAnUnknownProfileExitsFive() async throws {
        try makeInitializedWorkspace()

        let result = await invoke(
            "write", "Missing",
            standardInput: Data("0.0.0.0 ads.example.com\n".utf8),
            merger: MergerStub()
        )

        XCTAssertEqual(result.exitCode, .notFound)
    }

    func testTheFileOptionOnAnotherCommandFailsWithUsageExitCode() async throws {
        try makeInitializedWorkspace()

        let result = await invoke("cat", "Solo", "--file", "somewhere", merger: MergerStub())

        XCTAssertEqual(result.exitCode, .usage)
        XCTAssertTrue(result.standardError.contains("--file"))
    }

    func testTheFileOptionWithoutAValueFailsWithUsageExitCode() async throws {
        let result = await invoke("write", "Solo", "--file", merger: MergerStub())

        XCTAssertEqual(result.exitCode, .usage)
        XCTAssertTrue(result.standardError.contains("option '--file' requires a value"))
    }

    // MARK: - delete

    func testDeleteAnInactiveProfileRemovesItLocally() async throws {
        try makeInitializedWorkspace()
        let merger = MergerStub()
        let spy = WorkspaceChangeSpy()

        let result = await invoke("delete", "Solo", merger: merger, onWorkspaceChanged: spy)

        XCTAssertEqual(result.exitCode, .success)
        XCTAssertEqual(result.standardOutput, "Deleted Solo.\n")
        XCTAssertFalse(try allProfileNames().contains("Solo"))
        XCTAssertEqual(merger.recordedRequests.count, 0, "an inactive profile never goes through the daemon")
        XCTAssertEqual(spy.postCount, 1)
        XCTAssertEqual(spy.observedProfileNames.first?.contains("Solo"), false)
    }

    func testDeleteJSONReportsTheRemovedProfile() async throws {
        try makeInitializedWorkspace()

        let result = await invoke("--json", "delete", "Solo", merger: MergerStub())

        XCTAssertEqual(result.exitCode, .success)
        let object = try jsonObject(result.standardOutput)
        XCTAssertEqual(object["id"] as? String, "solo-id")
        XCTAssertEqual(object["name"] as? String, "Solo")
        XCTAssertNil(object["group"])
    }

    func testDeleteAnActiveProfileMergesWithoutItBeforeRemoving() async throws {
        try makeInitializedWorkspace()
        let workspace = Workspace(rootDirectory: workspaceRootDirectory)
        // Dev is the only active profile: the merge preview must be Base Hosts alone, and at
        // merge time the profile must still exist on disk — the exit from the merge lands
        // before the removal does.
        let merger = MergerStub(script: [{ [capturedHosts] merged in
            XCTAssertEqual(merged.content, capturedHosts)
            XCTAssertEqual(
                try workspace.openReadOnly().groups.first { $0.name == "Work" }?.profiles.contains { $0.name == "Dev" },
                true
            )
            return merged.hash
        }])
        let spy = WorkspaceChangeSpy()

        let result = await invoke("delete", "Work/Dev", merger: merger, onWorkspaceChanged: spy)

        XCTAssertEqual(result.exitCode, .success)
        XCTAssertEqual(result.standardOutput, "Deleted Work/Dev.\n")
        XCTAssertEqual(merger.recordedRequests.count, 1)
        let persisted = try reloadModel()
        XCTAssertFalse(try allProfileNames().contains("Dev"))
        XCTAssertFalse(persisted.activeProfileIDs.contains(.init("dev-id")))
        XCTAssertEqual(spy.postCount, 1)
    }

    func testDeleteAnActiveProfileUnderDriftExitsThree() async throws {
        try makeInitializedWorkspace()
        try Data("tampered\n".utf8).write(to: systemHostsURL)
        let merger = MergerStub()

        let result = await invoke("delete", "Work/Dev", merger: merger)

        XCTAssertEqual(result.exitCode, .drift)
        XCTAssertTrue(try allProfileNames().contains("Dev"))
        XCTAssertEqual(merger.recordedRequests.count, 0)
    }

    func testDeleteAnActiveProfileWithAnUnavailableDaemonExitsFourWithoutRemoving() async throws {
        try makeInitializedWorkspace()
        let merger = MergerStub(script: [{ _ in throw DaemonChannelError.unavailable }])
        let spy = WorkspaceChangeSpy()

        let result = await invoke("delete", "Work/Dev", merger: merger, onWorkspaceChanged: spy)

        XCTAssertEqual(result.exitCode, .daemonUnavailable)
        XCTAssertTrue(try allProfileNames().contains("Dev"))
        XCTAssertEqual(spy.postCount, 0)
    }

    func testDeleteAnUnknownProfileExitsFive() async throws {
        try makeInitializedWorkspace()

        let result = await invoke("--json", "delete", "Missing", merger: MergerStub())

        XCTAssertEqual(result.exitCode, .notFound)
        let details = try XCTUnwrap(try jsonObject(result.standardError)["error"] as? [String: Any])
        XCTAssertEqual(details["code"] as? String, "profile-not-found")
    }

    // MARK: - Cross-process persistence (ADR-0010)

    func testAConcurrentExternalEditSurvivesTheWritePersistence() async throws {
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

        let result = await invoke(
            "write", "Work/Dev",
            standardInput: Data("0.0.0.0 tracker.example.com\n".utf8),
            merger: merger
        )

        XCTAssertEqual(result.exitCode, .success)
        let persisted = try reloadModel()
        XCTAssertTrue(persisted.standaloneProfiles.contains { $0.id == .init("injected-id") })
        XCTAssertEqual(try reloadProfile("dev-id").content, "0.0.0.0 tracker.example.com\n")
    }

    func testAPeerDeletingTheProfileMidMergeIsReportedAsASaveConflict() async throws {
        try makeInitializedWorkspace()
        let workspace = Workspace(rootDirectory: workspaceRootDirectory)
        // The peer removes Work/Dev after the merge lands but before the replay commits: the
        // change cannot be recorded, which must be surfaced instead of silently dropped.
        let merger = MergerStub(script: [{ merged in
            _ = try workspace.save(applying: { try $0.deleteProfile(.init("dev-id")) })
            return merged.hash
        }])

        let result = await invoke(
            "--json", "write", "Work/Dev",
            standardInput: Data("0.0.0.0 tracker.example.com\n".utf8),
            merger: merger
        )

        XCTAssertEqual(result.exitCode, .failure)
        let details = try XCTUnwrap(try jsonObject(result.standardError)["error"] as? [String: Any])
        XCTAssertEqual(details["code"] as? String, "state-save-conflict")
    }

    // MARK: - Help

    func testHelpListsTheContentCommands() {
        let commandLines = CLI.usageText
            .split(separator: "\n")
            .filter { $0.hasPrefix("  ") }
            .map { $0.split(separator: " ", omittingEmptySubsequences: true).first.map(String.init) }
        for verb in ["create", "write", "delete"] {
            XCTAssertTrue(commandLines.contains(verb), "help must list '\(verb)'")
        }
    }

    // MARK: - Doubles

    /// Scripted stand-in for the daemon channel seam, same shape as SwitchCommandTests':
    /// replies (or throws) per call in script order — an empty script confirms every merge with
    /// its own hash — and records every request for assertions.
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

    /// Records every workspace-change notification post, capturing the on-disk profile names at
    /// post time so tests can assert the persist-then-notify ordering.
    private final class WorkspaceChangeSpy: @unchecked Sendable {
        private let lock = NSLock()
        private var observations: [Set<String>] = []

        func record(_ workspace: Workspace) {
            let names = (try? workspace.openReadOnly()).map { model in
                Set(model.standaloneProfiles.map(\.name) + model.groups.flatMap { $0.profiles.map(\.name) })
            } ?? []
            lock.withLock { observations.append(names) }
        }

        var postCount: Int { lock.withLock { observations.count } }
        var observedProfileNames: [Set<String>] { lock.withLock { observations } }
    }

    // MARK: - Helpers

    private func invoke(
        _ arguments: String...,
        standardInput: Data = Data(),
        merger: MergerStub,
        onWorkspaceChanged spy: WorkspaceChangeSpy? = nil
    ) async -> CLIResult {
        await CLI.run(
            arguments: arguments,
            workspaceRootDirectory: workspaceRootDirectory,
            systemHostsURL: systemHostsURL,
            makeHostsMerger: { _ in merger },
            postWorkspaceChanged: { spy?.record($0) },
            readStandardInput: { standardInput }
        )
    }

    private func reloadModel() throws -> ActivationModel {
        try Workspace(rootDirectory: workspaceRootDirectory).openReadOnly()
    }

    private func reloadProfile(_ id: String) throws -> Profile {
        let model = try reloadModel()
        let profiles = model.standaloneProfiles + model.groups.flatMap(\.profiles)
        return try XCTUnwrap(profiles.first { $0.id.rawValue == id })
    }

    private func allProfileNames() throws -> Set<String> {
        let model = try reloadModel()
        return Set(model.standaloneProfiles.map(\.name) + model.groups.flatMap { $0.profiles.map(\.name) })
    }

    /// Same fixture as SwitchCommandTests: one standalone profile and one two-member group with
    /// its first profile active, plus a matching (drift-free) system hosts file.
    private func makeInitializedWorkspace() throws {
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
            isPaused: false
        )
        try workspace.save(model)
        try Data(capturedHosts.utf8).write(to: systemHostsURL)
    }

    /// Group names are not unique (only IDs are): two groups named "Work" make the group half
    /// of a create path ambiguous.
    private func makeDuplicateGroupsWorkspace() throws {
        let workspace = Workspace(rootDirectory: workspaceRootDirectory)
        _ = try workspace.open(systemHosts: { capturedHosts })
        let model = try ActivationModel(
            baseHosts: BaseHosts(content: capturedHosts),
            standaloneProfiles: [],
            groups: [
                Group(id: .init("work-id"), name: "Work", profiles: [
                    Profile(id: .init("dev-id"), name: "Dev", content: "# dev"),
                ]),
                Group(id: .init("work-2-id"), name: "Work", profiles: [
                    Profile(id: .init("beta-id"), name: "Beta", content: "# beta"),
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
