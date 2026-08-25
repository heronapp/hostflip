import Foundation
import HostflipCore

/// Global search across the workspace (#88): every document with at least one matching line,
/// in sidebar order — Base Hosts first, then standalone profiles, then each group's profiles.
struct GlobalSearchResults: Equatable {
    struct Document: Equatable {
        let item: MainWindowView.SidebarItem
        let name: String
        let content: String
        /// Nil for Base Hosts, which is always applied.
        let isActive: Bool?
    }

    struct Match: Equatable, Identifiable {
        let hit: HostsSearch.Hit
        let lineText: String
        /// The line as the narrow sidebar row shows it: matches usually sit in the hostname at
        /// the end of a mapping, so a long prefix folds into "…" plus a little context.
        let displayText: String
        var id: Int { hit.line }

        static let contextLength = 3
        static let foldThreshold = 12

        init(hit: HostsSearch.Hit, lineText: String, matchOffsetInLine: Int) {
            self.hit = hit
            self.lineText = lineText
            var shown = lineText
            if matchOffsetInLine > Self.foldThreshold {
                let ns = lineText as NSString
                // Snap to a character boundary so the fold never splits a surrogate pair.
                let start = ns.rangeOfComposedCharacterSequence(at: matchOffsetInLine - Self.contextLength).location
                shown = "…" + ns.substring(from: start)
            }
            // Column alignment whitespace is noise in a one-line row.
            displayText = shown.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        }
    }

    struct DocumentResult: Equatable, Identifiable {
        let document: Document
        /// At most `matchLimit` rows: a one-letter query hits tens of thousands of lines in a
        /// big Remote Profile, and diffing that many rows per keystroke froze typing.
        let matches: [Match]
        let hiddenMatchCount: Int
        var id: MainWindowView.SidebarItem { document.item }
    }

    static let matchLimit = 100

    /// The trimmed query these results answer.
    let query: String
    let results: [DocumentResult]

    static let empty = GlobalSearchResults(documents: [], query: "")

    init(documents: [Document], query: String) {
        self.query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        results = documents.compactMap { document in
            let hits = HostsSearch.matches(in: document.content, query: query)
            guard !hits.isEmpty else { return nil }
            let ns = document.content as NSString
            let shown = hits.prefix(Self.matchLimit)
            let matches = shown.map { hit -> Match in
                let raw = ns.substring(with: hit.lineRange) as NSString
                let firstNonBlank = raw.rangeOfCharacter(from: CharacterSet.whitespaces.inverted).location
                let leading = firstNonBlank == NSNotFound ? 0 : firstNonBlank
                let lineText = raw.trimmingCharacters(in: .whitespaces)
                let matchOffset = hit.matchRange.location - hit.lineRange.location - leading
                return Match(hit: hit, lineText: lineText, matchOffsetInLine: matchOffset)
            }
            return DocumentResult(document: document, matches: matches, hiddenMatchCount: hits.count - shown.count)
        }
    }
}
