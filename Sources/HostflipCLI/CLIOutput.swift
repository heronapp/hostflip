import Foundation
import HostflipCore

/// Exit codes shared by every CLI command, aligned with the argparse/Go/bash convention.
/// Codes 3–6 are reserved by the framework for later write/addressing commands; the read-only
/// commands never emit them, but the numbers are fixed here so integrations can rely on them.
enum ExitCode: Int32 {
    case success = 0
    case failure = 1
    case usage = 2
    /// Reserved: a command refused to proceed because the system hosts drifted.
    case drift = 3
    /// Reserved: the privileged daemon is not registered or not reachable.
    case daemonUnavailable = 4
    /// Reserved: a profile reference matched nothing.
    case notFound = 5
    /// Reserved: a profile reference matched more than one candidate.
    case ambiguous = 6
    /// `doctor` completed its diagnosis and found at least one inconsistency (ADR-0014's
    /// diff-style three-state: 0 = consistent, 7 = findings, 1 = the tool itself failed).
    case inconsistent = 7
}

/// A command failure carrying the machine contract: the stable string `code` is the authoritative
/// semantic carrier (integrations key on it, never on message text), the message is for humans.
struct CLIError: Error {
    let code: String
    let message: String
    let exitCode: ExitCode
    /// Present only on ambiguity errors: every profile the reference could mean, feeding both
    /// the human candidate listing and the JSON envelope's `candidates` field.
    var candidates: [ProfileResolver.Candidate]? = nil

    static func usage(_ message: String) -> CLIError {
        CLIError(code: "usage", message: message, exitCode: .usage)
    }

    /// The one drift error, shared by the local pre-check and the daemon's rejection so both
    /// render identically. The CLI only reports drift, it never reconciles (exit code 3 is the
    /// documented "stop and hand back to a human" signal).
    static let hostsDrift = CLIError(
        code: "hosts-drift",
        message: "the system hosts changed outside hostflip; review and reconcile in the Hostflip app",
        exitCode: .drift
    )
}

/// What one invocation produced. Commands return their streams instead of printing so tests can
/// assert on stdout/stderr separation and exit codes without spawning a process.
struct CLIResult {
    let exitCode: ExitCode
    let standardOutput: String
    let standardError: String
}

/// A command's result object: encodable verbatim for `--json`, plus a human-readable rendering.
protocol CommandPayload: Encodable {
    var humanText: String { get }
    /// Verbatim payloads (cat) own their exact bytes; every other human rendering gets a
    /// trailing newline appended by the CLI.
    var humanTextIsVerbatim: Bool { get }
    /// The process exit code of a successful run. doctor reports its verdict through this
    /// (0 = consistent, 7 = inconsistency found) without becoming an error path: the report
    /// belongs on stdout either way.
    var exitCode: ExitCode { get }
    /// Human-mode diagnostics accompanying a result that still belongs on stdout — refresh
    /// reports its per-profile outcomes there while a blocked system hosts write lands here
    /// (#73). Empty for most commands; a non-empty value carries its own trailing newline.
    /// `--json` mode never prints it: the JSON result object carries the same facts.
    var humanStandardError: String { get }
}

extension CommandPayload {
    var humanTextIsVerbatim: Bool { false }
    var exitCode: ExitCode { .success }
    var humanStandardError: String { "" }
}

/// Remote Profile metadata shared by profile payloads: present only when the profile's content
/// declares a Remote Header (ADR-0012), mirroring its Source URL, refresh interval — the
/// interval uses the header's wire syntax (1h/6h/24h/manual) — and Freshness (#77): the last
/// successful refresh time and whether the latest attempt failed.
struct RemoteMetadata: Encodable {
    let url: String
    let interval: String
    /// ISO8601 UTC, or an explicit null before the first success: the key is part of the
    /// contract whenever `remote` is present, so scripts never need an existence check.
    let lastSuccessAt: String?
    let lastAttemptFailed: Bool

    init?(of profile: Profile) {
        guard let header = profile.remoteHeader else { return nil }
        url = header.sourceURL.absoluteString
        interval = header.interval.rawValue
        lastSuccessAt = profile.remoteRefreshState?.lastSuccessAt
            .map { ISO8601DateFormatter().string(from: $0) }
        lastAttemptFailed = profile.remoteRefreshState?.lastAttemptFailed ?? false
    }

    private enum CodingKeys: String, CodingKey {
        case url, interval, lastSuccessAt, lastAttemptFailed
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(url, forKey: .url)
        try container.encode(interval, forKey: .interval)
        // Encoded by hand: the synthesized conformance would drop a nil key entirely.
        try container.encode(lastSuccessAt, forKey: .lastSuccessAt)
        try container.encode(lastAttemptFailed, forKey: .lastAttemptFailed)
    }
}

/// The `--json` error shape on stderr: `{"error":{"code":…,"message":…}}`. Fields are only ever
/// added to this envelope, never removed or renamed.
struct ErrorEnvelope: Encodable {
    struct Details: Encodable {
        let code: String
        let message: String
        /// Present only on ambiguity errors; omitted from the JSON otherwise.
        let candidates: [ProfileResolver.Candidate]?
    }

    let error: Details
}

enum CLIColumns {
    /// Renders non-empty (label, trailing) rows as two aligned columns. Padded by hand:
    /// String.padding(toLength:) counts UTF-16 units and would truncate labels holding
    /// non-BMP characters, corrupting the trailing column.
    static func render(_ rows: [(label: String, trailing: String)]) -> String {
        let width = rows.map(\.label.count).max()! + 2
        return rows
            .map { $0.label + String(repeating: " ", count: width - $0.label.count) + $0.trailing }
            .joined(separator: "\n")
    }
}

enum CLIJSON {
    static func encode(_ value: some Encodable) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        // Payloads are plain strings, booleans, and arrays thereof; encoding cannot fail.
        return String(decoding: try! encoder.encode(value), as: UTF8.self)
    }
}
