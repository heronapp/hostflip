import SwiftUI
import XCTest
@testable import Hostflip

/// Settings > Command Line presents the symlink install command instead of
/// creating the link itself: creating it needs root, and privileged work stays
/// out of the app — the daemon's XPC surface deliberately has exactly one
/// operation (ADR-0009), so the user runs the command in Terminal.
final class CLIInstallPresentationTests: XCTestCase {
    // MARK: Command building

    func testCommandSymlinksTheGivenCLIPathIntoUsrLocalBin() {
        let presentation = CLIInstallPresentation(
            cliPath: "/Applications/Hostflip.app/Contents/Helpers/hostflip",
            linkState: .absent
        )
        XCTAssertEqual(
            presentation.command,
            """
            sudo mkdir -p /usr/local/bin
            sudo ln -sf /Applications/Hostflip.app/Contents/Helpers/hostflip /usr/local/bin/hostflip
            """
        )
    }

    func testCommandSingleQuotesAPathContainingSpaces() {
        let presentation = CLIInstallPresentation(
            cliPath: "/Users/sam/My Apps/Hostflip.app/Contents/Helpers/hostflip",
            linkState: .absent
        )
        XCTAssertTrue(
            presentation.command.contains(
                "sudo ln -sf '/Users/sam/My Apps/Hostflip.app/Contents/Helpers/hostflip' /usr/local/bin/hostflip"
            )
        )
    }

    func testCommandEscapesASingleQuoteInsideTheQuotedPath() {
        let presentation = CLIInstallPresentation(
            cliPath: "/Users/sam/Sam's Apps/Hostflip.app/Contents/Helpers/hostflip",
            linkState: .absent
        )
        XCTAssertTrue(
            presentation.command.contains(
                "sudo ln -sf '/Users/sam/Sam'\\''s Apps/Hostflip.app/Contents/Helpers/hostflip' /usr/local/bin/hostflip"
            )
        )
    }

    // MARK: Status mapping

    func testAbsentLinkPresentsAsNotLinkedAndNeutral() {
        let presentation = CLIInstallPresentation(
            cliPath: "/Applications/Hostflip.app/Contents/Helpers/hostflip",
            linkState: .absent
        )
        XCTAssertEqual(presentation.statusTitle, "Not linked yet")
        XCTAssertNotEqual(presentation.statusColor, .red)
        XCTAssertNotEqual(presentation.statusColor, .orange)
    }

    func testLinkPointingAtThisAppPresentsAsLinked() {
        let cliPath = "/Applications/Hostflip.app/Contents/Helpers/hostflip"
        let presentation = CLIInstallPresentation(
            cliPath: cliPath,
            linkState: .linked(destination: cliPath)
        )
        XCTAssertEqual(presentation.statusTitle, "Linked at /usr/local/bin/hostflip")
        XCTAssertEqual(presentation.statusColor, .green)
    }

    func testLinkPointingElsewherePresentsTheStaleDestination() {
        let presentation = CLIInstallPresentation(
            cliPath: "/Applications/Hostflip.app/Contents/Helpers/hostflip",
            linkState: .linked(destination: "/Users/sam/Old/Hostflip.app/Contents/Helpers/hostflip")
        )
        XCTAssertEqual(
            presentation.statusTitle,
            "Links elsewhere: /Users/sam/Old/Hostflip.app/Contents/Helpers/hostflip"
        )
        XCTAssertEqual(presentation.statusColor, .orange)
    }

    func testNonSymlinkOccupantPresentsAsOccupied() {
        let presentation = CLIInstallPresentation(
            cliPath: "/Applications/Hostflip.app/Contents/Helpers/hostflip",
            linkState: .occupiedByFile
        )
        XCTAssertEqual(
            presentation.statusTitle,
            "Something else occupies /usr/local/bin/hostflip"
        )
        XCTAssertEqual(presentation.statusColor, .orange)
    }

    // MARK: Link probing

    func testProbeReportsAbsentForMissingPath() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let state = CLIInstallProbe.linkState(at: directory.appendingPathComponent("hostflip").path)
        XCTAssertEqual(state, .absent)
    }

    func testProbeReportsOccupiedForRegularFile() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("hostflip")
        try Data().write(to: file)
        XCTAssertEqual(CLIInstallProbe.linkState(at: file.path), .occupiedByFile)
    }

    func testProbeReportsTheLiteralDestinationForASymlink() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let link = directory.appendingPathComponent("hostflip")
        try FileManager.default.createSymbolicLink(
            atPath: link.path,
            withDestinationPath: "/Applications/Hostflip.app/Contents/Helpers/hostflip"
        )
        XCTAssertEqual(
            CLIInstallProbe.linkState(at: link.path),
            .linked(destination: "/Applications/Hostflip.app/Contents/Helpers/hostflip")
        )
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CLIInstallPresentationTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
