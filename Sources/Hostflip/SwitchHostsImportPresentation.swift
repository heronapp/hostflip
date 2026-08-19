import Foundation
import HostflipCore

/// The localized paragraphs of the SwitchHosts import summary alert (#74): counts, the
/// transposed Remote Profiles with their Source URLs, the skipped list, and every deliberate
/// semantic shift. ADR-0013 forbids silent drops and silent shifts, so whatever the summary
/// carries is rendered — nothing is elided.
enum SwitchHostsImportPresentation {
    static func paragraphs(for summary: SwitchHostsImportSummary) -> [String] {
        var paragraphs = [countsLine(for: summary)]
        if !summary.remoteProfiles.isEmpty {
            let header = summary.remoteProfiles.count == 1
                ? String(localized: "1 remote rule became a Remote Profile and will fetch content from this URL:")
                : String(localized: "\(summary.remoteProfiles.count) remote rules became Remote Profiles and will fetch content from these URLs:")
            paragraphs.append(
                header + "\n" + summary.remoteProfiles
                    .map { "\($0.profileName) — \($0.sourceURL)" }
                    .joined(separator: "\n")
            )
        }
        let skipped = skippedLines(for: summary)
        if !skipped.isEmpty {
            paragraphs.append(String(localized: "Skipped:") + "\n" + skipped.joined(separator: "\n"))
        }
        let notes = noteLines(for: summary)
        if !notes.isEmpty {
            paragraphs.append(String(localized: "Notes:") + "\n" + notes.joined(separator: "\n"))
        }
        return paragraphs
    }

    private static func countsLine(for summary: SwitchHostsImportSummary) -> String {
        var line = summary.profileCount == 1
            ? String(localized: "Imported 1 profile from SwitchHosts.")
            : String(localized: "Imported \(summary.profileCount) profiles from SwitchHosts.")
        if summary.groupCount > 0 {
            line += " " + (summary.groupCount == 1
                ? String(localized: "Created 1 group.")
                : String(localized: "Created \(summary.groupCount) groups."))
        }
        if let format = summary.detectedFormat {
            line += " " + String(localized: "Detected SwitchHosts v\(format.rawValue) data.")
        }
        return line
    }

    private static func skippedLines(for summary: SwitchHostsImportSummary) -> [String] {
        var lines: [String] = []
        if summary.skippedSystemEntryCount > 0 {
            lines.append(String(localized: "System hosts entries: \(summary.skippedSystemEntryCount)"))
        }
        if summary.skippedHistoryEntryCount > 0 {
            lines.append(String(localized: "History snapshots: \(summary.skippedHistoryEntryCount)"))
        }
        if summary.skippedTrashedItemCount > 0 {
            lines.append(String(localized: "Trashed items: \(summary.skippedTrashedItemCount)"))
        }
        return lines
    }

    private static func noteLines(for summary: SwitchHostsImportSummary) -> [String] {
        var lines: [String] = []
        for name in summary.exclusivityTightenedGroups {
            lines.append(String(localized: "Profiles in “\(name)” are now mutually exclusive; move a profile out of the group to stack it."))
        }
        for name in summary.frozenCombinedProfiles {
            lines.append(String(localized: "“\(name)” was expanded to a snapshot of its members and will no longer update with them."))
        }
        for remoteProfile in summary.remoteProfiles {
            // Manual is never marked adjusted, so an adjusted entry always has a period.
            guard let seconds = remoteProfile.adjustedFromSeconds,
                  let period = remoteProfile.interval.period
            else { continue }
            lines.append(String(localized: "“\(remoteProfile.profileName)” will refresh every \(duration(seconds: Int(period))) instead of every \(duration(seconds: seconds))."))
        }
        for downgraded in summary.downgradedRemotes {
            lines.append(String(localized: "“\(downgraded.profileName)” was imported as a local profile: \(downgraded.urlString) is not an HTTPS URL."))
        }
        return lines
    }

    /// Durations localize through the formatter (per the app language at runtime), so the
    /// catalogs only carry the sentence around them.
    private static func duration(seconds: Int) -> String {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.day, .hour, .minute]
        formatter.unitsStyle = .full
        return formatter.string(from: TimeInterval(seconds)) ?? "\(seconds)s"
    }
}
