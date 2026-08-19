import Foundation
import HostflipCore
import XCTest
@testable import Hostflip

/// The SwitchHosts import summary alert copy (#74): every part of the mapping report —
/// counts, Remote Profiles, skips, semantic shifts — must render; nothing may be elided.
final class SwitchHostsImportPresentationTests: XCTestCase {
    func testAPlainImportRendersOnlyTheCountsParagraph() {
        let paragraphs = SwitchHostsImportPresentation.paragraphs(
            for: SwitchHostsImportSummary(profileCount: 3, groupCount: 2)
        )

        XCTAssertEqual(paragraphs, ["Imported 3 profiles from SwitchHosts. Created 2 groups."])
    }

    func testASingleProfileWithoutGroupsUsesTheSingularLine() {
        let paragraphs = SwitchHostsImportPresentation.paragraphs(
            for: SwitchHostsImportSummary(profileCount: 1)
        )

        XCTAssertEqual(paragraphs, ["Imported 1 profile from SwitchHosts."])
    }

    func testRemoteProfilesListNamesWithTheirSourceURLs() {
        let paragraphs = SwitchHostsImportPresentation.paragraphs(for: SwitchHostsImportSummary(
            profileCount: 1,
            remoteProfiles: [.init(
                profileName: "Blocklist",
                sourceURL: "https://rules.example/list.hosts",
                interval: .twentyFourHours
            )]
        ))

        XCTAssertEqual(paragraphs.count, 2)
        XCTAssertEqual(
            paragraphs[1],
            "1 remote rule became a Remote Profile and will fetch content from this URL:\n"
                + "Blocklist — https://rules.example/list.hosts"
        )
    }

    func testSkippedCountsRenderOnlyTheNonZeroLines() {
        let paragraphs = SwitchHostsImportPresentation.paragraphs(for: SwitchHostsImportSummary(
            profileCount: 1,
            skippedSystemEntryCount: 1,
            skippedHistoryEntryCount: 23
        ))

        XCTAssertEqual(paragraphs.count, 2)
        XCTAssertEqual(paragraphs[1], "Skipped:\nSystem hosts entries: 1\nHistory snapshots: 23")
    }

    func testEverySemanticShiftRendersANoteLine() {
        let paragraphs = SwitchHostsImportPresentation.paragraphs(for: SwitchHostsImportSummary(
            profileCount: 4,
            remoteProfiles: [.init(
                profileName: "Weekly",
                sourceURL: "https://rules.example/w.hosts",
                interval: .twentyFourHours,
                adjustedFromSeconds: 604800
            )],
            exclusivityTightenedGroups: ["Overrides"],
            frozenCombinedProfiles: ["combo"],
            downgradedRemotes: [.init(profileName: "Feed", urlString: "http://feed.example/rules")]
        ))

        let notes = try? XCTUnwrap(paragraphs.last)
        XCTAssertTrue(paragraphs.count >= 3)
        let noteLines = (notes ?? "").components(separatedBy: "\n")
        XCTAssertEqual(noteLines.first, "Notes:")
        XCTAssertEqual(noteLines.count, 5)
        XCTAssertTrue(noteLines[1].contains("“Overrides”"), noteLines[1])
        XCTAssertTrue(noteLines[1].contains("mutually exclusive"), noteLines[1])
        XCTAssertTrue(noteLines[2].contains("“combo”"), noteLines[2])
        XCTAssertTrue(noteLines[2].contains("snapshot"), noteLines[2])
        // Durations render through DateComponentsFormatter, so the exact wording is
        // locale-dependent; the note must name the profile and both cadences.
        XCTAssertTrue(noteLines[3].contains("“Weekly”"), noteLines[3])
        XCTAssertTrue(noteLines[3].contains("instead of"), noteLines[3])
        XCTAssertTrue(noteLines[4].contains("“Feed”"), noteLines[4])
        XCTAssertTrue(noteLines[4].contains("http://feed.example/rules"), noteLines[4])
    }

    func testTheDetectedFormatJoinsTheCountsParagraph() {
        let paragraphs = SwitchHostsImportPresentation.paragraphs(
            for: SwitchHostsImportSummary(profileCount: 2, detectedFormat: .v5)
        )

        XCTAssertEqual(paragraphs, [
            "Imported 2 profiles from SwitchHosts. Detected SwitchHosts v5 data."
        ])
    }

    func testAnUnadjustedRemoteProfileAddsNoNoteLine() {
        let paragraphs = SwitchHostsImportPresentation.paragraphs(for: SwitchHostsImportSummary(
            profileCount: 1,
            remoteProfiles: [.init(
                profileName: "Blocklist",
                sourceURL: "https://rules.example/list.hosts",
                interval: .oneHour
            )]
        ))

        XCTAssertFalse(paragraphs.contains { $0.hasPrefix("Notes:") })
    }
}
