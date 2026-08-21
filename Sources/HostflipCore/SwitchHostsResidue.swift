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
    /// shape SwitchHosts itself writes when all rules are off; CRLF content keeps its own
    /// ending). Content without a marker line is returned unchanged — the marker text
    /// inside a longer line (say, a user's comment about SwitchHosts) is not SwitchHosts's
    /// writing and must not cut the file. So is content with nothing but whitespace before
    /// the marker: that is not the shape append mode produces, and an empty Base Hosts
    /// would make hostflip write an empty system hosts whenever no profile is active —
    /// keeping the whole file welds the block in (the pre-#81 behavior), which is the
    /// safer failure.
    public static func stripped(from content: String) -> String {
        guard let markerLineStart = markerLineStart(in: content) else { return content }
        let head = content[..<markerLineStart]
        guard let lastContent = head.lastIndex(where: { !$0.isWhitespace }) else { return content }
        let newline = head.contains("\r\n") ? "\r\n" : "\n"
        return head[...lastContent] + newline
    }

    /// The start of the first line whose whole content is the marker.
    private static func markerLineStart(in content: String) -> String.Index? {
        MergedHosts.lineRange(ofExact: marker, in: content, from: content.startIndex)?.lowerBound
    }
}
