import Foundation

/// SwitchHosts data read from one of its persistence formats (#74, ADR-0013). This is the
/// format-independent intermediate model between the per-version readers and the mapping
/// engine: the v4 reader produces it today, and the v5/v3 readers (M2) will produce the same
/// shape so the engine never learns about on-disk formats.
public struct SwitchHostsData: Equatable, Sendable {
    /// The tree as SwitchHosts shows it: top-level entries and folders, in list order.
    public var items: [SwitchHostsItem]
    /// Records in the history collection; never imported, counted for the summary.
    public var historyEntryCount: Int
    /// Items in the trashcan; never imported, counted for the summary.
    public var trashedItemCount: Int

    public init(items: [SwitchHostsItem], historyEntryCount: Int = 0, trashedItemCount: Int = 0) {
        self.items = items
        self.historyEntryCount = historyEntryCount
        self.trashedItemCount = trashedItemCount
    }
}

/// One entry of the SwitchHosts tree, with its rule content already resolved by the reader.
public struct SwitchHostsItem: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case local
        /// A remote rule: the URL it refreshes from and its refresh cadence in seconds
        /// (nil or non-positive = never). `content` holds the locally cached fetch result.
        case remote(urlString: String, refreshIntervalSeconds: Int?)
        /// A combined rule (SwitchHosts type "group"): its content is its members' contents
        /// joined in `memberIDs` order.
        case combined(memberIDs: [String])
        /// A folder: a container, not a rule. `isSingleSelection` is SwitchHosts folder mode 1,
        /// the only mode matching a native group's in-group mutual exclusion.
        case folder(isSingleSelection: Bool, children: [SwitchHostsItem])
    }

    public var id: String
    public var title: String
    /// The rule text (for remote items: the cached fetch result); empty for containers.
    public var content: String
    /// SwitchHosts' built-in system hosts entry; skipped on import (Base Hosts owns that role).
    public var isSystem: Bool
    public var kind: Kind

    public init(id: String, title: String, content: String = "", isSystem: Bool = false, kind: Kind) {
        self.id = id
        self.title = title
        self.content = content
        self.isSystem = isSystem
        self.kind = kind
    }
}

/// What one SwitchHosts import will do: the snapshot to apply (through the ADR-0008 import
/// path: all inactive, same-named objects coexist, one atomic batch) and the report of how
/// the data was mapped.
public struct SwitchHostsImportPlan: Equatable, Sendable {
    public var snapshot: ExportSnapshot
    public var summary: SwitchHostsImportSummary

    public init(snapshot: ExportSnapshot, summary: SwitchHostsImportSummary) {
        self.snapshot = snapshot
        self.summary = summary
    }
}

/// The full mapping report of one SwitchHosts import (#74): counts, every transposed Remote
/// Profile with its Source URL, everything skipped, and every deliberate semantic shift.
/// ADR-0013 forbids silent drops and silent shifts, so whatever the mapper decides must
/// surface here.
public struct SwitchHostsImportSummary: Equatable, Sendable {
    /// A remote rule transposed to a native Remote Profile.
    public struct RemoteProfile: Equatable, Sendable {
        public var profileName: String
        public var sourceURL: String
        public var interval: RemoteHeader.RefreshInterval
        /// The SwitchHosts cadence in seconds when it had no exact native preset and was
        /// rounded to `interval`; nil when the mapped preset matches the original cadence.
        public var adjustedFromSeconds: Int?

        public init(
            profileName: String,
            sourceURL: String,
            interval: RemoteHeader.RefreshInterval,
            adjustedFromSeconds: Int? = nil
        ) {
            self.profileName = profileName
            self.sourceURL = sourceURL
            self.interval = interval
            self.adjustedFromSeconds = adjustedFromSeconds
        }
    }

    /// A remote rule whose URL cannot be a Source URL (non-HTTPS or unparseable): imported
    /// as a local profile carrying the cached content, reported instead of dropped.
    public struct DowngradedRemote: Equatable, Sendable {
        public var profileName: String
        public var urlString: String

        public init(profileName: String, urlString: String) {
            self.profileName = profileName
            self.urlString = urlString
        }
    }

