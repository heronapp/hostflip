import Foundation
import HostflipXPC

/// What a problem report needs and nothing more (#90): versions, environment, helper state,
/// and counts. No profile names, Source URLs, hosts lines, or paths beyond the app's own
/// can enter — the type has no fields for them.
struct DiagnosticSnapshot: Equatable {
    enum InstallSource: Equatable {
        case homebrewCask
        case direct
    }

    struct RemoteFreshness: Equatable {
        /// Seconds since the last successful refresh; nil when it never succeeded.
        var lastSuccessAge: TimeInterval?
        /// The workspace only records that the latest attempt failed, not why (the reason is
        /// shown live, never persisted), and the report must not add persisted data.
        var lastAttemptFailed: Bool
    }

    var appVersion: String
    var build: String
    var macOSVersion: String
    var architecture: String
    var installSource: InstallSource
    var helperStatus: DaemonRegistrationStatus?
    var isPaused: Bool
    var hasHostsDrift: Bool
    var groupCount: Int
    var profileCount: Int
    var activeProfileCount: Int
    var remoteFreshness: [RemoteFreshness]
}

/// Renders the snapshot as plain text for the clipboard and as the prefilled new-issue URL.
/// The text is English only on purpose: it is pasted into an English issue tracker, and a
/// localized report would have to be translated back by whoever reads it.
enum DiagnosticReport {
    static let newIssueURL = URL(string: "https://github.com/heronapp/hostflip/issues/new")!
    static let bugTemplate = "bug_report.yml"

    /// The lines the bug form's Environment field asks for; also the head of the full report.
    static func environment(for snapshot: DiagnosticSnapshot) -> String {
        """
        hostflip \(snapshot.appVersion) (\(snapshot.build))
        macOS: \(snapshot.macOSVersion) (\(snapshot.architecture))
        Install source: \(label(snapshot.installSource))
        Helper: \(snapshot.helperStatus?.rawValue ?? "unknown")
        """
    }

    static func text(for snapshot: DiagnosticSnapshot) -> String {
        var lines = [
            "hostflip \(snapshot.appVersion) (\(snapshot.build)) diagnostic report",
            "macOS: \(snapshot.macOSVersion) (\(snapshot.architecture))",
            "Install source: \(label(snapshot.installSource))",
            "Helper: \(snapshot.helperStatus?.rawValue ?? "unknown")",
            "Paused: \(yesNo(snapshot.isPaused))",
            "Hosts drift detected: \(yesNo(snapshot.hasHostsDrift))",
            "Groups: \(snapshot.groupCount)",
            "Profiles: \(snapshot.profileCount) (active: \(snapshot.activeProfileCount), remote: \(snapshot.remoteFreshness.count))",
        ]
        for (index, remote) in snapshot.remoteFreshness.enumerated() {
            let success = remote.lastSuccessAge.map { "last success \(age($0)) ago" } ?? "never refreshed"
            lines.append("Remote profile \(index + 1): \(success), last attempt failed: \(yesNo(remote.lastAttemptFailed))")
        }
        return lines.joined(separator: "\n")
    }

    static func issueURL(for snapshot: DiagnosticSnapshot) -> URL {
        var components = URLComponents(url: newIssueURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "template", value: bugTemplate),
            URLQueryItem(name: "environment", value: environment(for: snapshot)),
        ]
        // URLComponents keeps "+", "&", and "=" literal inside values; encode everything
        // outside the unreserved set so the multi-line block survives GitHub's query parsing.
        components.percentEncodedQuery = components.queryItems!.map { item in
            let value = item.value ?? ""
            return "\(item.name)=\(value.addingPercentEncoding(withAllowedCharacters: .urlQueryValueAllowed) ?? "")"
        }.joined(separator: "&")
        return components.url!
    }

    private static func label(_ source: DiagnosticSnapshot.InstallSource) -> String {
        switch source {
        case .homebrewCask: "Homebrew cask"
        case .direct: "direct download"
        }
    }

    private static func yesNo(_ value: Bool) -> String { value ? "yes" : "no" }

    /// Coarse "1h 30m" style; a report needs the order of magnitude, not the second.
    private static func age(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        let days = total / 86_400, hours = total % 86_400 / 3_600, minutes = total % 3_600 / 60
        if days > 0 { return "\(days)d \(hours)h" }
        if hours > 0 { return "\(hours)h \(minutes)m" }
        return "\(minutes)m"
    }
}

private extension CharacterSet {
    /// RFC 3986 unreserved characters: everything else is percent-encoded in query values.
    static let urlQueryValueAllowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
}
