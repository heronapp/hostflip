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
                shown = "…" + (lineText as NSString).substring(from: max(0, matchOffsetInLine - Self.contextLength))
            }
            // Column alignment whitespace is noise in a one-line row.
            displayText = shown.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        }
    }

    struct DocumentResult: Equatable, Identifiable {
        let document: Document
        let matches: [Match]
        var id: MainWindowView.SidebarItem { document.item }
    }

    let results: [DocumentResult]
    var matchCount: Int { results.reduce(0) { $0 + $1.matches.count } }

    init(documents: [Document], query: String) {
        results = documents.compactMap { document in
            let hits = HostsSearch.matches(in: document.content, query: query)
            guard !hits.isEmpty else { return nil }
            let ns = document.content as NSString
            return DocumentResult(document: document, matches: hits.map { hit in
                let raw = ns.substring(with: hit.lineRange) as NSString
                let firstNonBlank = raw.rangeOfCharacter(from: CharacterSet.whitespaces.inverted).location
                let leading = firstNonBlank == NSNotFound ? 0 : firstNonBlank
                let lineText = raw.trimmingCharacters(in: .whitespaces)
                let matchOffset = hit.matchRange.location - hit.lineRange.location - leading
                return Match(hit: hit, lineText: lineText, matchOffsetInLine: matchOffset)
            })
        }
    }
}
