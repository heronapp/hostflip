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
        var first: Int?
        enumerateIncompleteLines(in: text) { line, stop in
            first = line
            stop = true
        }
        return first
    }

    /// Every incomplete line, 1-based, on the rule of `firstIncompleteLine` (#87).
    public static func incompleteLines(in text: String) -> [Int] {
        var lines: [Int] = []
        enumerateIncompleteLines(in: text) { line, _ in lines.append(line) }
        return lines
    }

    private static func enumerateIncompleteLines(in text: String, _ body: @escaping (Int, inout Bool) -> Void) {
        let ns = text as NSString
        var lineNumber = 0
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
                var shouldStop = false
                body(lineNumber, &shouldStop)
                if shouldStop { stop.pointee = true }
            }
        }
    }
}

/// Result of a Toggle Comment (#86): `editedRange` (in the old text) replaced by `replacement`
/// yields `text`; `selection` is the range to select afterwards, in the new text.
public struct HostsCommentToggle: Equatable, Sendable {
    public let editedRange: NSRange
    public let replacement: String
    public let selection: NSRange
    public let text: String
}

extension HostsSyntax {
    /// Toggles line comments on every line intersecting `range` (the caret's line when empty);
    /// a selection ending at the start of a line leaves that line out. When every non-blank
    /// target line is commented they are all uncommented, otherwise every non-blank line is
    /// commented — mixed selections end up fully commented. Blank lines are skipped, and a
    /// target of blank lines only is a no-op (nil). Commenting inserts `# ` after the leading
    /// whitespace; uncommenting removes the first `#` and at most one following space.
    /// Offsets are UTF-16 to match the editor's text storage; lines split where NSString's line APIs do.
    public static func toggleComment(in text: String, range: NSRange) -> HostsCommentToggle? {
        let ns = text as NSString
        let firstLine = ns.lineRange(for: NSRange(location: range.location, length: 0))
        // The last target line is the one holding the selection's last character, so a
        // selection ending at a line start leaves that line out.
        let lastLine = range.length > 0
            ? ns.lineRange(for: NSRange(location: NSMaxRange(range) - 1, length: 0))
            : firstLine
        let editedRange = NSRange(
            location: firstLine.location,
            length: NSMaxRange(lastLine) - firstLine.location
        )

        // Walked by hand: enumerateSubstrings(.byLines) skips an empty line at the end of the range,
        // which must still count for the returned selection.
        var lines: [(content: NSRange, terminator: NSRange, indentEnd: Int)] = []
        var position = editedRange.location
        while position < NSMaxRange(editedRange) {
            var start = 0, end = 0, contentsEnd = 0
            ns.getLineStart(&start, end: &end, contentsEnd: &contentsEnd, for: NSRange(location: position, length: 0))
            var indentEnd = start
            while indentEnd < contentsEnd, isIndentation(ns.character(at: indentEnd)) {
                indentEnd += 1
            }
            lines.append((
                NSRange(location: start, length: contentsEnd - start),
                NSRange(location: contentsEnd, length: end - contentsEnd),
                indentEnd
            ))
            position = end
        }
        let nonBlank = lines.filter { $0.indentEnd < NSMaxRange($0.content) }
        guard !nonBlank.isEmpty else { return nil }
        let uncomment = nonBlank.allSatisfy { ns.character(at: $0.indentEnd) == hash }

        var replacement = ""
        var caret = range.location
        var lastContentEnd = editedRange.location
        for line in lines {
            let isBlank = line.indentEnd == NSMaxRange(line.content)
            let indent = ns.substring(with: NSRange(location: line.content.location, length: line.indentEnd - line.content.location))
            let bodyRange = NSRange(location: line.indentEnd, length: NSMaxRange(line.content) - line.indentEnd)
            var body = ns.substring(with: bodyRange)
            var delta = 0
            if !isBlank {
                if uncomment {
                    // UTF-16 slicing, not Character removal: a combining mark after `#` must not go with it.
                    let dropped = bodyRange.length > 1 && ns.character(at: line.indentEnd + 1) == space ? 2 : 1
                    body = ns.substring(with: NSRange(location: line.indentEnd + dropped, length: bodyRange.length - dropped))
                    delta = -dropped
                } else {
                    body = "# " + body
                    delta = 2
                }
            }
            if range.length == 0, caret > line.indentEnd {
                caret = max(line.indentEnd, caret + delta)
            }
            let start = editedRange.location + (replacement as NSString).length
            replacement += indent + body
            lastContentEnd = start + (indent as NSString).length + (body as NSString).length
            replacement += ns.substring(with: line.terminator)
        }

        let selection = range.length == 0
            ? NSRange(location: caret, length: 0)
            : NSRange(location: editedRange.location, length: lastContentEnd - editedRange.location)
        return HostsCommentToggle(
            editedRange: editedRange,
            replacement: replacement,
            selection: selection,
            text: ns.replacingCharacters(in: editedRange, with: replacement)
        )
    }

    private static let hash: unichar = 0x23
    private static let space: unichar = 0x20

    private static func isIndentation(_ character: unichar) -> Bool {
        guard let scalar = Unicode.Scalar(character) else { return false }
        return CharacterSet.whitespaces.contains(scalar)
    }
}
