import Darwin
import Foundation

/// hostflip's persistent workspace (defaults to `~/Library/Application Support/hostflip/`).
///
/// Directory layout (see the ticket #4 resolution):
/// - `hosts.orig`: pristine backup of the system hosts taken at first capture; kept forever, never rewritten
/// - `base.hosts`: Base Hosts content, updatable in a controlled way by the drift reconciliation flow
/// - `profiles/*.hosts`: each profile's content; file name = profile name (sanitized + conflict suffix)
/// - `manifest.json`: group structure, active state, ordering
/// - `manifest.lock`: dedicated cross-process lock file for manifest read-modify-write (ADR-0010 ①)
public enum WorkspaceError: Error, Equatable, Sendable {
    /// The workspace has residual content (base.hosts or profile files) but no manifest;
    /// it must not be overwritten as a first-run capture and needs manual intervention.
    case residualContentWithoutManifest
    /// The workspace has not completed first capture; domain state cannot be saved and the last-written hash cannot be read or written.
    case notInitialized
}

public struct Workspace: Sendable {
    public let rootDirectory: URL

    /// Default workspace location (`~/Library/Application Support/hostflip/`).
    public static var defaultRootDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("hostflip", isDirectory: true)
    }

    public init(rootDirectory: URL) {
        self.rootDirectory = rootDirectory
    }

    /// Opens the workspace: an empty workspace captures the system hosts as Base Hosts; an initialized
    /// workspace restores from existing data and no longer reads the system hosts.
    public func open(systemHosts: () throws -> String) throws -> ActivationModel {
        if FileManager.default.fileExists(atPath: manifestURL.path) {
            return try load()
        }
        guard !hasResidualContent else {
            throw WorkspaceError.residualContentWithoutManifest
        }
        return try captureSystemHosts(systemHosts)
    }

    /// Opens the workspace without side effects: loads an initialized workspace, or throws
    /// `notInitialized` instead of capturing the system hosts. Read-only clients (the CLI)
    /// must never turn a missing workspace into a first capture.
    public func openReadOnly() throws -> ActivationModel {
        guard FileManager.default.fileExists(atPath: manifestURL.path) else {
            throw WorkspaceError.notInitialized
        }
        return try load()
    }

    /// hosts.orig alone is treated as an interrupted first capture and safe to capture again;
    /// base.hosts or profile files, however, are unreproducible user content.
    private var hasResidualContent: Bool {
        if FileManager.default.fileExists(atPath: baseHostsURL.path) {
            return true
        }
        let profileFiles = (try? FileManager.default.contentsOfDirectory(
            at: profilesDirectory,
            includingPropertiesForKeys: nil
        )) ?? []
        return profileFiles.contains { $0.pathExtension == "hosts" }
    }

    // MARK: - First capture

    private func captureSystemHosts(_ systemHosts: () throws -> String) throws -> ActivationModel {
        let content = try systemHosts()

        try FileManager.default.createDirectory(at: profilesDirectory, withIntermediateDirectories: true)
        try writeOriginalBackupIfAbsent(content)

        let model = try ActivationModel(
            baseHosts: BaseHosts(content: content),
            standaloneProfiles: [],
            groups: []
        )
        try save(model)
        return model
    }

    /// Exclusive creation avoids the check-then-write race of concurrent initialization; an existing backup is never rewritten.
    private func writeOriginalBackupIfAbsent(_ content: String) throws {
        do {
            try Data(content.utf8).write(to: originalBackupURL, options: .withoutOverwriting)
        } catch let error as CocoaError where error.code == .fileWriteFileExists {
            // Backup already exists (an interrupted first capture or concurrent initialization)
        }
    }

    // MARK: - Saving

    public func save(_ model: ActivationModel) throws {
        try save(model, acceptingSystemHostsHash: nil)
    }

    /// Accepts the system hosts the user just reviewed as the new Base Hosts; domain content and the observed
    /// hash are persisted under the same manifest lock, but the system file is not rewritten and hosts.orig stays untouched.
    public func save(
        _ model: ActivationModel,
        acceptingSystemHostsHash acceptedHash: String
    ) throws {
        try save(model, acceptingSystemHostsHash: Optional(acceptedHash))
    }

    private func save(
        _ model: ActivationModel,
        acceptingSystemHostsHash acceptedHash: String?
    ) throws {
        guard FileManager.default.fileExists(atPath: originalBackupURL.path) else {
            throw WorkspaceError.notInitialized
        }
        try withManifestLock {
            try saveLocked(model, acceptingSystemHostsHash: acceptedHash)
        }
    }

    /// The save body proper; the caller must hold the manifest lock.
    private func saveLocked(
        _ model: ActivationModel,
        acceptingSystemHostsHash acceptedHash: String?
    ) throws {
        // Read the old manifest before writing any content files: we must neither discover a corrupt manifest
        // after leaving half a set of new content behind, nor silently reset the stored hash (#24's comparison primitive) to nil.
        let priorLastWrittenHash = FileManager.default.fileExists(atPath: manifestURL.path)
            ? try loadManifest().lastWrittenHash
            : nil
        try FileManager.default.createDirectory(at: profilesDirectory, withIntermediateDirectories: true)
        try write(model.baseHosts.content, to: baseHostsURL)

        let fileNames = assignFileNames(for: model.standaloneProfiles + model.groups.flatMap(\.profiles))
        func writeProfileFile(for profile: Profile) throws -> ManifestProfile {
            let fileName = fileNames[profile.id]!
            try write(profile.content, to: profilesDirectory.appendingPathComponent(fileName))
            return ManifestProfile(
                id: profile.id.rawValue,
                name: profile.name,
                file: fileName,
                remoteRefresh: profile.remoteRefreshState
            )
        }

        let manifest = try Manifest(
            standaloneProfiles: model.standaloneProfiles.map(writeProfileFile),
            groups: model.groups.map { group in
                try ManifestGroup(
                    id: group.id.rawValue,
                    name: group.name,
                    profiles: group.profiles.map(writeProfileFile)
                )
            },
            activeProfileIDs: model.activeProfileIDs.map(\.rawValue).sorted(),
            isPaused: model.isPaused,
            lastWrittenHash: acceptedHash ?? priorLastWrittenHash
        )
        try writeManifest(manifest)

        // Stale profile files are cleaned up only after the manifest is persisted — and best-effort:
        // the manifest write is the commit point, so a cleanup failure must not turn an already
        // committed save into a thrown one (callers that commit in-memory state only on success
        // would diverge from disk). An unremoved stale file is unreferenced and retried next save.
        let expectedFileNames = Set(fileNames.values.map { $0.lowercased() })
        let leftovers = (try? FileManager.default.contentsOfDirectory(
            at: profilesDirectory,
            includingPropertiesForKeys: nil
        )) ?? []
        for url in leftovers
        where url.pathExtension == "hosts" && !expectedFileNames.contains(url.lastPathComponent.lowercased()) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    // MARK: - Reload-and-replay saving (ADR-0010 ②)

    /// Outcome of a reload-and-replay save.
    public enum ReplayedSaveOutcome: Sendable {
        /// The change was applied to the latest on-disk state and the result persisted.
        case saved(ActivationModel)
        /// The change does not apply to the latest on-disk state (e.g. it targets a profile another
        /// process deleted); nothing was written. Carries the untouched latest state and the error
        /// the change threw.
        case conflict(latest: ActivationModel, reason: any Error)
    }

    /// Saves by replaying `change` on the latest on-disk state instead of overwriting the disk with
    /// a model loaded earlier: reload, replay, and write all run under the manifest lock, so changes
    /// another process made since this instance last read the workspace survive the save (ADR-0010 ②).
    public func save(
        applying change: (inout ActivationModel) throws -> Void
    ) throws -> ReplayedSaveOutcome {
        try save(applying: change, acceptingSystemHostsHash: nil)
    }

    /// Reload-and-replay variant of `save(_:acceptingSystemHostsHash:)`.
    public func save(
        applying change: (inout ActivationModel) throws -> Void,
        acceptingSystemHostsHash acceptedHash: String
    ) throws -> ReplayedSaveOutcome {
        try save(applying: change, acceptingSystemHostsHash: Optional(acceptedHash))
    }

    private func save(
        applying change: (inout ActivationModel) throws -> Void,
        acceptingSystemHostsHash acceptedHash: String?
    ) throws -> ReplayedSaveOutcome {
        guard FileManager.default.fileExists(atPath: originalBackupURL.path) else {
            throw WorkspaceError.notInitialized
        }
        return try withManifestLock {
            guard FileManager.default.fileExists(atPath: manifestURL.path) else {
                throw WorkspaceError.notInitialized
            }
            let latest = try load()
            var updated = latest
            do {
                try change(&updated)
            } catch {
                return ReplayedSaveOutcome.conflict(latest: latest, reason: error)
            }
            try saveLocked(updated, acceptingSystemHostsHash: acceptedHash)
            return .saved(updated)
        }
    }

    private func writeManifest(_ manifest: Manifest) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        // ISO8601 keeps the remote refresh timestamps human-readable in manifest.json; the
        // manifest had no date fields before, so the strategy changes no existing key.
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(manifest).write(to: manifestURL, options: .atomic)
    }

    // MARK: - Last-written hash

    /// The output hash (`MergedHosts.hash`) of the last successful merge write to the system hosts;
    /// nil if nothing has been written yet. External-modification detection (#24) compares against this baseline.
    public func lastWrittenHash() throws -> String? {
        try requireManifest().lastWrittenHash
    }

    /// The hash the system hosts should currently have. After a successful merge write, the daemon-confirmed value wins;
    /// before any write it falls back to the read-only pristine snapshot from first capture, so even the first write has a verifiable baseline.
    public func expectedSystemHostsHash() throws -> String {
        if let lastWrittenHash = try requireManifest().lastWrittenHash {
            return lastWrittenHash
        }
        return MergedHosts.hash(of: try Data(contentsOf: originalBackupURL))
    }

    /// Records the hash after a successful merge write; only this field is updated, domain state is left untouched.
    public func recordLastWrittenHash(_ hash: String) throws {
        try withManifestLock {
            var manifest = try requireManifest()
            manifest.lastWrittenHash = hash
            try writeManifest(manifest)
        }
    }

    /// Reading or writing the last-written hash requires the manifest to exist (guaranteed once open has completed first capture).
    private func requireManifest() throws -> Manifest {
        guard FileManager.default.fileExists(atPath: manifestURL.path) else {
            throw WorkspaceError.notInitialized
        }
        return try loadManifest()
    }

    // MARK: - Loading

    private func loadManifest() throws -> Manifest {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(Manifest.self, from: Data(contentsOf: manifestURL))
    }

    private func load() throws -> ActivationModel {
        let manifest = try loadManifest()
        let baseContent = try String(contentsOf: baseHostsURL, encoding: .utf8)

        func profile(from entry: ManifestProfile) throws -> Profile {
            try Profile(
                id: .init(entry.id),
                name: entry.name,
                content: String(
                    contentsOf: profilesDirectory.appendingPathComponent(entry.file),
                    encoding: .utf8
                ),
                remoteRefreshState: entry.remoteRefresh
            )
        }

        return try ActivationModel(
            baseHosts: BaseHosts(content: baseContent),
            standaloneProfiles: manifest.standaloneProfiles.map(profile),
            groups: manifest.groups.map { group in
                try Group(
                    id: .init(group.id),
                    name: group.name,
                    profiles: group.profiles.map(profile)
                )
            },
            activeProfileIDs: Set(manifest.activeProfileIDs.map(Profile.ID.init)),
            isPaused: manifest.isPaused
        )
    }

    // MARK: - Profile file names

    /// File name = profile name; characters illegal in macOS file names are replaced, and name collisions
    /// (including collisions on case-insensitive file systems) get a ` 2`, ` 3`… suffix. Suffixes are stable: a file
    /// name from the previous manifest that still matches the current profile name is reused as is, so reordering
    /// never makes same-named profiles swap files.
    private func assignFileNames(for profiles: [Profile]) -> [Profile.ID: String] {
        let priorFileNames: [Profile.ID: String] = (try? loadManifest()).map { manifest in
            let entries = manifest.standaloneProfiles + manifest.groups.flatMap(\.profiles)
            return Dictionary(entries.map { (Profile.ID($0.id), $0.file) }) { first, _ in first }
        } ?? [:]

        var assigned: [Profile.ID: String] = [:]
        // Every file name referenced by the previous manifest stays reserved for its original owner and is
        // off-limits to other profiles: no file write before the manifest lands can overwrite content the old
        // manifest references (swap-renames are safe too), so the old state is fully recoverable if a save fails midway.
        var taken = Set(priorFileNames.values.map { $0.lowercased() })

        for profile in profiles {
            guard let prior = priorFileNames[profile.id],
                  fileName(prior, matchesBase: sanitizedBase(for: profile.name))
            else { continue }
            assigned[profile.id] = prior
        }

        for profile in profiles where assigned[profile.id] == nil {
            let base = sanitizedBase(for: profile.name)
            var candidate = base
            var counter = 2
            while !taken.insert("\(candidate).hosts".lowercased()).inserted {
                candidate = "\(base) \(counter)"
                counter += 1
            }
            assigned[profile.id] = "\(candidate).hosts"
        }
        return assigned
    }

    private func sanitizedBase(for name: String) -> String {
        let illegalCharacters = CharacterSet(charactersIn: "/:\0")
        let base = name.components(separatedBy: illegalCharacters).joined(separator: "-")
        return base.isEmpty ? "Untitled" : base
    }

    /// Whether this file name belongs to the given sanitized profile name (`base.hosts` or `base N.hosts`).
    private func fileName(_ fileName: String, matchesBase base: String) -> Bool {
        let fileName = fileName.lowercased()
        let base = base.lowercased()
        guard fileName.hasSuffix(".hosts") else { return false }
        let stem = String(fileName.dropLast(".hosts".count))
        if stem == base { return true }
        guard stem.hasPrefix(base + " ") else { return false }
        return Int(stem.dropFirst(base.count + 1)) != nil
    }

    // MARK: - Manifest mutual exclusion

    /// Read-modify-write mutual exclusion for the manifest (one lock per workspace directory): main-window
    /// edits persist synchronously on the MainActor (save), while merge confirmation writes the hash back on a
    /// background task chain (recordLastWrittenHash); without mutual exclusion, running concurrently would
    /// overwrite the other side's freshly written manifest with stale values (#20 re-review).
    private static let manifestLocks = ManifestLockRegistry()

    private func withManifestLock<T>(_ body: () throws -> T) throws -> T {
        let lock = Self.manifestLocks.lock(forPath: rootDirectory.standardizedFileURL.path)
        lock.lock()
        defer { lock.unlock() }
        return try withCrossProcessManifestLock(body)
    }

    /// Serializes manifest read-modify-write across processes (CLI and resident GUI as peer writers,
    /// ADR-0010 ①) with an exclusive flock. The lock lives on a dedicated lock file, never on
    /// manifest.json itself: the manifest is atomically replaced, and rename would leave the lock
    /// attached to a file no other process opens anymore. The in-process NSLock stays in front, so the
    /// kernel lock only ever mediates between processes and existing in-process semantics are unchanged.
    /// flock is released by the kernel when its holder exits, so a crash cannot leave a stale deadlock;
    /// the leftover lock file itself is inert.
    private func withCrossProcessManifestLock<T>(_ body: () throws -> T) throws -> T {
        let fd = Darwin.open(manifestLockURL.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o644)
        guard fd >= 0 else {
            // The lock file's parent directory is missing, i.e. there is no workspace to lock.
            if errno == ENOENT { throw WorkspaceError.notInitialized }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        // Closing the descriptor releases the flock.
        defer { close(fd) }
        while flock(fd, LOCK_EX) != 0 {
            guard errno == EINTR else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        }
        return try body()
    }

    // MARK: - Cross-process change notification (ADR-0010 ③)

    /// Distributed notification a writer (the CLI) posts after changing the workspace on disk so a
    /// running GUI can refresh its display. Post with the workspace's `changeNotificationObject` as
    /// the object and `deliverImmediately: true`. The channel is unauthenticated and unreliable —
    /// a display-refresh optimization only: receipt may trigger a re-read of the workspace but must
    /// never be trusted beyond that, and correctness must not depend on delivery.
    public static let changeNotification = Notification.Name("com.heronapp.hostflip.workspace-changed")

    /// The notification object identifying this workspace: observers filter on it so workspaces at
    /// different roots do not trigger each other.
    public var changeNotificationObject: String {
        rootDirectory.standardizedFileURL.path
    }

    // MARK: - File layout

    private var originalBackupURL: URL { rootDirectory.appendingPathComponent("hosts.orig") }
    private var baseHostsURL: URL { rootDirectory.appendingPathComponent("base.hosts") }
    private var manifestURL: URL { rootDirectory.appendingPathComponent("manifest.json") }
    private var manifestLockURL: URL { rootDirectory.appendingPathComponent("manifest.lock") }
    private var profilesDirectory: URL { rootDirectory.appendingPathComponent("profiles", isDirectory: true) }

    private func write(_ content: String, to url: URL) throws {
        try Data(content.utf8).write(to: url, options: .atomic)
    }
}

