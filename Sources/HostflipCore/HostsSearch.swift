import Foundation

/// Text search across hosts content (#88): case-insensitive substring, one hit per line so
/// results read as "profile · line". Offsets are UTF-16 for the editor's text storage.
public enum HostsSearch {
    public struct Hit: Equatable, Sendable {
        /// 1-based.
        public let line: Int
        /// The line without its terminator.
        public let lineRange: NSRange
        /// The first occurrence on the line.
        public let matchRange: NSRange

        public init(line: Int, lineRange: NSRange, matchRange: NSRange) {
            self.line = line
            self.lineRange = lineRange
            self.matchRange = matchRange
        }
    }

    public static func matches(in text: String, query: String) -> [Hit] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return [] }
        let ns = text as NSString
        var hits: [Hit] = []
        var lineNumber = 0
        ns.enumerateSubstrings(
            in: NSRange(location: 0, length: ns.length),
            options: [.byLines, .substringNotRequired]
        ) { _, lineRange, _, _ in
            lineNumber += 1
            let found = ns.range(of: needle, options: [.caseInsensitive], range: lineRange)
            guard found.location != NSNotFound else { return }
            hits.append(Hit(line: lineNumber, lineRange: lineRange, matchRange: found))
        }
        return hits
    }
}
