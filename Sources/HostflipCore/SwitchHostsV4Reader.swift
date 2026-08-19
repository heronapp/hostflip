import Foundation

public enum SwitchHostsImportError: Error, Equatable, Sendable {
    /// The directory holds no SwitchHosts data in a supported format (M1: v4 only).
    case dataNotFound
    /// A data file exists but does not parse as expected; the whole import is refused —
    /// one bad file means zero change (ADR-0008). The path is relative to the data directory.
    case malformedData(file: String)
}

/// Reads a SwitchHosts v4 (Electron) data directory — PotDb on disk: `data/list/tree.json`
/// holds the tree, the `data/collection/hosts` collection holds one JSON record per rule's
/// content, keyed back to tree entries by their id (#74, ADR-0013). Output is the
/// format-independent intermediate model; everything v4-specific ends here.
public enum SwitchHostsV4Reader {
    public static func read(at root: URL) throws -> SwitchHostsData {
        let dataDirectory = root.appendingPathComponent("data", isDirectory: true)
        let treeURL = dataDirectory.appendingPathComponent("list/tree.json")
        guard FileManager.default.fileExists(atPath: treeURL.path) else {
            throw SwitchHostsImportError.dataNotFound
        }

        let nodes: [TreeNode] = try SwitchHostsReaderSupport.decode(
            [TreeNode].self, at: treeURL, file: "data/list/tree.json"
        )
        let contentsByID = try contents(
            inCollectionAt: dataDirectory.appendingPathComponent("collection/hosts", isDirectory: true),
            file: "data/collection/hosts"
        )
        let items = try nodes.map { try item(for: $0, contentsByID: contentsByID) }
        try SwitchHostsReaderSupport.validateIDs(of: items, file: "data/list/tree.json")
        return SwitchHostsData(
            items: items,
            historyEntryCount: try recordCount(
                inCollectionAt: dataDirectory.appendingPathComponent("collection/history", isDirectory: true),
                file: "data/collection/history"
            ),
            trashedItemCount: try trashedItemCount(
                at: dataDirectory.appendingPathComponent("list/trashcan.json")
            )
        )
    }

    /// One tree entry as v4 stores it. Everything but `id` is optional on disk; an absent
    /// `type` is a local rule (the common case in real data — v4 only writes the field it
    /// changed away from the default).
    private struct TreeNode: Decodable {
        var id: String?
        var title: String?
        var type: String?
        var url: String?
        var refresh_interval: Double?
        var include: [String]?
        var folder_mode: Int?
        var is_sys: Bool?
        var children: [TreeNode]?
    }

    /// A record of the hosts collection: the content of the tree entry named by `id`.
    private struct ContentRecord: Decodable {
        var id: String?
        var content: String?
    }

    private static func item(
        for node: TreeNode,
        contentsByID: [String: String]
    ) throws -> SwitchHostsItem {
        let id = node.id ?? ""
        let kind: SwitchHostsItem.Kind
        switch node.type ?? "local" {
        case "local":
            kind = .local
        case "remote":
            kind = .remote(
                urlString: node.url ?? "",
                refreshIntervalSeconds: node.refresh_interval
                    .map(SwitchHostsReaderSupport.clampedSeconds)
            )
        case "group":
            kind = .combined(memberIDs: node.include ?? [])
        case "folder":
            // Mode 1 is single selection; 0 (default) and 2 (multiple) allow stacking.
            kind = .folder(
                isSingleSelection: node.folder_mode == 1,
                children: try (node.children ?? []).map { try item(for: $0, contentsByID: contentsByID) }
            )
        default:
            throw SwitchHostsImportError.malformedData(file: "data/list/tree.json")
        }
        return SwitchHostsItem(
            id: id,
            title: node.title ?? "",
            // A rule that was never edited has no collection record: empty content.
            content: contentsByID[id] ?? "",
            isSystem: node.is_sys == true,
            kind: kind
        )
    }

    /// Loads the hosts collection: `ids.json` lists the record file names — with null holes
    /// where records were deleted (PotDb never compacts) — and `data/<n>.json` holds one
    /// record each. A listed record that is missing or unreadable fails the whole import.
    private static func contents(
        inCollectionAt collection: URL,
        file: String
    ) throws -> [String: String] {
        guard let recordIDs = try recordIDs(inCollectionAt: collection, file: file) else { return [:] }
        var contentsByID: [String: String] = [:]
        for recordID in recordIDs {
            let record = try SwitchHostsReaderSupport.decode(
                ContentRecord.self,
                at: collection.appendingPathComponent("data/\(recordID).json"),
                file: "\(file)/data/\(recordID).json"
            )
            guard let treeID = record.id else { continue }
            contentsByID[treeID] = record.content ?? ""
        }
        return contentsByID
    }

    private static func recordCount(inCollectionAt collection: URL, file: String) throws -> Int {
        try recordIDs(inCollectionAt: collection, file: file)?.count ?? 0
    }

    /// The non-null entries of a collection's `ids.json`; nil when the collection does not
    /// exist at all (a valid state — nothing was ever stored in it).
    private static func recordIDs(inCollectionAt collection: URL, file: String) throws -> [String]? {
        let idsURL = collection.appendingPathComponent("ids.json")
        guard FileManager.default.fileExists(atPath: idsURL.path) else { return nil }
        return try SwitchHostsReaderSupport
            .decode([String?].self, at: idsURL, file: "\(file)/ids.json")
            .compactMap(\.self)
    }

    /// The trashcan is informational only (skipped + counted in the summary), so its items
    /// are counted without interpreting their shape.
    private static func trashedItemCount(at url: URL) throws -> Int {
        guard FileManager.default.fileExists(atPath: url.path) else { return 0 }
        guard let data = try? Data(contentsOf: url),
              let items = try? JSONSerialization.jsonObject(with: data) as? [Any]
        else {
            throw SwitchHostsImportError.malformedData(file: "data/list/trashcan.json")
        }
        return items.count
    }
}
