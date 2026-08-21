import CryptoKit
import Foundation

/// The merge output: the full content the privileged daemon rewrites the system hosts with wholesale, plus its stable hash.
/// The hash is the comparison primitive for external-modification detection (#24) and is stored in the manifest with the last write.
public struct MergedHosts: Equatable, Sendable {
    public let content: String
    /// SHA-256 of the content's UTF-8 bytes, lowercase hex.
    public let hash: String

    public init(content: String) {
        self.content = content
        self.hash = Self.hash(of: Data(content.utf8))
    }

    /// Computes the same hash over the system hosts' raw bytes; detection skips decoding the text first, so
    /// malformed UTF-8 is not normalized into replacement characters that would mask an external modification.
    public static func hash(of data: Data) -> String {
        SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

extension MergedHosts {
    /// The fence lines wrapping everything hostflip appends after Base Hosts.
    /// A reader (or a user cleaning up after uninstalling) deletes begin
    /// through end to remove hostflip's entries; Base Hosts above the fence is
    /// the user's own content and carries no hostflip comments at all.
    public static let appendedBlockBegin =
        "# ══ hostflip:begin — delete through hostflip:end to remove ══"
    public static let appendedBlockEnd = "# ══ hostflip:end ══"

    /// Captured content with this manager's own appended block removed (#83): a workspace
    /// deleted while profiles were active leaves the previous install's block in the file,
    /// and — like the SwitchHosts marker (#81) — it is manager-owned output, not the user's
    /// baseline. The block spans the first line that is exactly `appendedBlockBegin` through
    /// the next line that is exactly `appendedBlockEnd`; content after the block is kept.
    /// A begin without an end, or a block with nothing but whitespace before it, returns the
    /// content unchanged — malformed shapes are not guessed at, and an empty Base Hosts would
    /// make a no-profile write empty the system hosts. Removal repeats while blocks remain,
    /// so a file polluted by two successive deleted installs comes fully clean. (A profile
    /// whose own content contains the exact end fence line would cut its block short — no
    /// hosts content has a reason to carry that line, so the shape is not guarded against.)
    public static func removingAppendedBlock(from content: String) -> String {
        var content = content
        while true {
            let removed = removingFirstAppendedBlock(from: content)
            if removed == content { return content }
            content = removed
        }
    }

    private static func removingFirstAppendedBlock(from content: String) -> String {
        guard let begin = lineRange(ofExact: appendedBlockBegin, in: content, from: content.startIndex),
              let end = lineRange(ofExact: appendedBlockEnd, in: content, from: begin.upperBound)
        else { return content }
        // An orphan begin must not pair with a LATER block's end — everything in between,
        // the user's own lines included, would silently go with it. A second begin before
        // the end marks the shape malformed, and malformed shapes are not guessed at.
        if let nextBegin = lineRange(ofExact: appendedBlockBegin, in: content, from: begin.upperBound),
           nextBegin.lowerBound < end.lowerBound {
            return content
        }
        let head = content[..<begin.lowerBound]
        guard let lastContent = head.lastIndex(where: { !$0.isWhitespace }) else { return content }
        var tail = content[end.upperBound...]
        while let first = tail.first, first.isNewline {
            tail = tail.dropFirst()
        }
        let newline = head.contains("\r\n") ? "\r\n" : "\n"
        return head[...lastContent] + newline + tail
    }

    /// The first line in `content` at or after `start` whose whole content is `line`, as the
    /// range from the line's start through its newline (`Character.isNewline` treats CRLF as
    /// one grapheme). Nil when no such line exists. Shared with the SwitchHosts capture strip.
    static func lineRange(
        ofExact line: String,
        in content: String,
        from start: String.Index
    ) -> Range<String.Index>? {
        var lineStart = start
        while lineStart < content.endIndex {
            let lineEnd = content[lineStart...].firstIndex(where: \.isNewline) ?? content.endIndex
            let after = lineEnd < content.endIndex ? content.index(after: lineEnd) : content.endIndex
            if content[lineStart..<lineEnd] == line {
                return lineStart..<after
            }
            lineStart = after
        }
        return nil
    }
    /// The banner releases up to 0.1.1 wrote at the top of the file; still
    /// recognized wherever generated output must be detected.
    public static let legacyGeneratedBanner =
        "# Generated by hostflip — manual edits will be overwritten"
}

extension ActivationModel {
    /// Produces the deterministic merge output from the current domain state: Base Hosts verbatim, then —
    /// only when at least one profile is active — a fenced block holding the active standalone profiles and
    /// each group's active profiles, in container order (= manifest order). When paused or with nothing
    /// active, the output is exactly Base Hosts: no fence, no comments — pausing before uninstalling leaves
    /// a pristine file. Content is concatenated verbatim — no deduplication, no reordering; a newline is
    /// appended only when a block lacks one, so the next marker gets its own line.
    ///
    /// Markers are for human readers only: a grouped profile reads "group/profile", a standalone profile
    /// has no group segment, just its name — no unambiguity guarantee against user-entered names.
    /// External-modification detection compares hashes and never parses the markers.
    public var mergedHosts: MergedHosts {
        var sections: [(title: String, content: String)] = []
        if !isPaused {
            for profile in standaloneProfiles where activeProfileIDs.contains(profile.id) {
                sections.append((profile.name, profile.content))
            }
            for group in groups {
                for profile in group.profiles where activeProfileIDs.contains(profile.id) {
                    sections.append(("\(group.name)/\(profile.name)", profile.content))
                }
            }
        }

        var output = baseHosts.content
        guard !sections.isEmpty else { return MergedHosts(content: output) }

        if !output.isEmpty, output.utf8.last != UInt8(ascii: "\n") {
            output += "\n"
        }
        output += "\n" + MergedHosts.appendedBlockBegin + "\n"
        for section in sections {
            output += "# ── \(section.title) ──\n"
            guard !section.content.isEmpty else { continue }
            output += section.content
            if section.content.utf8.last != UInt8(ascii: "\n") {
                output += "\n"
            }
        }
        output += MergedHosts.appendedBlockEnd + "\n"
        return MergedHosts(content: output)
    }
}
