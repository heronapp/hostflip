import Foundation

/// Token kinds for hosts syntax (the three categories settled by the #7 research).
public enum HostsTokenKind: Equatable, Sendable {
    case comment
    case ipAddress
    case hostname
}

public struct HostsToken: Equatable, Sendable {
    public let kind: HostsTokenKind
    /// UTF-16 offsets, directly usable with NSTextStorage / NSAttributedString.
    public let range: NSRange

    public init(kind: HostsTokenKind, range: NSRange) {
        self.kind = kind
        self.range = range
    }
}

/// Minimal per-line tokenization rules: from the first `#` to the end of the line is a comment; before the
/// comment, fields are split on whitespace — the first field is the IP (guaranteed by the hosts format, covers
/// IPv4/IPv6 alike), the rest are hostnames. No field validation — highlighting only needs roles, not value correctness.
public enum HostsSyntax {
    private static let fieldPattern = try! NSRegularExpression(pattern: "\\S+")

    public static func tokens(in text: String) -> [HostsToken] {
        let ns = text as NSString
        var tokens: [HostsToken] = []
        ns.enumerateSubstrings(
            in: NSRange(location: 0, length: ns.length),
            options: [.byLines, .substringNotRequired]
        ) { _, lineRange, _, _ in
            var codeRange = lineRange
            let hash = ns.range(of: "#", range: lineRange)
            if hash.location != NSNotFound {
                tokens.append(HostsToken(
                    kind: .comment,
                    range: NSRange(
                        location: hash.location,
                        length: NSMaxRange(lineRange) - hash.location
                    )
                ))
                codeRange.length = hash.location - lineRange.location
            }

            var isFirstField = true
            fieldPattern.enumerateMatches(in: text, range: codeRange) { match, _, _ in
                guard let match else { return }
                tokens.append(HostsToken(
                    kind: isFirstField ? .ipAddress : .hostname,
                    range: match.range
                ))
                isFirstField = false
            }
        }
        return tokens
    }

    /// Structural validation on the same per-line rules: a hosts entry names an IP address and at
    /// least one hostname, so a non-comment line with exactly one field cannot be complete. Field
    /// values stay unvalidated, matching the tokenizer. Returns the 1-based number of the first
    /// incomplete line; nil when every line is blank, comment-only, or a full entry.
    public static func firstIncompleteLine(in text: String) -> Int? {
        let ns = text as NSString
        var lineNumber = 0
        var incompleteLine: Int?
        ns.enumerateSubstrings(
            in: NSRange(location: 0, length: ns.length),
            options: [.byLines, .substringNotRequired]
        ) { _, lineRange, _, stop in
            lineNumber += 1
            var codeRange = lineRange
            let hash = ns.range(of: "#", range: lineRange)
            if hash.location != NSNotFound {
                codeRange.length = hash.location - lineRange.location
            }
            if fieldPattern.numberOfMatches(in: text, options: [], range: codeRange) == 1 {
                incompleteLine = lineNumber
                stop.pointee = true
            }
        }
        return incompleteLine
    }
}
