import HostflipXPC
import XCTest
@testable import Hostflip

/// The report and the prefilled issue URL (#90) from a fixed snapshot: exact text, exact
/// encoding, and nothing user-identifying — the snapshot deliberately has no room for
/// profile names, Source URLs, or hosts lines.
final class DiagnosticReportTests: XCTestCase {
    private let snapshot = DiagnosticSnapshot(
        appVersion: "0.4.0",
        build: "13",
        macOSVersion: "15.6.1",
        architecture: "arm64",
        installSource: .homebrewCask,
        helperStatus: .requiresApproval,
        isPaused: true,
        hasHostsDrift: false,
        groupCount: 2,
        profileCount: 7,
        activeProfileCount: 3,
        remoteFreshness: [
            .init(lastSuccessAge: 5_400, lastAttemptFailed: false),
            .init(lastSuccessAge: nil, lastAttemptFailed: true),
        ]
    )

    func testReportTextMatchesTheFixture() {
        XCTAssertEqual(DiagnosticReport.text(for: snapshot), """
            hostflip 0.4.0 (13) diagnostic report
            macOS: 15.6.1 (arm64)
            Install source: Homebrew cask
            Helper: requiresApproval
            Paused: yes
            Hosts drift detected: no
            Groups: 2
            Profiles: 7 (active: 3, remote: 2)
            Remote profile 1: last success 1h 30m ago, last attempt failed: no
            Remote profile 2: never refreshed, last attempt failed: yes
            """)
    }

    func testEnvironmentBlockIsTheHeadOfTheReport() {
        XCTAssertEqual(DiagnosticReport.environment(for: snapshot), """
            hostflip 0.4.0 (13)
            macOS: 15.6.1 (arm64)
            Install source: Homebrew cask
            Helper: requiresApproval
            """)
    }

    func testIssueURLTargetsTheBugFormWithThePercentEncodedEnvironment() throws {
        let url = DiagnosticReport.issueURL(for: snapshot)
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        XCTAssertEqual(components.scheme, "https")
        XCTAssertEqual(components.host, "github.com")
        XCTAssertEqual(components.path, "/heronapp/hostflip/issues/new")
        let items = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value) })
        XCTAssertEqual(items["template"], "bug_report.yml")
        XCTAssertEqual(items["environment"], DiagnosticReport.environment(for: snapshot))
        // Query strings must not carry raw newlines or spaces.
        XCTAssertFalse(url.absoluteString.contains("\n"))
        XCTAssertFalse(url.absoluteString.contains(" "))
    }

    func testUnknownStatesReadAsSuch() {
        var unknown = snapshot
        unknown.helperStatus = nil
        unknown.installSource = .direct
        XCTAssertTrue(DiagnosticReport.text(for: unknown).contains("Helper: unknown"))
        XCTAssertTrue(DiagnosticReport.text(for: unknown).contains("Install source: direct download"))
    }

    func testInstallSourceFollowsTheCaskroomEntry() throws {
        let caskroom = FileManager.default.temporaryDirectory.appendingPathComponent("Caskroom-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: caskroom, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: caskroom) }
        XCTAssertEqual(DiagnosticSnapshot.installSource(caskrooms: [caskroom.path]), .homebrewCask)
        XCTAssertEqual(DiagnosticSnapshot.installSource(caskrooms: ["/nonexistent/Caskroom"]), .direct)
    }
}
