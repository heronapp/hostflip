import Foundation

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
}

/// A command failure carrying the machine contract: the stable string `code` is the authoritative
/// semantic carrier (integrations key on it, never on message text), the message is for humans.
struct CLIError: Error {
    let code: String
    let message: String
    let exitCode: ExitCode

    static func usage(_ message: String) -> CLIError {
        CLIError(code: "usage", message: message, exitCode: .usage)
    }
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
}

/// The `--json` error shape on stderr: `{"error":{"code":…,"message":…}}`. Fields are only ever
/// added to this envelope, never removed or renamed.
struct ErrorEnvelope: Encodable {
    struct Details: Encodable {
        let code: String
        let message: String
    }

    let error: Details
}

enum CLIJSON {
    static func encode(_ value: some Encodable) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        // Payloads are plain strings, booleans, and arrays thereof; encoding cannot fail.
        return String(decoding: try! encoder.encode(value), as: UTF8.self)
    }
}