    public var profileCount: Int
    public var groupCount: Int
    public var remoteProfiles: [RemoteProfile]
    public var skippedSystemEntryCount: Int
    public var skippedHistoryEntryCount: Int
    public var skippedTrashedItemCount: Int
    /// Groups whose SwitchHosts folder allowed stacking several active entries (mode default
    /// or multiple): the group structure survives, the stacking semantics tighten to native
    /// in-group mutual exclusion.
    public var exclusivityTightenedGroups: [String]
    /// Combined rules expanded to a frozen snapshot of their members' contents.
    public var frozenCombinedProfiles: [String]
    public var downgradedRemotes: [DowngradedRemote]
    /// Which SwitchHosts generation the data was read from (#75) — stitched in after
    /// mapping by whoever ran the unified reader, so the mapping engine itself stays
    /// format-blind; nil when the caller read a known format directly.
    public var detectedFormat: SwitchHostsFormat?

    public init(
        profileCount: Int = 0,
        groupCount: Int = 0,
        remoteProfiles: [RemoteProfile] = [],
        skippedSystemEntryCount: Int = 0,
        skippedHistoryEntryCount: Int = 0,
        skippedTrashedItemCount: Int = 0,
        exclusivityTightenedGroups: [String] = [],
        frozenCombinedProfiles: [String] = [],
        downgradedRemotes: [DowngradedRemote] = [],
        detectedFormat: SwitchHostsFormat? = nil
    ) {
        self.profileCount = profileCount
        self.groupCount = groupCount
        self.remoteProfiles = remoteProfiles
        self.skippedSystemEntryCount = skippedSystemEntryCount
        self.skippedHistoryEntryCount = skippedHistoryEntryCount
        self.skippedTrashedItemCount = skippedTrashedItemCount
        self.exclusivityTightenedGroups = exclusivityTightenedGroups
        self.frozenCombinedProfiles = frozenCombinedProfiles
        self.downgradedRemotes = downgradedRemotes
        self.detectedFormat = detectedFormat
    }
}

/// The mapping engine (#74, ADR-0013): SwitchHosts' intermediate model → an import plan.
/// Pure and offline — remote rules are transposed by writing a Remote Header over their
/// cached content, never by fetching.
public enum SwitchHostsMapper {
    /// The rules, in ADR-0013's terms: folders flatten to groups named by their joined path,
    /// top-level loose entries land standalone, remote rules transpose to native Remote
    /// Profiles, combined rules freeze to snapshots, and system entries are skipped and counted.
    public static func plan(for data: SwitchHostsData) -> SwitchHostsImportPlan {
        var builder = Builder(itemsByID: itemsByID(in: data.items))
        builder.walk(data.items, path: [])
        var summary = builder.summary
        summary.profileCount = builder.standaloneProfiles.count
            + builder.groups.reduce(0) { $0 + $1.profiles.count }
        summary.groupCount = builder.groups.count
        summary.skippedHistoryEntryCount = data.historyEntryCount
        summary.skippedTrashedItemCount = data.trashedItemCount
        return SwitchHostsImportPlan(
            snapshot: ExportSnapshot(
                standaloneProfiles: builder.standaloneProfiles,
                groups: builder.groups
            ),
            summary: summary
        )
    }

    /// Maps a SwitchHosts refresh cadence to the largest native preset that fetches at least
    /// as often — a migrated Remote Profile may refresh more often than before, never
    /// silently slower (ADR-0013); sub-hour cadences take 1h, the fastest preset there is,
    /// exactly as #74's table pins (≤3600s→1h). Nil or non-positive is SwitchHosts' "never":
    /// manual. `isAdjusted` reports an inexact match, which the import summary must disclose.
    public static func refreshInterval(
        forSeconds seconds: Int?
    ) -> (interval: RemoteHeader.RefreshInterval, isAdjusted: Bool) {
        guard let seconds, seconds > 0 else { return (.manual, false) }
        if seconds < 21600 { return (.oneHour, seconds != 3600) }
        if seconds < 86400 { return (.sixHours, seconds != 21600) }
        return (.twentyFourHours, seconds != 86400)
    }

    private static func itemsByID(in items: [SwitchHostsItem]) -> [String: SwitchHostsItem] {
        var index: [String: SwitchHostsItem] = [:]
        var pending = items
        while let item = pending.popLast() {
            index[item.id] = item
            if case .folder(_, let children) = item.kind {
                pending.append(contentsOf: children)
            }
        }
        return index
    }

