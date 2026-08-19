import Foundation

/// Reads a SwitchHosts v3 (Electron, single-file) data directory: `data.json` holds
/// `{list, version}` where the list is the same tree shape as v4 with three field
/// remappings — `where` instead of `type`, refresh intervals in hours instead of
/// seconds, and content inline on each node instead of a collection (#75, ADR-0013).
public enum SwitchHostsV3Reader {
    public static func read(at root: URL) throws -> SwitchHostsData {
        let dataURL = root.appendingPathComponent("data.json")
        guard FileManager.default.fileExists(atPath: dataURL.path) else {
            throw SwitchHostsImportError.dataNotFound
        }
        let file = try SwitchHostsReaderSupport.decode(DataFile.self, at: dataURL, file: "data.json")
        // A version array from another major would mean this is not actually v3 data;
        // an absent array stays tolerated — the earliest 3.x files predate the field.
        if let major = file.version?.first, major != 3 {
            throw SwitchHostsImportError.malformedData(file: "data.json")
        }
        let items = try file.list.map(item(for:))
        try SwitchHostsReaderSupport.validateIDs(of: items, file: "data.json")
        // v3 predates both the trashcan and the standalone history store, so there is
        // nothing to skip-count beyond the tree itself.
        return SwitchHostsData(items: items, historyEntryCount: 0, trashedItemCount: 0)
    }

    private struct DataFile: Decodable {
        var list: [Node]
        var version: [Int]?
    }

    /// One tree node as v3 stores it; `where` is the discriminator (absent reads as a
    /// local rule, matching the other readers' default).
    private struct Node: Decodable {
        var id: String?
        var title: String?
        var kindName: String?
        var content: String?
        var url: String?
        /// Hours, possibly fractional — v3's one unit quirk.
        var refresh_interval: Double?
        var include: [String]?
        var folder_mode: Int?
        var is_sys: Bool?
        var children: [Node]?

        enum CodingKeys: String, CodingKey {
            case id, title, content, url, refresh_interval, include, folder_mode, is_sys, children
            case kindName = "where"
        }
    }

    private static func item(for node: Node) throws -> SwitchHostsItem {
        let kind: SwitchHostsItem.Kind
        switch node.kindName ?? "local" {
        case "local":
            kind = .local
        case "remote":
            kind = .remote(
                urlString: node.url ?? "",
                refreshIntervalSeconds: node.refresh_interval
                    .map { SwitchHostsReaderSupport.clampedSeconds($0 * 3600) }
            )
        case "group":
            kind = .combined(memberIDs: node.include ?? [])
        case "folder":
            kind = .folder(
                isSingleSelection: node.folder_mode == 1,
                children: try (node.children ?? []).map(item(for:))
            )
        default:
            throw SwitchHostsImportError.malformedData(file: "data.json")
        }
        return SwitchHostsItem(
            id: node.id ?? "",
            title: node.title ?? "",
            content: node.content ?? "",
            isSystem: node.is_sys == true,
            kind: kind
        )
    }
}
