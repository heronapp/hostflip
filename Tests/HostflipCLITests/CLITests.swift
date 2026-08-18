import HostflipCore
import HostflipXPC
import XCTest
@testable import HostflipCLI

final class CLITests: XCTestCase {
    private var rootDirectory: URL!
    private var workspaceRootDirectory: URL!
    private var systemHostsURL: URL!

    private let capturedHosts = "127.0.0.1 localhost\n"

    override func setUpWithError() throws {
        rootDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("hostflip-cli-tests-\(UUID().uuidString)", isDirectory: true)
        workspaceRootDirectory = rootDirectory.appendingPathComponent("workspace", isDirectory: true)
        systemHostsURL = rootDirectory.appendingPathComponent("hosts")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: rootDirectory)
    }

    // MARK: - status

    func testStatusReportsRunningActiveProfilesAndNoDrift() async throws {
        try makeInitializedWorkspace()

        let result = await invoke("status")

        XCTAssertEqual(result.exitCode, .success)
        XCTAssertEqual(result.standardError, "")
        XCTAssertEqual(result.standardOutput, """
            Status: running
            Active: Work/Dev
            Drift:  none

            """)
    }

    func testStatusJSONWritesTheResultObjectToStandardOutput() async throws {
        try makeInitializedWorkspace()

        let result = await invoke("--json", "status")

        XCTAssertEqual(result.exitCode, .success)
        XCTAssertEqual(result.standardError, "")
        let object = try jsonObject(result.standardOutput)
        XCTAssertEqual(object["paused"] as? Bool, false)
        XCTAssertEqual(object["drift"] as? Bool, false)
        let active = try XCTUnwrap(object["active"] as? [[String: Any]])
        XCTAssertEqual(active.count, 1)
        XCTAssertEqual(active.first?["id"] as? String, "dev-id")
        XCTAssertEqual(active.first?["name"] as? String, "Dev")
        XCTAssertEqual(active.first?["group"] as? String, "Work")
    }

    func testStatusReportsPausedWhilePreservingActiveProfiles() async throws {
        try makeInitializedWorkspace(paused: true)

        let result = await invoke("status")

        XCTAssertEqual(result.exitCode, .success)
        XCTAssertTrue(result.standardOutput.hasPrefix("Status: paused\nActive: Work/Dev\n"))
    }

    func testStatusReportsDriftWhenTheSystemHostsDiverges() async throws {
        try makeInitializedWorkspace()
        try Data("tampered\n".utf8).write(to: systemHostsURL)

        let result = await invoke("--json", "status")

        // status only reports drift; exit code 3 is reserved for write commands refusing to proceed.
        XCTAssertEqual(result.exitCode, .success)
        XCTAssertEqual(try jsonObject(result.standardOutput)["drift"] as? Bool, true)
    }

    func testStatusDriftLineNamesTheDriftInHumanOutput() async throws {
        try makeInitializedWorkspace()
        try Data("tampered\n".utf8).write(to: systemHostsURL)

        let result = await invoke("status")

        XCTAssertTrue(result.standardOutput.contains("Drift:  detected"))
    }

    func testStatusDriftBaselineFollowsTheLastConfirmedMergeWrite() async throws {
        let workspace = try makeInitializedWorkspace()
        let merged = "merged output\n"
        try workspace.recordLastWrittenHash(MergedHosts(content: merged).hash)
        try Data(merged.utf8).write(to: systemHostsURL)

        let result = await invoke("--json", "status")

        // The system hosts no longer matches first capture, but it matches the recorded merge
        // write: no drift — the same baseline the app's drift monitor compares against.
        XCTAssertEqual(try jsonObject(result.standardOutput)["drift"] as? Bool, false)
    }

    // MARK: - list

    func testListShowsTheGroupStructureWithIDs() async throws {
        try makeInitializedWorkspace()

        let result = await invoke("list")

        XCTAssertEqual(result.exitCode, .success)
        XCTAssertEqual(result.standardError, "")
        XCTAssertEqual(result.standardOutput, """
            Solo       solo-id
            Work/      work-id
              Dev      dev-id
              Staging  staging-id

            """)
    }

    func testListJSONContainsStandaloneProfilesAndGroups() async throws {
        try makeInitializedWorkspace()

        let result = await invoke("--json", "list")

        XCTAssertEqual(result.exitCode, .success)
        let object = try jsonObject(result.standardOutput)
        let standalone = try XCTUnwrap(object["standaloneProfiles"] as? [[String: Any]])
        XCTAssertEqual(standalone.map { $0["id"] as? String }, ["solo-id"])
        XCTAssertEqual(standalone.map { $0["name"] as? String }, ["Solo"])
        let groups = try XCTUnwrap(object["groups"] as? [[String: Any]])
        XCTAssertEqual(groups.map { $0["id"] as? String }, ["work-id"])
        XCTAssertEqual(groups.map { $0["name"] as? String }, ["Work"])
        let members = try XCTUnwrap(groups.first?["profiles"] as? [[String: Any]])
        XCTAssertEqual(members.map { $0["id"] as? String }, ["dev-id", "staging-id"])
    }

    func testListPadsNonBMPNamesWithoutTruncatingTheIDColumn() async throws {
        let workspace = Workspace(rootDirectory: workspaceRootDirectory)
        _ = try workspace.open(systemHosts: { capturedHosts })
        let model = try ActivationModel(
            baseHosts: BaseHosts(content: capturedHosts),
            standaloneProfiles: [
                Profile(id: .init("emoji-id"), name: "🚀🚀🚀🚀🚀🚀", content: "# a"),
                Profile(id: .init("plain-id"), name: "Plain", content: "# b"),
            ],
            groups: []
        )
        try workspace.save(model)

        let result = await invoke("list")

        // A name whose UTF-16 length exceeds the column width must still be printed whole,
        // with its ID intact after the padding.
        XCTAssertEqual(result.standardOutput, """
            🚀🚀🚀🚀🚀🚀  emoji-id
            Plain   plain-id

            """)
    }

    func testListWithNoProfilesPrintsAPlaceholder() async throws {
        let workspace = Workspace(rootDirectory: workspaceRootDirectory)
        _ = try workspace.open(systemHosts: { capturedHosts })

        let result = await invoke("list")

        XCTAssertEqual(result.exitCode, .success)
        XCTAssertEqual(result.standardOutput, "No profiles.\n")
    }

    func testListAnnotatesRemoteProfilesWithTheirSourceURLAndInterval() async throws {
        try makeRemoteProfileWorkspace()

        let result = await invoke("list")

        XCTAssertEqual(result.exitCode, .success)
        XCTAssertEqual(result.standardOutput, """
            Solo    solo-id
            Remote  remote-id  [remote: https://example.com/hosts.txt, 6h]
            Work/   work-id
              Dev   dev-id

            """)
    }

    func testListJSONCarriesRemoteMetadataAndOmitsItForLocalProfiles() async throws {
        try makeRemoteProfileWorkspace()

        let result = await invoke("--json", "list")

        XCTAssertEqual(result.exitCode, .success)
        let standalone = try XCTUnwrap(try jsonObject(result.standardOutput)["standaloneProfiles"] as? [[String: Any]])
        let solo = try XCTUnwrap(standalone.first { $0["id"] as? String == "solo-id" })
        XCTAssertNil(solo["remote"], "a local profile carries no remote key")
        let remote = try XCTUnwrap(standalone.first { $0["id"] as? String == "remote-id" }?["remote"] as? [String: Any])
        XCTAssertEqual(remote["url"] as? String, "https://example.com/hosts.txt")
        XCTAssertEqual(remote["interval"] as? String, "6h")
        XCTAssertEqual(remote["lastSuccessAt"] as? String, "2025-08-18T06:53:20Z")
        XCTAssertEqual(remote["lastAttemptFailed"] as? Bool, false)
    }

    func testListJSONReportsANeverRefreshedRemoteProfileWithNullSuccessTime() async throws {
        let workspace = Workspace(rootDirectory: workspaceRootDirectory)
        _ = try workspace.open(systemHosts: { capturedHosts })
        let model = try ActivationModel(
            baseHosts: BaseHosts(content: capturedHosts),
            standaloneProfiles: [
                Profile(
                    id: .init("remote-id"),
                    name: "Remote",
                    content: "#!hostflip-remote https://example.com/hosts.txt interval=manual\n",
                    remoteRefreshState: RemoteRefreshState(lastAttemptFailed: true)
                ),
            ],
            groups: []
        )
        try workspace.save(model)

        let result = await invoke("--json", "list")

        XCTAssertEqual(result.exitCode, .success)
        let standalone = try XCTUnwrap(try jsonObject(result.standardOutput)["standaloneProfiles"] as? [[String: Any]])
        let remote = try XCTUnwrap(standalone.first?["remote"] as? [String: Any])
        XCTAssertEqual(remote["lastSuccessAt"] as? NSNull, NSNull(), "no success yet is an explicit null, not an absent key")
        XCTAssertEqual(remote["lastAttemptFailed"] as? Bool, true)
    }

    // MARK: - cat

    func testCatByNamePrintsTheProfileContentVerbatim() async throws {
        try makeInitializedWorkspace()

        let result = await invoke("cat", "Dev")

        XCTAssertEqual(result.exitCode, .success)
        XCTAssertEqual(result.standardError, "")
        // Verbatim: the fixture content has no trailing newline, so neither has stdout.
        XCTAssertEqual(result.standardOutput, "# dev")
    }

    func testCatPreservesATrailingNewlineExactly() async throws {
        let workspace = Workspace(rootDirectory: workspaceRootDirectory)
        _ = try workspace.open(systemHosts: { capturedHosts })
        let content = "127.0.0.1 dev.local\n"
        let model = try ActivationModel(
            baseHosts: BaseHosts(content: capturedHosts),
            standaloneProfiles: [Profile(id: .init("dev-id"), name: "Dev", content: content)],
            groups: []
        )
        try workspace.save(model)

        let result = await invoke("cat", "Dev")

        XCTAssertEqual(result.standardOutput, content)
    }

    func testCatByPathPrintsTheNamedGroupMember() async throws {
        try makeInitializedWorkspace()

        let result = await invoke("cat", "Work/Staging")

        XCTAssertEqual(result.exitCode, .success)
        XCTAssertEqual(result.standardOutput, "# staging")
    }

    func testCatByIDPrintsTheProfile() async throws {
        try makeInitializedWorkspace()

        let result = await invoke("cat", "--id", "solo-id")

        XCTAssertEqual(result.exitCode, .success)
        XCTAssertEqual(result.standardOutput, "# solo")
    }

    func testCatJSONReportsTheResolvedProfileWithItsContent() async throws {
        try makeInitializedWorkspace()

        let result = await invoke("--json", "cat", "Dev")

        XCTAssertEqual(result.exitCode, .success)
        let object = try jsonObject(result.standardOutput)
        XCTAssertEqual(object["id"] as? String, "dev-id")
        XCTAssertEqual(object["name"] as? String, "Dev")
        XCTAssertEqual(object["group"] as? String, "Work")
        XCTAssertEqual(object["content"] as? String, "# dev")
    }

    func testCatARemoteProfileReportsRemoteMetadataAndTheHeaderLeadsTheContent() async throws {
        try makeRemoteProfileWorkspace()

        let result = await invoke("--json", "cat", "Remote")

        XCTAssertEqual(result.exitCode, .success)
        let object = try jsonObject(result.standardOutput)
        XCTAssertEqual(
            object["content"] as? String,
            "#!hostflip-remote https://example.com/hosts.txt interval=6h\n1.2.3.4 a.example.com\n",
            "the verbatim content leads with the header line, so the human output shows it too"
        )
        let remote = try XCTUnwrap(object["remote"] as? [String: Any])
        XCTAssertEqual(remote["url"] as? String, "https://example.com/hosts.txt")
        XCTAssertEqual(remote["interval"] as? String, "6h")
        XCTAssertEqual(
            remote["lastSuccessAt"] as? String,
            "2025-08-18T06:53:20Z",
            "cat shares the remote metadata shape with list, Freshness fields included"
        )

        let local = await invoke("--json", "cat", "Solo")
        XCTAssertNil(try jsonObject(local.standardOutput)["remote"], "a local profile carries no remote key")
    }

    func testCatUnknownReferenceFailsWithNotFoundExitCode() async throws {
        try makeInitializedWorkspace()

        let result = await invoke("cat", "Missing")

        XCTAssertEqual(result.exitCode, .notFound)
        XCTAssertEqual(result.standardOutput, "")
        XCTAssertTrue(result.standardError.contains("no profile matches 'Missing'"))
    }

    func testCatUnknownReferenceJSONErrorCarriesTheNotFoundCodeWithoutCandidates() async throws {
        try makeInitializedWorkspace()

        let result = await invoke("--json", "cat", "--id", "missing-id")

        XCTAssertEqual(result.exitCode, .notFound)
        let details = try XCTUnwrap(try jsonObject(result.standardError)["error"] as? [String: Any])
        XCTAssertEqual(details["code"] as? String, "profile-not-found")
        XCTAssertNil(details["candidates"])
    }

    func testCatWithAnIDPastedAsANameHintsAtTheIDOption() async throws {
        try makeInitializedWorkspace()

        let result = await invoke("cat", "dev-id")

        XCTAssertEqual(result.exitCode, .notFound)
        XCTAssertTrue(result.standardError.contains("'dev-id' is a profile ID, not a profile name; use --id dev-id"))
    }

    func testTheIDPastedAsANameJSONErrorKeepsTheNotFoundCode() async throws {
        try makeInitializedWorkspace()

        let result = await invoke("--json", "cat", "dev-id")

        XCTAssertEqual(result.exitCode, .notFound)
        let details = try XCTUnwrap(try jsonObject(result.standardError)["error"] as? [String: Any])
        // The string code is the machine contract and stays stable; only the human message hints.
        XCTAssertEqual(details["code"] as? String, "profile-not-found")
    }

    func testCatAmbiguousReferenceListsEveryCandidateWithItsID() async throws {
        try makeAmbiguousWorkspace()

        let result = await invoke("cat", "Dev")

        XCTAssertEqual(result.exitCode, .ambiguous)
        XCTAssertEqual(result.standardOutput, "")
        // The standalone candidate has no path prefix — that's exactly the case --id exists for.
        XCTAssertEqual(result.standardError, """
            hostflip: 'Dev' matches multiple profiles; disambiguate with a group/profile path or --id:
              Dev       solo-dev-id
              Work/Dev  work-dev-id

            """)
    }

    func testCatAmbiguousReferenceJSONErrorCarriesTheCandidates() async throws {
        try makeAmbiguousWorkspace()

        let result = await invoke("--json", "cat", "Dev")

        XCTAssertEqual(result.exitCode, .ambiguous)
        let details = try XCTUnwrap(try jsonObject(result.standardError)["error"] as? [String: Any])
        XCTAssertEqual(details["code"] as? String, "profile-ambiguous")
        let candidates = try XCTUnwrap(details["candidates"] as? [[String: Any]])
        XCTAssertEqual(candidates.map { $0["id"] as? String }, ["solo-dev-id", "work-dev-id"])
        XCTAssertEqual(candidates.map { $0["name"] as? String }, ["Dev", "Dev"])
        XCTAssertEqual(candidates.map { $0["group"] as? String }, [nil, "Work"])
    }

    // MARK: - Errors and exit codes

    func testUninitializedWorkspaceFailsWithGeneralErrorExitCode() async throws {
        let result = await invoke("status")

        XCTAssertEqual(result.exitCode, .failure)
        XCTAssertEqual(result.standardOutput, "")
        XCTAssertTrue(result.standardError.contains("not initialized"))
    }

    func testUninitializedWorkspaceJSONErrorCarriesTheStringCode() async throws {
        let result = await invoke("--json", "list")

        XCTAssertEqual(result.exitCode, .failure)
        XCTAssertEqual(result.standardOutput, "", "results belong to stdout, errors to stderr")
        let envelope = try jsonObject(result.standardError)
        let details = try XCTUnwrap(envelope["error"] as? [String: Any])
        XCTAssertEqual(details["code"] as? String, "workspace-not-initialized")
        XCTAssertFalse(try XCTUnwrap(details["message"] as? String).isEmpty)
    }

    func testUnknownCommandFailsWithUsageExitCode() async throws {
        let result = await invoke("frobnicate")

        XCTAssertEqual(result.exitCode, .usage)
        XCTAssertTrue(result.standardError.contains("unknown command 'frobnicate'"))
    }

    func testUnknownCommandJSONErrorUsesTheUsageCode() async throws {
        let result = await invoke("--json", "frobnicate")

        XCTAssertEqual(result.exitCode, .usage)
        let details = try XCTUnwrap(try jsonObject(result.standardError)["error"] as? [String: Any])
        XCTAssertEqual(details["code"] as? String, "usage")
    }

    func testUnknownOptionFailsWithUsageExitCode() async throws {
        let result = await invoke("status", "--verbose")

        XCTAssertEqual(result.exitCode, .usage)
        XCTAssertTrue(result.standardError.contains("unknown option '--verbose'"))
    }

    func testUnexpectedExtraArgumentFailsWithUsageExitCode() async throws {
        try makeInitializedWorkspace()

        let result = await invoke("status", "extra")

        XCTAssertEqual(result.exitCode, .usage)
        XCTAssertTrue(result.standardError.contains("unexpected argument 'extra'"))
    }

    func testCatWithoutAReferenceFailsWithUsageExitCode() async throws {
        let result = await invoke("cat")

        XCTAssertEqual(result.exitCode, .usage)
        XCTAssertTrue(result.standardError.contains("'cat' needs a profile name, group/profile path, or --id"))
    }

    func testCatWithBothANameAndIDFailsWithUsageExitCode() async throws {
        let result = await invoke("cat", "Dev", "--id", "dev-id")

        XCTAssertEqual(result.exitCode, .usage)
        XCTAssertTrue(result.standardError.contains("not both"))
    }

    func testCatWithASecondPositionalFailsWithUsageExitCode() async throws {
        let result = await invoke("cat", "Dev", "Staging")

        XCTAssertEqual(result.exitCode, .usage)
        XCTAssertTrue(result.standardError.contains("unexpected argument 'Staging'"))
    }

    func testIDOnACommandThatTakesNoReferenceFailsWithUsageExitCode() async throws {
        let result = await invoke("status", "--id", "dev-id")

        XCTAssertEqual(result.exitCode, .usage)
        XCTAssertTrue(result.standardError.contains("unexpected option '--id'"))
    }

    func testIDWithoutAValueFailsWithUsageExitCode() async throws {
        let result = await invoke("cat", "--id")

        XCTAssertEqual(result.exitCode, .usage)
        XCTAssertTrue(result.standardError.contains("option '--id' requires a value"))
    }

    func testBareInvocationFailsWithUsageExitCode() async throws {
        let result = await invoke()

        XCTAssertEqual(result.exitCode, .usage)
        XCTAssertEqual(result.standardOutput, "")
        XCTAssertTrue(result.standardError.contains("no command given"))
    }

    func testHelpPrintsCanonicalCommandsAndSucceeds() async throws {
        let result = await invoke("--help")

        XCTAssertEqual(result.exitCode, .success)
        XCTAssertEqual(result.standardError, "")
        XCTAssertTrue(result.standardOutput.contains("Usage: hostflip"))
        XCTAssertTrue(result.standardOutput.contains("status"))
        XCTAssertTrue(result.standardOutput.contains("list"))
        XCTAssertTrue(result.standardOutput.contains("cat"))
        XCTAssertTrue(result.standardOutput.contains("--id"))
    }

    func testVersionPrintsTheBundleVersionAndSucceeds() async throws {
        let result = await invoke("--version")

        XCTAssertEqual(result.exitCode, .success)
        XCTAssertEqual(result.standardError, "")
        XCTAssertEqual(result.standardOutput, HostflipBuild.version + "\n")
        XCTAssertTrue(CLI.usageText.contains("--version"))
    }

    func testVersionWithJSONEmitsAVersionObject() async throws {
        let result = await invoke("--json", "--version")

        XCTAssertEqual(result.exitCode, .success)
        XCTAssertEqual(result.standardError, "")
        let object = try jsonObject(result.standardOutput)
        XCTAssertEqual(object["version"] as? String, HostflipBuild.version)
    }

    func testExitCodeFrameworkPinsTheNumericContract() {
        XCTAssertEqual(ExitCode.success.rawValue, 0)
        XCTAssertEqual(ExitCode.failure.rawValue, 1)
        XCTAssertEqual(ExitCode.usage.rawValue, 2)
        // Reserved by the framework; enabled by later commands.
        XCTAssertEqual(ExitCode.drift.rawValue, 3)
        XCTAssertEqual(ExitCode.daemonUnavailable.rawValue, 4)
        XCTAssertEqual(ExitCode.notFound.rawValue, 5)
        XCTAssertEqual(ExitCode.ambiguous.rawValue, 6)
        // doctor's three-state verdict (ADR-0014): 0 consistent, 7 findings, 1 tool failure.
        XCTAssertEqual(ExitCode.inconsistent.rawValue, 7)
    }

    // MARK: - Helpers

    private func invoke(_ arguments: String...) async -> CLIResult {
        await CLI.run(
            arguments: arguments,
            workspaceRootDirectory: workspaceRootDirectory,
            systemHostsURL: systemHostsURL
        )
    }

    /// Initializes a workspace holding one standalone profile and one two-member group with its
    /// first profile active, plus a matching (drift-free) system hosts file.
    @discardableResult
    private func makeInitializedWorkspace(paused: Bool = false) throws -> Workspace {
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
        return workspace
    }

    /// Initializes a workspace where the standalone "Remote" is a Remote Profile (its content's
    /// first line is a Remote Header) next to local content in both containers.
    private func makeRemoteProfileWorkspace() throws {
        let workspace = Workspace(rootDirectory: workspaceRootDirectory)
        _ = try workspace.open(systemHosts: { capturedHosts })
        let model = try ActivationModel(
            baseHosts: BaseHosts(content: capturedHosts),
            standaloneProfiles: [
                Profile(id: .init("solo-id"), name: "Solo", content: "# solo"),
                Profile(
                    id: .init("remote-id"),
                    name: "Remote",
                    content: "#!hostflip-remote https://example.com/hosts.txt interval=6h\n1.2.3.4 a.example.com\n",
                    remoteRefreshState: RemoteRefreshState(
                        lastSuccessAt: Date(timeIntervalSince1970: 1_755_500_000)
                    )
                ),
            ],
            groups: [
                Group(id: .init("work-id"), name: "Work", profiles: [
                    Profile(id: .init("dev-id"), name: "Dev", content: "# dev"),
                ]),
            ]
        )
        try workspace.save(model)
        try Data(capturedHosts.utf8).write(to: systemHostsURL)
    }

    /// Initializes a workspace where the bare name "Dev" is ambiguous between a standalone
    /// profile and a group member.
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
    }

    private func jsonObject(_ text: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }
}
