import Foundation

/// The SwitchHosts persistence generation a data directory holds (#75, ADR-0013). The raw
/// value is the marketing major version, shown in the import summary's format note.
public enum SwitchHostsFormat: Int, Equatable, Sendable {
    case v3 = 3
    case v4 = 4
    case v5 = 5
}

/// Format detection and the unified read entry over the per-generation readers (#75).
public enum SwitchHostsReader {
    /// The generation stored at this directory, or nil for no SwitchHosts data. Probed
    /// newest first — when several generations' leftovers coexist (an upgraded install
    /// keeps archives around), the newest is the live one (ADR-0013).
    public static func detectFormat(at root: URL) -> SwitchHostsFormat? {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: root.appendingPathComponent("manifest.json").path) {
            return .v5
        }
        if fileManager.fileExists(atPath: root.appendingPathComponent("data/list/tree.json").path) {
            return .v4
        }
        if fileManager.fileExists(atPath: root.appendingPathComponent("data.json").path) {
            return .v3
        }
        return nil
    }

    /// Where the data actually lives for a user-supplied directory: the directory itself,
    /// or its `SwitchHosts.data/` subdirectory — v5 nests the store under that name inside
    /// a custom location, and a manual pick may land on either level. The newest generation
    /// wins across both levels, so older leftovers beside a nested v5 store never shadow it
    /// (the ADR-0013 detection order, applied to the whole candidate set).
    public static func resolveDataRoot(at directory: URL) -> (root: URL, format: SwitchHostsFormat)? {
        [directory, directory.appendingPathComponent("SwitchHosts.data", isDirectory: true)]
            .compactMap { candidate in detectFormat(at: candidate).map { (candidate, $0) } }
            .max { $0.1.rawValue < $1.1.rawValue }
    }

    /// Reads whatever generation the directory holds into the shared intermediate model.
    /// The format tag rides along for the import summary; the mapping engine never sees it.
    public static func read(at directory: URL) throws -> (data: SwitchHostsData, format: SwitchHostsFormat) {
        guard let (root, format) = resolveDataRoot(at: directory) else {
            throw SwitchHostsImportError.dataNotFound
        }
        let data = switch format {
        case .v5: try SwitchHostsV5Reader.read(at: root)
        case .v4: try SwitchHostsV4Reader.read(at: root)
        case .v3: try SwitchHostsV3Reader.read(at: root)
        }
        return (data, format)
    }
}

/// The data directory discovery chain (#75, ADR-0013): default `~/.SwitchHosts` → the v5
/// custom-directory pointer → the v4 archives v5 left behind (#80) → nil, which the UI
/// answers with a manual folder picker.
public enum SwitchHostsDiscovery {
    /// The resolved data root of the first chain link that holds rules, or nil when the
    /// chain is exhausted. v4's Electron userData pointer is deliberately not consulted
    /// (ADR-0013): rare, and the manual pick covers it.
    public static func discoverDataDirectory(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        applicationSupportDirectory: URL? = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first
    ) -> URL? {
        let defaultDirectory = homeDirectory.appendingPathComponent(".SwitchHosts", isDirectory: true)
        var candidates = [defaultDirectory]
        if let applicationSupportDirectory,
           let pointed = customDataDirectory(applicationSupportDirectory: applicationSupportDirectory) {
            candidates.append(pointed)
        }
        candidates.append(contentsOf: v4Archives(under: defaultDirectory))
        for candidate in candidates {
            if let (root, _) = SwitchHostsReader.resolveDataRoot(at: candidate), holdsRules(root) {
                return root
            }
        }
        return nil
    }

    /// Whether a store is worth offering. A live v5 store whose tree holds nothing but the
    /// system entry is what a v4 → v5 upgrade that lost its data leaves behind (#80) — it
    /// reads as empty so the chain moves on to the archive. A store that fails to read
    /// still counts: the import then fails loudly and offers the manual pick, instead of
    /// the corruption being skipped over in silence.
    private static func holdsRules(_ root: URL) -> Bool {
        guard let (data, _) = try? SwitchHostsReader.read(at: root) else { return true }
        return data.items.contains { !$0.isSystem }
    }

    /// `v4/migration-<unix seconds>/` under the default directory: v5's first start moves
    /// the v4 store it migrated from there (its `data/` lands as `data/list/tree.json`, so
    /// the archive reads as a plain v4 root). Newest first; the stamps share a width, so
    /// the lexical order is the numeric one.
    private static func v4Archives(under directory: URL) -> [URL] {
        let archiveRoot = directory.appendingPathComponent("v4", isDirectory: true)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: archiveRoot.path)) ?? []
        return names
            .filter { $0.hasPrefix("migration-") }
            .sorted(by: >)
            .map { archiveRoot.appendingPathComponent($0, isDirectory: true) }
    }

    /// The directory the v5 pointer file names, or nil without a readable pointer. The
    /// pointer lives in v5's config directory (`net.oldj.switchhosts/data_dir.json`); the
    /// key is read in both spellings since only the serialized form is observable.
    private static func customDataDirectory(applicationSupportDirectory: URL) -> URL? {
        let pointerURL = applicationSupportDirectory
            .appendingPathComponent("net.oldj.switchhosts/data_dir.json")
        guard let data = try? Data(contentsOf: pointerURL),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let path = (object["dataDir"] ?? object["data_dir"]) as? String,
              !path.isEmpty
        else { return nil }
        return URL(fileURLWithPath: path)
    }
}

/// Parsing helpers shared by the per-generation readers.
enum SwitchHostsReaderSupport {
    static func decode<Value: Decodable>(
        _ type: Value.Type,
        at url: URL,
        file: String
    ) throws -> Value {
        guard let data = try? Data(contentsOf: url),
              let value = try? JSONDecoder().decode(Value.self, from: data)
        else {
            throw SwitchHostsImportError.malformedData(file: file)
        }
        return value
    }

    /// Every tree entry must carry a unique, non-empty id — content lookup and combined
    /// rules resolve members by id, so a hole or collision would silently misattribute
    /// content. Refusing the batch keeps ADR-0008's one-bad-file-zero-change promise.
    static func validateIDs(of items: [SwitchHostsItem], file: String) throws {
        var seen: Set<String> = []
        var pending = items
        while let item = pending.popLast() {
            guard !item.id.isEmpty, seen.insert(item.id).inserted else {
                throw SwitchHostsImportError.malformedData(file: file)
            }
            if case .folder(_, let children) = item.kind {
                pending.append(contentsOf: children)
            }
        }
    }

    /// Int(exactly:) rejects non-finite and out-of-range doubles instead of trapping;
    /// absurd magnitudes clamp to the nearest representable meaning — a huge positive
    /// cadence stays "very slow" (24h after mapping, disclosed as adjusted), anything
    /// else reads as "never".
    static func clampedSeconds(_ value: Double) -> Int {
        Int(exactly: value.rounded()) ?? (value > 0 ? .max : .min)
    }
}
