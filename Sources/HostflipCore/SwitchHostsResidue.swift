import Foundation

/// The SwitchHosts content block in a system hosts file (#81). SwitchHosts v4
/// (`setSystemHosts.ts`) and v5 (`hosts_apply/write.rs`) both write, in their default
/// append mode, the user's file followed by a marker line and the aggregated rules; turning
/// every rule off rewrites the file as the part before the marker. By SwitchHosts' own
/// contract, then, the marker and everything below it belong to SwitchHosts, not to the
/// baseline — so first capture leaves them out of Base Hosts while `hosts.orig` keeps the
/// full file.
public enum SwitchHostsResidue {
    public static let marker = "# --- SWITCHHOSTS_CONTENT_START ---"

    /// The content with the SwitchHosts block removed: everything before the first line
    /// that is exactly the marker, trailing whitespace collapsed to a single newline (the
    /// shape SwitchHosts itself writes when all rules are off), or the empty string when
    /// the marker leads the file. Content without a marker line is returned unchanged —
    /// the marker text inside a longer line (say, a user's comment about SwitchHosts) is
    /// not SwitchHosts's writing and must not cut the file.
    public static func stripped(from content: String) -> String {
        guard let markerLineStart = markerLineStart(in: content) else { return content }
        var head = String(content[..<markerLineStart])
        while let last = head.unicodeScalars.last, CharacterSet.whitespacesAndNewlines.contains(last) {
            head.unicodeScalars.removeLast()
        }
        return head.isEmpty ? "" : head + "\n"
    }

    /// The start of the first line whose whole content is the marker. `Character.isNewline`
    /// treats CRLF as one grapheme, so lines come out clean in CRLF files too.
    private static func markerLineStart(in content: String) -> String.Index? {
        var lineStart = content.startIndex
        while lineStart < content.endIndex {
            let lineEnd = content[lineStart...].firstIndex(where: \.isNewline) ?? content.endIndex
            if content[lineStart..<lineEnd] == marker {
                return lineStart
            }
            lineStart = lineEnd < content.endIndex ? content.index(after: lineEnd) : content.endIndex
        }
        return nil
    }
}