    private struct Builder {
        let itemsByID: [String: SwitchHostsItem]
        var standaloneProfiles: [ExportSnapshot.Profile] = []
        var groups: [ExportSnapshot.Group] = []
        var summary = SwitchHostsImportSummary()

        /// Maps one container's entries: direct entries become this container's profiles
        /// (standalone at the top level, one group per non-empty folder path otherwise),
        /// then each subfolder recurses with its name appended to the path.
        mutating func walk(_ items: [SwitchHostsItem], path: [String], isSingleSelection: Bool = true) {
            var directProfiles: [ExportSnapshot.Profile] = []
            var subfolders: [SwitchHostsItem] = []
            for item in items {
                if item.isSystem {
                    summary.skippedSystemEntryCount += 1
                } else if case .folder = item.kind {
                    subfolders.append(item)
                } else {
                    directProfiles.append(profile(for: item))
                }
            }

            if path.isEmpty {
                standaloneProfiles.append(contentsOf: directProfiles)
            } else if !directProfiles.isEmpty {
                let name = path.joined(separator: " / ")
                groups.append(ExportSnapshot.Group(name: name, profiles: directProfiles))
                // A default- or multiple-mode folder let several entries stack; the group
                // keeps the structure but tightens to in-group mutual exclusion. ADR-0013
                // wants every such folder disclosed, member count regardless.
                if !isSingleSelection {
                    summary.exclusivityTightenedGroups.append(name)
                }
            }

            for folder in subfolders {
                guard case .folder(let single, let children) = folder.kind else { continue }
                walk(children, path: path + [displayName(folder.title)], isSingleSelection: single)
            }
        }

        private mutating func profile(for item: SwitchHostsItem) -> ExportSnapshot.Profile {
            let name = displayName(item.title)
            switch item.kind {
            case .local:
                return ExportSnapshot.Profile(
                    name: name,
                    content: RemoteHeader.escapingEmbeddedHeader(in: item.content)
                )
            case .remote(let urlString, let seconds):
                let (interval, isAdjusted) = SwitchHostsMapper.refreshInterval(forSeconds: seconds)
                guard let url = URL(string: urlString),
                      let header = RemoteHeader(sourceURL: url, interval: interval)
                else {
                    summary.downgradedRemotes.append(.init(profileName: name, urlString: urlString))
                    return ExportSnapshot.Profile(
                        name: name,
                        content: RemoteHeader.escapingEmbeddedHeader(in: item.content)
                    )
                }
                summary.remoteProfiles.append(.init(
                    profileName: name,
                    sourceURL: header.sourceURL.absoluteString,
                    interval: interval,
                    adjustedFromSeconds: isAdjusted ? seconds : nil
                ))
                // The cached fetch result becomes the initial content under the header — the
                // import itself stays offline; the refresh engine takes over from here.
                return ExportSnapshot.Profile(
                    name: name,
                    content: header.storedContent(forFetched: item.content)
                )
            case .combined(let memberIDs):
                summary.frozenCombinedProfiles.append(name)
                let expanded = expandedContent(ofMembers: memberIDs, visited: [item.id])
                return ExportSnapshot.Profile(
                    name: name,
                    content: RemoteHeader.escapingEmbeddedHeader(in: expanded)
                )
            case .folder:
                // Folders never reach here: walk() routes them into recursion.
                return ExportSnapshot.Profile(name: name, content: "")
            }
        }

        /// A combined rule's content: its members' contents joined in include order —
        /// SwitchHosts' own combination semantics, frozen at import time. Remote members
        /// contribute their cached content; folder, system, unknown, and already-visited
        /// members (a cycle) contribute nothing.
        private func expandedContent(ofMembers memberIDs: [String], visited: Set<String>) -> String {
            var chunks: [String] = []
            for memberID in memberIDs {
                guard let member = itemsByID[memberID],
                      !visited.contains(memberID),
                      !member.isSystem
                else { continue }
                switch member.kind {
                case .local, .remote:
                    chunks.append(member.content)
                case .combined(let nested):
                    chunks.append(expandedContent(ofMembers: nested, visited: visited.union([memberID])))
                case .folder:
                    continue
                }
            }
            return chunks.joined(separator: "\n")
        }

        /// SwitchHosts allows blank titles (shown as "(No title)"); imports fall back to the
        /// same default name plain-text file import uses.
        private func displayName(_ title: String) -> String {
            title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Untitled" : title
        }
    }
}
