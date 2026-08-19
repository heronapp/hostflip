import Foundation

/// Reads a SwitchHosts v5 (Tauri) data directory: `manifest.json` holds the tree with
/// camelCase node fields, and each rule's content lives in the file its `contentFile`
/// names (`entries/<id>.hosts`) — cached fetch results included (#75, ADR-0013). Output
/// is the format-independent intermediate model; everything v5-specific ends here.
public enum SwitchHostsV5Reader {
    public static func read(at root: URL) throws -> SwitchHostsData {
        let manifestURL = root.appendingPathComponent("manifest.json")
        guard FileManager.default.fileExists(atPath: manifestURL.path) else {
            throw SwitchHostsImportError.dataNotFound
        }
        let manifest = try SwitchHostsReaderSupport.decode(
            Manifest.self, at: manifestURL, file: "manifest.json"
        )
        let items = try manifest.root.map { try item(for: $0, root: root) }
        try SwitchHostsReaderSupport.validateIDs(of: items, file: "manifest.json")
        return SwitchHostsData(
            items: items,
            historyEntryCount: try historyEntryCount(at: root),
            trashedItemCount: try trashedItemCount(at: root)
        )
    }

    /// One tree node as v5 serializes it. Everything but `id` is optional on disk; an
    /// absent `type` reads as a local rule, matching the v4 reader's default.
    private struct Manifest: Decodable {
        var root: [Node]
    }

    private struct Node: Decodable {
        var id: String?
        var title: String?
        var type: String?
        /// Path of the rule's content, relative to the data root.
        var contentFile: String?
        /// A remote rule's Source URL — v5 renamed v4's `url`.
        var source: String?
        var refreshIntervalSec: Double?
        var include: [String]?
        var folder: FolderInfo?
        var isSys: Bool?
        var children: [Node]?
    }

    private struct FolderInfo: Decodable {
        /// Same encoding as v4's folder_mode: 1 is single selection, 0/2 allow stacking.
        var mode: Int?
    }

    private static func item(for node: Node, root: URL) throws -> SwitchHostsItem {
        let kind: SwitchHostsItem.Kind
        switch node.type ?? "local" {
        case "local":
            kind = .local
        case "remote":
            kind = .remote(
                urlString: node.source ?? "",
                refreshIntervalSeconds: node.refreshIntervalSec
                    .map(SwitchHostsReaderSupport.clampedSeconds)
            )
        case "group":
            kind = .combined(memberIDs: node.include ?? [])
        case "folder":
            kind = .folder(
                isSingleSelection: node.folder?.mode == 1,
                children: try (node.children ?? []).map { try item(for: $0, root: root) }
            )
        default:
            throw SwitchHostsImportError.malformedData(file: "manifest.json")
        }
        return SwitchHostsItem(
            id: node.id ?? "",
            title: node.title ?? "",
            content: try content(named: node.contentFile, root: root),
            isSystem: node.isSys == true,
            kind: kind
        )
    }

    /// A node without a content file has no content; a named file that is missing or not
    /// UTF-8 fails the whole import (ADR-0008 atomicity). The path must stay inside the
    /// data root: a manifest naming an absolute or `..`-escaping path would otherwise pull
    /// arbitrary readable files into imported content, so it reads as malformed instead.
    private static func content(named contentFile: String?, root: URL) throws -> String {
        guard let contentFile else { return "" }
        guard !contentFile.hasPrefix("/"),
              !contentFile.split(separator: "/").contains(".."),
              let data = try? Data(contentsOf: root.appendingPathComponent(contentFile)),
              let content = String(data: data, encoding: .utf8)
        else {
            throw SwitchHostsImportError.malformedData(file: contentFile)
        }
        return content
    }

    /// v5 keeps the system-hosts apply history (v4's history collection successor) under
    /// `internal/histories/system-hosts.json` as one JSON array of snapshots.
    private static func historyEntryCount(at root: URL) throws -> Int {
        let url = root.appendingPathComponent("internal/histories/system-hosts.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return 0 }
        guard let data = try? Data(contentsOf: url),
              let items = try? JSONSerialization.jsonObject(with: data) as? [Any]
        else {
            throw SwitchHostsImportError.malformedData(file: "internal/histories/system-hosts.json")
        }
        return items.count
    }

    /// The trashcan is informational only (skipped + counted in the summary), so its
    /// items are counted without interpreting their shape.
    private static func trashedItemCount(at root: URL) throws -> Int {
        let url = root.appendingPathComponent("trashcan.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return 0 }
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = object["items"] as? [Any]
        else {
            throw SwitchHostsImportError.malformedData(file: "trashcan.json")
        }
        return items.count
    }
}
