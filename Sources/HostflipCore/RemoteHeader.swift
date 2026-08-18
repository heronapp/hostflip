import Foundation

/// The Remote Header (ADR-0012): the first line of a Remote Profile's content,
/// `#!hostflip-remote <url> interval=<1h|6h|24h|manual>`. Its presence alone is what makes a
/// profile remote — the manifest carries no remote identity fields — so parsing doubles as the identity
/// check: a malformed line is not an error, it is an ordinary comment line of a local profile
/// (the token starts with `#`, so hosts tooling reads it as a comment either way).
public struct RemoteHeader: Equatable, Sendable {
    /// The preset refresh cadences; raw values are the header's wire syntax.
    public enum RefreshInterval: String, CaseIterable, Sendable {
        case oneHour = "1h"
        case sixHours = "6h"
        case twentyFourHours = "24h"
        case manual = "manual"
    }

    public static let token = "#!hostflip-remote"

    /// The Source URL the content is fetched from. HTTPS-only (ADR-0012): the fetch result is
    /// ultimately written to /etc/hosts as root, so a non-HTTPS line never even reads as remote.
    /// Immutable: the initializer is the only writer, so the validated invariant cannot be
    /// broken after construction — changing the URL means constructing a new header.
    public let sourceURL: URL
    public let interval: RefreshInterval

    /// Whether a URL qualifies as a Source URL: HTTPS with a non-empty host. The single
    /// predicate behind the initializer, `parse`, and the fetch engine, so a constructible
    /// header always serializes to a line that parses back as the same header.
    public static func isValidSourceURL(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https" && !(url.host ?? "").isEmpty
    }

    /// Fails on a URL `isValidSourceURL` rejects: an unconstructible header can never produce
    /// a `line` that `parse` would refuse, keeping the serialize→parse round trip total. The
    /// URL is stored in absolute form — a relative URL resolves against its base here, so the
    /// reparsed header compares equal to the original.
    public init?(sourceURL: URL, interval: RefreshInterval = .twentyFourHours) {
        guard Self.isValidSourceURL(sourceURL),
              let absolute = URL(string: sourceURL.absoluteString) else { return nil }
        self.sourceURL = absolute
        self.interval = interval
    }

    /// Parses the header from a profile's content. Only the first line is consulted (the first
    /// line of the file is the truth); an omitted interval defaults to 24h. Any deviation —
    /// wrong token, leading whitespace, a non-HTTPS or unparseable URL, an unknown interval,
    /// extra fields — yields nil.
    public static func parse(fromContent content: String) -> RemoteHeader? {
        // Character-level isNewline, not a search for "\n": Swift folds CRLF into one Character,
        // which a plain firstIndex(of: "\n") would never match.
        let firstLine = content.firstIndex(where: \.isNewline).map { content[..<$0] } ?? content[...]
        guard firstLine.hasPrefix(token) else { return nil }

        let fields = firstLine.split(whereSeparator: { $0 == " " || $0 == "\t" })
        guard (2...3).contains(fields.count), fields[0] == token else { return nil }
        guard let url = URL(string: String(fields[1])) else { return nil }

        var interval = RefreshInterval.twentyFourHours
        if fields.count == 3 {
            guard fields[2].hasPrefix("interval="),
                  let parsed = RefreshInterval(rawValue: String(fields[2].dropFirst("interval=".count)))
            else { return nil }
            interval = parsed
        }
        // The failable initializer applies the Source URL predicate, so a non-HTTPS or
        // hostless line reads as an ordinary comment of a local profile.
        return RemoteHeader(sourceURL: url, interval: interval)
    }

    /// The canonical serialized header line (no trailing newline). The interval is always spelled
    /// out, including the 24h default, so a stored header never depends on the parser's default.
    public var line: String {
        "\(Self.token) \(sourceURL.absoluteString) interval=\(interval.rawValue)"
    }

    /// The full content a Remote Profile is stored with: this header's line above the fetched
    /// content, escaped first in case its own first line would read as a Remote Header. Creation
    /// and refresh both assemble stored content through here.
    public func storedContent(forFetched fetched: String) -> String {
        line + "\n" + Self.escapingEmbeddedHeader(in: fetched)
    }

    /// The stored content below the Remote Header line — the stored form of the last fetched
    /// body, the inverse of `storedContent(forFetched:)` up to embedded-header escaping. Nil
    /// when the content has no Remote Header. Refresh's "no change after header stripping"
    /// gate (ADR-0012) compares this against the incoming escaped fetch, so a header whose
    /// URL or interval the user edited never counts as a content change.
    public static func storedBody(of content: String) -> String? {
        guard parse(fromContent: content) != nil else { return nil }
        guard let newlineIndex = content.firstIndex(where: \.isNewline) else { return "" }
        return String(content[content.index(after: newlineIndex)...])
    }

    /// Defuses fetched content whose own first line would itself parse as a Remote Header by
    /// commenting the whole content's first line out with a `# ` prefix (ADR-0012): without this,
    /// Convert to Local would strip one header only to expose another, flipping the profile
    /// straight back to remote. Content whose first line does not parse is returned untouched.
    public static func escapingEmbeddedHeader(in content: String) -> String {
        guard parse(fromContent: content) != nil else { return content }
        return "# " + content
    }
}

/// Runtime state of a Remote Profile's refreshes (ADR-0012): the only remote fields the
/// manifest carries, as one optional `remoteRefresh` entry per profile. Deliberately
/// discardable — identity and configuration live in the Remote Header — so an old app
/// version stripping the entry on its next save loses display state, never the subscription
/// (the ADR's degradation promise).
public struct RemoteRefreshState: Codable, Equatable, Sendable {
    /// When a fetch last succeeded and its content was stored; the validation fetch of the
    /// creation (and conversion) dialog counts as the first success.
    public var lastSuccessAt: Date?
    /// Whether the most recent refresh attempt failed; the last successful content stays.
    public var lastAttemptFailed: Bool
    /// The stored content's cache validators, echoed back on the next fetch so an unchanged
    /// source answers 304 instead of a full download (#71).
    public var validators: RemoteContentValidators?

    public init(
        lastSuccessAt: Date? = nil,
        lastAttemptFailed: Bool = false,
        validators: RemoteContentValidators? = nil
    ) {
        self.lastSuccessAt = lastSuccessAt
        self.lastAttemptFailed = lastAttemptFailed
        self.validators = validators
    }
}

extension Profile {
    /// The Remote Header declared on the content's first line; nil for an ordinary local profile.
    public var remoteHeader: RemoteHeader? {
        RemoteHeader.parse(fromContent: content)
    }

    /// Whether this is a Remote Profile: content fetched from its Source URL and shown read-only,
    /// while grouping, activation, and merge semantics stay those of any other profile.
    public var isRemote: Bool {
        remoteHeader != nil
    }
}