/// Hands out mutual-exclusion locks keyed by workspace path; Workspace is a value type, so locks must live in
/// a path-keyed shared registry for all instances over the same directory to actually exclude each other.
private final class ManifestLockRegistry: @unchecked Sendable {
    private let registryLock = NSLock()
    private var locks: [String: NSLock] = [:]

    func lock(forPath path: String) -> NSLock {
        registryLock.withLock {
            if let existing = locks[path] { return existing }
            let created = NSLock()
            locks[path] = created
            return created
        }
    }
}

private struct Manifest: Codable {
    var version = 1
    var standaloneProfiles: [ManifestProfile]
    var groups: [ManifestGroup]
    var activeProfileIDs: [String]
    var isPaused: Bool
    /// The output hash of the last merge write to the system hosts; old manifests that never wrote lack this key.
    var lastWrittenHash: String?
}

private struct ManifestProfile: Codable {
    var id: String
    var name: String
    var file: String
    /// Runtime state of a Remote Profile's refreshes (ADR-0012): optional and discardable —
    /// an app version without this field strips it on its next save, losing nothing but
    /// display state (the subscription lives in the content's Remote Header).
    var remoteRefresh: RemoteRefreshState?
}

private struct ManifestGroup: Codable {
    var id: String
    var name: String
    var profiles: [ManifestProfile]
}
