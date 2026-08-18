import HostflipCore
import XCTest
@testable import HostflipCLI

final class DoctorCommandTests: XCTestCase {
    private var rootDirectory: URL!
    private var workspaceRootDirectory: URL!
    private var systemHostsURL: URL!

    override func setUpWithError() throws {
        rootDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("hostflip-doctor-tests-\(UUID().uuidString)", isDirectory: true)
        workspaceRootDirectory = rootDirectory.appendingPathComponent("workspace", isDirectory: true)
        systemHostsURL = rootDirectory.appendingPathComponent("hosts")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: rootDirectory)
    }

    // MARK: - Usage

    func testDoctorWithoutAHostnameFailsWithUsageExitCode() async throws {
        let result = await invoke("doctor")

        XCTAssertEqual(result.exitCode, .usage)
        XCTAssertTrue(result.standardError.contains("'doctor' needs a hostname"))
    }

    func testDoctorWithASecondPositionalFailsWithUsageExitCode() async throws {
        let result = await invoke("doctor", "a.example.com", "b.example.com")

        XCTAssertEqual(result.exitCode, .usage)
        XCTAssertTrue(result.standardError.contains("unexpected argument 'b.example.com'"))
    }

    func testDoctorWithTheIDOptionFailsWithUsageExitCode() async throws {
        let result = await invoke("doctor", "--id", "dev-id")

        XCTAssertEqual(result.exitCode, .usage)
        XCTAssertTrue(result.standardError.contains("unexpected option '--id'"))
    }

    func testDoctorWithADotOnlyHostnameFailsWithUsageExitCode() async throws {
        try makeWorkspace()

        let result = await invoke("doctor", ".")

        XCTAssertEqual(result.exitCode, .usage)
        XCTAssertTrue(result.standardError.contains("'.' is not a hostname"))
    }

    func testHelpListsDoctor() async throws {
        let result = await invoke("--help")

        XCTAssertEqual(result.exitCode, .success)
        XCTAssertTrue(result.standardOutput.contains("doctor"))
        XCTAssertTrue(result.standardOutput.contains("exits 7"))
    }

    // MARK: - Read-only, zero XPC

    func testDoctorOnAnUninitializedWorkspaceFailsWithoutCapturing() async throws {
        let result = await invoke("doctor", "dev.example.com")

        XCTAssertEqual(result.exitCode, .failure)
        XCTAssertTrue(result.standardError.contains("not initialized"))
        // Read-only clients never turn a missing workspace into a first capture.
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: workspaceRootDirectory.appendingPathComponent("manifest.json").path
        ))
    }

    func testDoctorNeverConstructsAMerger() async throws {
        try makeConsistentWorkspace()

        // Doctor is contractually zero-XPC (ADR-0014): it must work identically with the
        // daemon unapproved or absent, so even constructing a merger is a violation.
        let result = await CLI.run(
            arguments: ["doctor", "dev.example.com"],
            workspaceRootDirectory: workspaceRootDirectory,
            systemHostsURL: systemHostsURL,
            makeHostsMerger: { _ in
                XCTFail("doctor must never construct a merger")
                return UnusableMerger()
            },
            resolveHostname: { _ in .addresses(["127.0.0.1"]) }
        )

        XCTAssertEqual(result.exitCode, .success)
    }

    // MARK: - Consistent report

    func testDoctorConsistentReportRendersEveryLayer() async throws {
        try makeConsistentWorkspace()

        let result = await invoke("doctor", "dev.example.com") { _ in .addresses(["127.0.0.1"]) }

        XCTAssertEqual(result.exitCode, .success)
        XCTAssertEqual(result.standardError, "")
        XCTAssertEqual(result.standardOutput, """
            Doctor: dev.example.com — consistent

            Profiles:
              Solo (inactive — present, not applied):
                10.9.9.9 dev.example.com
              Work/Dev (active):
                127.0.0.1 dev.example.com www.example.com

            Merge:
              127.0.0.1 dev.example.com www.example.com

            File:
              no drift — the system hosts matches the last confirmed write

            Resolver:
              returns 127.0.0.1
              matches the merged mappings

            Guidance:
              The system side is consistent. If an app still sees a different address, the cause is inside that app, beyond any hosts switcher's reach:
              - Browsers keep a private DNS cache and reuse open connections for minutes; restart the browser, or clear its host cache and flush its socket pools.
              - DNS-over-HTTPS ("secure DNS") bypasses the hosts file entirely; while it is on, hosts entries never take effect in that app.

            """)
    }

    func testDoctorJSONLayersCarryStableCodes() async throws {
        try makeConsistentWorkspace()

        let result = await invoke("--json", "doctor", "dev.example.com") { _ in
            .addresses(["127.0.0.1"])
        }

        XCTAssertEqual(result.exitCode, .success)
        let object = try jsonObject(result.standardOutput)
        XCTAssertEqual(object["hostname"] as? String, "dev.example.com")
        XCTAssertEqual(object["consistent"] as? Bool, true)
        let layers = try XCTUnwrap(object["layers"] as? [[String: Any]])
        XCTAssertEqual(
            layers.map { $0["layer"] as? String },
            ["profiles", "merge", "file", "resolver", "guidance"]
        )
        XCTAssertEqual(
            layers.map { $0["code"] as? String },
            ["found", "mapped", "clean", "match", "system-consistent"]
        )
        let appearances = try XCTUnwrap(layers[0]["appearances"] as? [[String: Any]])
        XCTAssertEqual(appearances.map { $0["source"] as? String }, ["Solo", "Work/Dev"])
        XCTAssertEqual(appearances.map { $0["status"] as? String }, ["inactive", "active"])
        XCTAssertEqual(appearances.map { $0["id"] as? String }, ["solo-id", "dev-id"])
        let resolver = layers[3]
        XCTAssertEqual(resolver["addresses"] as? [String], ["127.0.0.1"])
        XCTAssertEqual(resolver["fakeIP"] as? Bool, false)
        XCTAssertEqual(resolver["mixedFamilies"] as? Bool, false)
    }

    // MARK: - Hostname matching

    func testDoctorMatchesCaseInsensitivelyStrippingTheTrailingDot() async throws {
        try makeWorkspace(
            standaloneProfiles: [
                Profile(id: .init("api-id"), name: "API", content: "127.0.0.1 API.example.com. extra\n"),
            ],
            activeProfileIDs: [.init("api-id")]
        )

        // Query side: uppercase and a trailing dot; file side: mixed case and a trailing dot.
        let result = await invoke("--json", "doctor", "Api.EXAMPLE.com.") { _ in
            .addresses(["127.0.0.1"])
        }

        XCTAssertEqual(result.exitCode, .success)
        let object = try jsonObject(result.standardOutput)
        XCTAssertEqual(object["hostname"] as? String, "api.example.com")
        let layers = try XCTUnwrap(object["layers"] as? [[String: Any]])
        XCTAssertEqual(layers[0]["code"] as? String, "found")
        XCTAssertEqual(layers[1]["code"] as? String, "mapped")
    }

    func testDoctorMatchesAliasTokensBeyondTheFirstName() async throws {
        try makeWorkspace(
            standaloneProfiles: [
                Profile(
                    id: .init("alias-id"),
                    name: "Alias",
                    content: "127.0.0.1 canonical.example.com alias.example.com # note\n"
                ),
            ],
            activeProfileIDs: [.init("alias-id")]
        )

        let result = await invoke("--json", "doctor", "alias.example.com") { _ in
            .addresses(["127.0.0.1"])
        }

        XCTAssertEqual(result.exitCode, .success)
        let layers = try XCTUnwrap(try jsonObject(result.standardOutput)["layers"] as? [[String: Any]])
        let mappings = try XCTUnwrap(layers[1]["mappings"] as? [[String: Any]])
        XCTAssertEqual(mappings.map { $0["ip"] as? String }, ["127.0.0.1"])
    }

    // MARK: - Profile-layer states

    func testDoctorReportsAnInactiveOnlyAppearanceAsConsistent() async throws {
        try makeWorkspace(
            standaloneProfiles: [
                Profile(id: .init("solo-id"), name: "Solo", content: "10.9.9.9 dev.example.com\n"),
            ]
        )

        let result = await invoke("doctor", "dev.example.com")

        // The system behaves exactly as configured: an unapplied profile is a finding to
        // explain, not an inconsistency.
        XCTAssertEqual(result.exitCode, .success)
        XCTAssertTrue(result.standardOutput.contains("Solo (inactive — present, not applied):"))
        XCTAssertTrue(result.standardOutput.contains("no mapping in the merged output"))
        XCTAssertTrue(result.standardOutput.contains("returns no addresses (host not found)"))
    }

    func testDoctorReportsAPausedActiveProfileAsPreservedNotApplied() async throws {
        try makeWorkspace(
            standaloneProfiles: [
                Profile(id: .init("solo-id"), name: "Solo", content: "10.9.9.9 dev.example.com\n"),
            ],
            activeProfileIDs: [.init("solo-id")],
            isPaused: true
        )

        let result = await invoke("--json", "doctor", "dev.example.com")

        XCTAssertEqual(result.exitCode, .success)
        let layers = try XCTUnwrap(try jsonObject(result.standardOutput)["layers"] as? [[String: Any]])
        let appearances = try XCTUnwrap(layers[0]["appearances"] as? [[String: Any]])
        XCTAssertEqual(appearances.first?["status"] as? String, "active-paused")
        // While paused only Base Hosts is written, so the merge has no mapping.
        XCTAssertEqual(layers[1]["code"] as? String, "not-mapped")

        let human = await invoke("doctor", "dev.example.com")
        XCTAssertTrue(human.standardOutput.contains(
            "Solo (active, Paused — selection preserved, not applied):"
        ))
    }

    func testDoctorReportsABaseHostsAppearance() async throws {
        try makeWorkspace()

        let result = await invoke("doctor", "localhost") { _ in .addresses(["127.0.0.1"]) }

        XCTAssertEqual(result.exitCode, .success)
        XCTAssertTrue(result.standardOutput.contains("Base Hosts (always applied):"))
        XCTAssertTrue(result.standardOutput.contains("127.0.0.1 localhost"))
    }

    func testDoctorReportsNoAppearanceAnywhere() async throws {
        try makeWorkspace()

        let result = await invoke("--json", "doctor", "unknown.example.com")

        XCTAssertEqual(result.exitCode, .success)
        let layers = try XCTUnwrap(try jsonObject(result.standardOutput)["layers"] as? [[String: Any]])
        XCTAssertEqual(layers[0]["code"] as? String, "not-found")

        let human = await invoke("doctor", "unknown.example.com")
        XCTAssertTrue(human.standardOutput.contains("no entry in Base Hosts or any profile"))
    }

    // MARK: - Merge layer: every mapping, no winner

    func testDoctorReturnsEveryMappingAndWarnsOnDifferentIPs() async throws {
        try makeWorkspace(
            standaloneProfiles: [
                Profile(id: .init("a-id"), name: "A", content: "127.0.0.1 dev.example.com\n"),
                Profile(id: .init("b-id"), name: "B", content: "10.0.0.1 dev.example.com\n"),
            ],
            activeProfileIDs: [.init("a-id"), .init("b-id")]
        )

        // The resolver returns all entries (the #66 measurement), so the sets agree: the
        // ambiguity stays a warning with a stable code — per ADR-0014 only set disagreement
        // between layers is an anomaly, and same-family multi-IP setups are legitimate.
        let result = await invoke("--json", "doctor", "dev.example.com") { _ in
            .addresses(["127.0.0.1", "10.0.0.1"])
        }

        XCTAssertEqual(result.exitCode, .success)
        let object = try jsonObject(result.standardOutput)
        XCTAssertEqual(object["consistent"] as? Bool, true)
        let layers = try XCTUnwrap(object["layers"] as? [[String: Any]])
        XCTAssertEqual(layers[1]["code"] as? String, "ambiguous")
        let mappings = try XCTUnwrap(layers[1]["mappings"] as? [[String: Any]])
        XCTAssertEqual(mappings.map { $0["ip"] as? String }, ["127.0.0.1", "10.0.0.1"])
        XCTAssertEqual(layers[3]["code"] as? String, "match")
        XCTAssertEqual(layers[4]["code"] as? String, "system-consistent")

        let human = await invoke("doctor", "dev.example.com") { _ in
            .addresses(["127.0.0.1", "10.0.0.1"])
        }
        XCTAssertTrue(human.standardOutput.contains(
            "Warning: 2 mappings with different IPs — the resolver returns all of them; no entry wins over another."
        ))
    }

    func testDoctorDoesNotFlagADualStackPairAsAmbiguous() async throws {
        // Every macOS hosts file maps localhost to both 127.0.0.1 and ::1; a v4+v6 pair is
        // dual-stack practice, not a duplicate-domain conflict.
        try makeWorkspace(baseHosts: "127.0.0.1 localhost\n::1 localhost\n")

        let result = await invoke("--json", "doctor", "localhost") { _ in
            .addresses(["::1", "127.0.0.1"])
        }

        XCTAssertEqual(result.exitCode, .success)
        let layers = try XCTUnwrap(try jsonObject(result.standardOutput)["layers"] as? [[String: Any]])
        XCTAssertEqual(layers[1]["code"] as? String, "mapped")
    }

    func testDoctorAcceptsMultipleMappingsWithTheSameIP() async throws {
        try makeWorkspace(
            standaloneProfiles: [
                Profile(id: .init("a-id"), name: "A", content: "127.0.0.1 dev.example.com\n"),
                Profile(id: .init("b-id"), name: "B", content: "127.0.0.1 dev.example.com\n"),
            ],
            activeProfileIDs: [.init("a-id"), .init("b-id")]
        )

        let result = await invoke("--json", "doctor", "dev.example.com") { _ in
            .addresses(["127.0.0.1"])
        }

        XCTAssertEqual(result.exitCode, .success)
        let layers = try XCTUnwrap(try jsonObject(result.standardOutput)["layers"] as? [[String: Any]])
        XCTAssertEqual(layers[1]["code"] as? String, "mapped")
        XCTAssertEqual((layers[1]["mappings"] as? [[String: Any]])?.count, 2)
    }

    // MARK: - File layer

    func testDoctorReportsDriftWithExpectedAndActualEntriesSideBySide() async throws {
        try makeConsistentWorkspace()
        try Data("10.0.0.1 dev.example.com # tampered\n".utf8).write(to: systemHostsURL)

        let result = await invoke("--json", "doctor", "dev.example.com") { _ in
            .addresses(["127.0.0.1"])
        }

        XCTAssertEqual(result.exitCode, .inconsistent)
        let layers = try XCTUnwrap(try jsonObject(result.standardOutput)["layers"] as? [[String: Any]])
        XCTAssertEqual(layers[2]["code"] as? String, "drift")
        let expected = try XCTUnwrap(layers[2]["expected"] as? [[String: Any]])
        XCTAssertEqual(expected.map { $0["ip"] as? String }, ["127.0.0.1"])
        let actual = try XCTUnwrap(layers[2]["actual"] as? [[String: Any]])
        XCTAssertEqual(actual.map { $0["ip"] as? String }, ["10.0.0.1"])

        let human = await invoke("doctor", "dev.example.com") { _ in .addresses(["127.0.0.1"]) }
        XCTAssertTrue(human.standardOutput.contains("Expected for this hostname:"))
        XCTAssertTrue(human.standardOutput.contains("Actual in the system hosts:"))
    }

    // MARK: - Resolver layer

    func testDoctorFlagsAResolverMismatch() async throws {
        try makeConsistentWorkspace()

        let result = await invoke("--json", "doctor", "dev.example.com") { _ in
            .addresses(["10.0.0.1"])
        }

        XCTAssertEqual(result.exitCode, .inconsistent)
        let layers = try XCTUnwrap(try jsonObject(result.standardOutput)["layers"] as? [[String: Any]])
        XCTAssertEqual(layers[3]["code"] as? String, "mismatch")

        let human = await invoke("doctor", "dev.example.com") { _ in .addresses(["10.0.0.1"]) }
        XCTAssertTrue(human.standardOutput.contains("Mismatch"))
    }

    func testDoctorReportsAResolverFailureAsAFindingNotAToolFailure() async throws {
        try makeConsistentWorkspace()

        let result = await invoke("--json", "doctor", "dev.example.com") { _ in
            .failed("temporary failure in name resolution")
        }

        // The query failure is its own stable code: the answers were never observed, so
        // claiming a mismatch would be false — but the diagnosis still found a problem.
        XCTAssertEqual(result.exitCode, .inconsistent)
        let layers = try XCTUnwrap(try jsonObject(result.standardOutput)["layers"] as? [[String: Any]])
        XCTAssertEqual(layers[3]["code"] as? String, "query-failed")
        XCTAssertEqual(layers[3]["failure"] as? String, "temporary failure in name resolution")

        let human = await invoke("doctor", "dev.example.com") { _ in .failed("temporary failure in name resolution") }
        XCTAssertTrue(human.standardOutput.contains("query failed: temporary failure in name resolution"))
        XCTAssertFalse(human.standardOutput.contains("Mismatch"))
    }

    func testDoctorFlagsAResolverFailureEvenWithoutAHostsMapping() async throws {
        try makeWorkspace()

        let result = await invoke("--json", "doctor", "unmapped.example.com") { _ in
            .failed("resolver unreachable")
        }

        // A broken system resolver must never pass silently just because hostflip has no
        // mapping for the name.
        XCTAssertEqual(result.exitCode, .inconsistent)
        let layers = try XCTUnwrap(try jsonObject(result.standardOutput)["layers"] as? [[String: Any]])
        XCTAssertEqual(layers[3]["code"] as? String, "query-failed")
    }

    func testDoctorTreatsReorderedMixedFamiliesAsAMatchWithANote() async throws {
        try makeWorkspace(
            standaloneProfiles: [
                Profile(
                    id: .init("mixed-id"),
                    name: "Mixed",
                    content: "127.0.0.1 dev.example.com\n::1 dev.example.com\n"
                ),
            ],
            activeProfileIDs: [.init("mixed-id")]
        )

        // The #66 measurement: RFC 6724 sorting puts ::1 first even though the file lists
        // IPv4 first, and "0:0:0:0:0:0:0:1" is the same address as "::1".
        let result = await invoke("--json", "doctor", "dev.example.com") { _ in
            .addresses(["0:0:0:0:0:0:0:1", "127.0.0.1"])
        }

        XCTAssertEqual(result.exitCode, .success)
        let layers = try XCTUnwrap(try jsonObject(result.standardOutput)["layers"] as? [[String: Any]])
        XCTAssertEqual(layers[3]["code"] as? String, "match")
        XCTAssertEqual(layers[3]["addresses"] as? [String], ["0:0:0:0:0:0:0:1", "127.0.0.1"])
        XCTAssertEqual(layers[3]["mixedFamilies"] as? Bool, true)

        let human = await invoke("doctor", "dev.example.com") { _ in
            .addresses(["0:0:0:0:0:0:0:1", "127.0.0.1"])
        }
        XCTAssertTrue(human.standardOutput.contains("RFC 6724"))
    }

    func testDoctorFlagsFakeIPAnswersWithoutAHostsMapping() async throws {
        try makeWorkspace()

        let result = await invoke("--json", "doctor", "unmapped.example.com") { _ in
            .addresses(["198.18.10.100"])
        }

        // No hosts mapping means DNS answers are informational, not an inconsistency —
        // but a 198.18.0.0/15 answer marks a fake-IP DNS takeover worth surfacing.
        XCTAssertEqual(result.exitCode, .success)
        let layers = try XCTUnwrap(try jsonObject(result.standardOutput)["layers"] as? [[String: Any]])
        XCTAssertEqual(layers[3]["code"] as? String, "no-mapping")
        XCTAssertEqual(layers[3]["fakeIP"] as? Bool, true)

        let human = await invoke("doctor", "unmapped.example.com") { _ in
            .addresses(["198.18.10.100"])
        }
        XCTAssertTrue(human.standardOutput.contains("fake-IP"))
        XCTAssertTrue(human.standardOutput.contains("answers come from DNS"))
    }

    // MARK: - Guidance wording (ADR-0014: exclusion, never detection claims)

    func testGuidanceNeverClaimsToHaveDetectedABrowserProblem() async throws {
        try makeConsistentWorkspace()

        let result = await invoke("doctor", "dev.example.com") { _ in .addresses(["127.0.0.1"]) }

        XCTAssertFalse(result.standardOutput.localizedCaseInsensitiveContains("detected browser"))
        XCTAssertTrue(result.standardOutput.contains("DNS-over-HTTPS"))
    }

    func testGuidancePointsBackAtFindingsWhenInconsistent() async throws {
        try makeConsistentWorkspace()

        let result = await invoke("doctor", "dev.example.com") { _ in .addresses(["10.0.0.1"]) }

        XCTAssertEqual(result.exitCode, .inconsistent)
        XCTAssertTrue(result.standardOutput.contains(
            "Inconsistencies were found above; resolve them before suspecting a browser or app."
        ))
        XCTAssertFalse(result.standardOutput.contains("DNS-over-HTTPS"))
    }

    // MARK: - Helpers

    /// Doctor never merges; any merge call is a contract violation.
    private struct UnusableMerger: HostsMerging {
        func merge(_ merged: MergedHosts, mergeID: UUID, isInterruptedRetry: Bool) async throws -> String {
            XCTFail("doctor must never talk to the daemon")
            throw CLIError.hostsDrift
        }
    }

    private func invoke(
        _ arguments: String...,
        resolver: @escaping @Sendable (String) -> ResolverReply = { _ in .noSuchHost }
    ) async -> CLIResult {
        await CLI.run(
            arguments: arguments,
            workspaceRootDirectory: workspaceRootDirectory,
            systemHostsURL: systemHostsURL,
            makeHostsMerger: { _ in UnusableMerger() },
            resolveHostname: resolver
        )
    }

    /// Initializes a workspace and writes the merge output to the system hosts file with
    /// its hash recorded, so the file layer starts clean.
    @discardableResult
    private func makeWorkspace(
        baseHosts: String = "127.0.0.1 localhost\n",
        standaloneProfiles: [Profile] = [],
        groups: [Group] = [],
        activeProfileIDs: Set<Profile.ID> = [],
        isPaused: Bool = false
    ) throws -> Workspace {
        let workspace = Workspace(rootDirectory: workspaceRootDirectory)
        _ = try workspace.open(systemHosts: { baseHosts })
        let model = try ActivationModel(
            baseHosts: BaseHosts(content: baseHosts),
            standaloneProfiles: standaloneProfiles,
            groups: groups,
            activeProfileIDs: activeProfileIDs,
            isPaused: isPaused
        )
        try workspace.save(model)
        let merged = model.mergedHosts
        try Data(merged.content.utf8).write(to: systemHostsURL)
        try workspace.recordLastWrittenHash(merged.hash)
        return workspace
    }

    /// The fixture behind the golden report: dev.example.com in an inactive standalone
    /// profile and an active group member, with the system hosts in sync.
    private func makeConsistentWorkspace() throws {
        try makeWorkspace(
            standaloneProfiles: [
                Profile(id: .init("solo-id"), name: "Solo", content: "10.9.9.9 dev.example.com\n"),
            ],
            groups: [
                Group(id: .init("work-id"), name: "Work", profiles: [
                    Profile(
                        id: .init("dev-id"),
                        name: "Dev",
                        content: "127.0.0.1 dev.example.com www.example.com\n"
                    ),
                ]),
            ],
            activeProfileIDs: [.init("dev-id")]
        )
    }

    private func jsonObject(_ text: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }
}
