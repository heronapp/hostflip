import Foundation

/// A portable snapshot of every profile and the group structure (ADR-0008). It deliberately has no
/// fields for Base Hosts, active state, or IDs: Base Hosts is machine-specific, and import always
/// mints fresh IDs, so an export carries names and contents only.
public struct ExportSnapshot: Equatable, Sendable {
    public struct Profile: Equatable, Sendable, Codable {
        public var name: String
        public var content: String

        public init(name: String, content: String) {
            self.name = name
            self.content = content
        }
    }

    public struct Group: Equatable, Sendable, Codable {
        public var name: String
        public var profiles: [Profile]

        public init(name: String, profiles: [Profile]) {
            self.name = name
            self.profiles = profiles
        }
    }

    public var standaloneProfiles: [Profile]
    public var groups: [Group]

    public init(standaloneProfiles: [Profile], groups: [Group]) {
        self.standaloneProfiles = standaloneProfiles
        self.groups = groups
    }

    public init(of model: ActivationModel) {
        standaloneProfiles = model.standaloneProfiles.map {
            Profile(name: $0.name, content: $0.content)
        }
        groups = model.groups.map { group in
            Group(name: group.name, profiles: group.profiles.map {
                Profile(name: $0.name, content: $0.content)
            })
        }
    }

    /// The on-disk export format is versioned from day one; the snapshot structure is a DTO
    /// independent of the workspace manifest, so the two evolve separately.
    static let currentVersion = 1

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(SnapshotFile(
            version: Self.currentVersion,
            standaloneProfiles: standaloneProfiles,
            groups: groups
        ))
    }
}

/// The serialized form of an export file: the snapshot plus the format version.
private struct SnapshotFile: Codable {
    var version: Int
    var standaloneProfiles: [ExportSnapshot.Profile]
    var groups: [ExportSnapshot.Group]
}

public enum ImportError: Error, Equatable, Sendable {
    /// The file was written by a newer hostflip; refuse rather than guess at the format.
    case unsupportedVersion(Int)
    /// The file is JSON but not a valid export snapshot; JSON is never swallowed as plain hosts text.
    case malformedSnapshot
    /// A profile or group name in the snapshot is empty or whitespace-only.
    case blankName
    /// A plain text file that is not valid UTF-8.
    case invalidTextEncoding
}

/// One file selected for import, classified by content.
public enum ImportedContent: Equatable, Sendable {
    case snapshot(ExportSnapshot)
    /// Plain hosts text; lands as one standalone profile named after the file.
    case plainText(name: String, content: String)
}

public enum ImportReader {
    /// Classifies a file: JSON must be a valid versioned snapshot (never falls through to plain
    /// text); anything else is plain hosts text named after the file (extension stripped).
    public static func read(data: Data, fileName: String) throws -> ImportedContent {
        if (try? JSONSerialization.jsonObject(with: data)) != nil {
            return .snapshot(try decodeSnapshot(data))
        }
        guard let content = String(data: data, encoding: .utf8) else {
            throw ImportError.invalidTextEncoding
        }
        return .plainText(name: profileName(fromFileName: fileName), content: content)
    }

    private static func decodeSnapshot(_ data: Data) throws -> ExportSnapshot {
        // The version is probed before full decoding so a future format still reports
        // unsupportedVersion instead of malformedSnapshot.
        struct VersionProbe: Codable {
            var version: Int
        }
        guard let probe = try? JSONDecoder().decode(VersionProbe.self, from: data),
              probe.version >= 1
        else {
            throw ImportError.malformedSnapshot
        }
        guard probe.version <= ExportSnapshot.currentVersion else {
            throw ImportError.unsupportedVersion(probe.version)
        }
        guard let file = try? JSONDecoder().decode(SnapshotFile.self, from: data) else {
            throw ImportError.malformedSnapshot
        }

        let names = file.standaloneProfiles.map(\.name)
            + file.groups.flatMap { [$0.name] + $0.profiles.map(\.name) }
        guard names.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            throw ImportError.blankName
        }
        return ExportSnapshot(standaloneProfiles: file.standaloneProfiles, groups: file.groups)
    }

    private static func profileName(fromFileName fileName: String) -> String {
        let stem = (fileName as NSString).deletingPathExtension
        let isBlank = stem.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return isBlank ? "Untitled" : stem
    }
}

extension ActivationModel {
    /// Appends the snapshot as new, inactive profiles and groups after the existing ones (ADR-0008).
    /// Every object gets a fresh ID; names are kept verbatim, so same-named objects coexist rather
    /// than merge — file-name collisions are the persistence layer's concern, not the model's.
    public mutating func importSnapshot(
        _ snapshot: ExportSnapshot,
        makeProfileID: () -> Profile.ID = { Profile.ID(UUID().uuidString) },
        makeGroupID: () -> Group.ID = { Group.ID(UUID().uuidString) }
    ) throws {
        for profile in snapshot.standaloneProfiles {
            try addProfile(id: makeProfileID(), name: profile.name, content: profile.content)
        }
        for group in snapshot.groups {
            let groupID = makeGroupID()
            try addGroup(id: groupID, name: group.name)
            for profile in group.profiles {
                let profileID = makeProfileID()
                try addProfile(id: profileID, name: profile.name, content: profile.content)
                try moveProfile(profileID, toGroup: groupID)
            }
        }
    }
}
