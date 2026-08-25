import Foundation
import HostflipCore
import HostflipXPC
import Observation

/// Result feedback for one activation switch (#21): a switch must conclude with success or
/// failure, unlike the silent follow-up merge after an edit is saved.
enum SwitchFeedback: Equatable {
    /// The merge finished; the system hosts has been updated.
    case merged
    /// The user accepted the current system hosts as the new Base Hosts; the system file itself was not rewritten.
    case baseHostsReplaced
    /// Waiting for the system to approve the helper; guides the user to open System Settings.
    case needsApproval
    /// The helper is unavailable; guides the user to reinstall.
    case unavailable
    /// The system hosts contains unhandled external modifications; to protect the unknown content, this switch was not sent.
    case hostsDrift
    case failed(String)

    var title: String {
        switch self {
        case .merged: String(localized: "System Hosts Updated")
        case .baseHostsReplaced: String(localized: "Base Hosts Replaced")
        case .needsApproval: String(localized: "Approval Required")
        case .unavailable: String(localized: "Helper Unavailable")
        case .hostsDrift: String(localized: "Hosts Drift Detected")
        case .failed: String(localized: "Switch Failed")
        }
    }

    var message: String {
        switch self {
        case .merged:
            String(localized: "System hosts file updated")
        case .baseHostsReplaced:
            String(localized: "Base Hosts replaced with the current /etc/hosts content. The system file was not changed.")
        case .needsApproval:
            String(localized: "Switch blocked: hostflip’s background helper needs system approval")
        case .unavailable:
            String(localized: "Helper unavailable: move the app to the Applications folder and reopen it")
        case .hostsDrift:
            String(localized: "Switch blocked: system hosts contains changes made outside hostflip")
        case .failed(let message):
            message
        }
    }
}

enum HostsReconciliationChoice {
    case addDriftLinesToBaseHosts
    case overwriteDriftWithActiveState
    case later
}

/// Result of one import (#40): either every file was applied — summarized for the user (#69) —
/// or none was.
enum ImportOutcome: Equatable {
    case imported(ImportSummary)
    case failed(String)
}

/// Result of one SwitchHosts import (#74): the full mapping report on success — counts,
/// transposed Remote Profiles, skips, and semantic shifts — or a failure with zero change.
enum SwitchHostsImportOutcome: Equatable {
    case imported(SwitchHostsImportSummary)
    case failed(String)
}

/// Result of the create-remote-profile flow (ADR-0012): success dismisses the dialog and selects
/// the new profile; failure keeps it open with display copy so the user can retry or cancel.
enum RemoteProfileCreationOutcome: Equatable {
    case created(Profile.ID)
    case failed(String)
}

/// A local profile's edit whose new first line parses as a Remote Header, held for confirmation
/// (ADR-0012): the stored content stays untouched until the user confirms and the validation
/// fetch passes, so an accidental header can never flip a profile silently.
struct PendingRemoteConversion: Equatable {
    let profileID: Profile.ID
    /// The full edited content as typed; shown in the editor while the confirmation is up, and
    /// discarded whole on cancel or failure.
    let draftContent: String
    /// The stored content the draft was typed over: confirming validates against it under the
    /// manifest lock, so a conversion can never overwrite what an external writer saved while
    /// the validation fetch was in flight.
    let baselineContent: String
    let header: RemoteHeader
}

/// Result of confirming a held local→remote conversion: success dismisses the dialog; failure
/// keeps the draft held with display copy so the user can retry or cancel.
enum RemoteConversionOutcome: Equatable {
    case converted
    case failed(String)
}

/// Result of editing a Remote Profile's Source URL or interval (ADR-0012): failure carries
/// display copy and leaves the old header and content untouched.
enum RemoteProfileEditOutcome: Equatable {
    case updated
    case failed(String)
}

/// Domain state for the main window (#20/#21/#22): opens the workspace, shows hosts, manages profiles and groups.
/// Saving does not go through the helper — every edit is written to disk synchronously, leaving no
/// window for loss; when already approved, a debounced follow-up merge runs separately
/// (mergeIfAuthorized, which never triggers registration), avoiding rewriting the system hosts and
/// flushing DNS on every keystroke. An activation switch (setProfileActive) takes the authorization
/// flow instead: the active state is committed and persisted only after the merge succeeds; on
/// failure the state returns to what it was and feedback is presented.
@MainActor
@Observable
final class WorkspaceStore {
    /// Every mutation path assigns through here (the model is a struct, so in-place edits
    /// set it too), making didSet the single choke point that keeps the refresh scheduler's
    /// view current (#71) — interval edits, refresh results, and external changes included.
    private(set) var model: ActivationModel? {
        didSet { remoteScheduleChanged?() }
    }
    /// Pokes the refresh scheduler after any model change; wired at launch, nil in tests
    /// that exercise the store alone.
    @ObservationIgnored var remoteScheduleChanged: (() -> Void)?
    /// Display copy for a failed workspace open (e.g. leftover content that needs manual handling).
    private(set) var loadError: String?
    /// The most recent local workspace save failure; stays nil on success (silent).
    private(set) var saveError: String?
    /// Failure copy from the background follow-up merge of the system hosts after an edit saved successfully.
    private(set) var backgroundSyncError: String?
    /// Result of the most recent activation switch; cleared when a new switch starts.
    private(set) var switchFeedback: SwitchFeedback?
    /// A switch is in flight: switch controls should be disabled to keep concurrent switches from interleaving.
    private(set) var isSwitching = false
    /// The in-flight switch task; tests await its completion before asserting the result.
    private(set) var switchTask: Task<Void, Never>?
    /// The system hosts differs from the last confirmed baseline; watching is unaffected by the paused state.
    private(set) var hasHostsDrift = false
    /// The single snapshot of the observed state used for both user review and safe reconciliation.
    private(set) var hostsDriftComparison: HostsDriftComparison?
    /// Read-only UTF-8 snapshot of the current system hosts; independent of the workspace model.
    private(set) var systemHostsContent: String?
    private(set) var systemHostsReadError: String?
    private(set) var isReconciling = false
    private(set) var reconciliationTask: Task<Void, Never>?
    private(set) var reconciliationError: String?

    private let workspace: Workspace
    private let coordinator: any SwitchCoordinating
    private let driftMonitor: (any HostsDriftMonitoring)?
    private let readSystemHosts: @Sendable () throws -> Data
    /// Entry point for approval guidance (opens the Login Items pane in System Settings); tests inject a no-op.
    private let openApproval: @Sendable () -> Void
    /// Fetches and validates a Source URL's content (RemoteFetcher), conditionally when
    /// stored validators are passed (#71); tests inject canned outcomes.
    private let fetchRemote: @Sendable (URL, RemoteContentValidators?) async throws -> RemoteFetchOutcome
    /// Clock for recording refresh success times; tests inject a fixed date.
    private let now: @Sendable () -> Date
    /// Remote Profiles with a refresh in flight: their refresh entries are disabled and their
    /// rows show a spinner instead of the failure marker.
    private(set) var refreshingProfileIDs: Set<Profile.ID> = []
    /// When each Remote Profile's refresh last actually started — manual and scheduled alike
    /// (#71) — in-memory only: the scheduler spaces the next attempt one interval after the
    /// newest one, so a failing source is not re-fetched on every evaluation and a manual
    /// failure is not immediately followed by a scheduled retry. Reset by a relaunch, so the
    /// startup catch-up retries an overdue failing profile once.
    @ObservationIgnored private var remoteRefreshAttempts: [Profile.ID: Date] = [:]
    /// Display copy for each profile's most recent refresh failure, in-memory only — the
    /// manifest persists just the failed flag, so after a relaunch the marker shows without
    /// the detailed copy.
    private(set) var remoteRefreshErrors: [Profile.ID: String] = [:]
    /// A local profile's edit held for local→remote confirmation (ADR-0012); nil while no
    /// conversion dialog is up.
    private(set) var pendingRemoteConversion: PendingRemoteConversion?
    /// The in-flight follow-up merge task; tests await its completion before asserting the result.
    private(set) var followUpMergeTask: Task<Void, Never>?
    private var hostsDriftGeneration = 0
    /// While a reconcile has written the system hosts but the latest reviewed state or the
    /// workspace persistence is not yet confirmed, keep blocking new writes even if the
    /// monitor briefly reports no drift.
    private var reconciliationNeedsAttention = false
    /// DistributedNotificationCenter observer token for external workspace-change signals
    /// (ADR-0010 ③); registered by the production initializer only. Not observation state, and
    /// nonisolated(unsafe) because the nonisolated deinit reads it — it is written only once.
    @ObservationIgnored nonisolated(unsafe) private var externalChangeObserver: (any NSObjectProtocol)?

    deinit {
        if let externalChangeObserver {
            DistributedNotificationCenter.default().removeObserver(externalChangeObserver)
        }
    }

    convenience init(registrar: DaemonRegistrar) {
        let workspace = Workspace(rootDirectory: Workspace.defaultRootDirectory)
        let hostsURL = URL(fileURLWithPath: "/etc/hosts")
        let driftMonitor = HostsDriftMonitor(workspace: workspace, hostsURL: hostsURL)
        self.init(
            workspace: workspace,
            coordinator: SwitchCoordinator(
                registrar: registrar,
                coordinator: MergeCoordinator(
                    workspace: workspace,
                    client: DaemonClient(),
                    confirmedWriteTracker: driftMonitor
                ),
                expectedWriteObserver: driftMonitor
            ),
            openApproval: { registrar.openApprovalSettings() },
            driftMonitor: driftMonitor,
            readSystemHosts: { try Data(contentsOf: hostsURL) }
        )
        observeExternalWorkspaceChanges()
    }

    /// Injection seam: tests substitute a temporary workspace + a coordinator stub for real XPC.
    init(
        workspace: Workspace,
        coordinator: any SwitchCoordinating,
        openApproval: @escaping @Sendable () -> Void = {},
        driftMonitor: (any HostsDriftMonitoring)? = nil,
        readSystemHosts: @escaping @Sendable () throws -> Data = {
            try Data(contentsOf: URL(fileURLWithPath: "/etc/hosts"))
        },
        fetchRemote: @escaping @Sendable (URL, RemoteContentValidators?) async throws -> RemoteFetchOutcome = { url, validators in
            try await RemoteFetcher().fetch(from: url, validators: validators)
        },
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.workspace = workspace
        self.coordinator = coordinator
        self.openApproval = openApproval
        self.driftMonitor = driftMonitor
        self.readSystemHosts = readSystemHosts
        self.fetchRemote = fetchRemote
        self.now = now
    }

    /// Idempotent open: the first call captures or restores the workspace; later calls reuse the in-memory model.
    func loadIfNeeded() {
        guard model == nil, loadError == nil else { return }
        do {
            model = try workspace.open(systemHosts: {
                let data = try readSystemHosts()
                guard let content = String(data: data, encoding: .utf8) else {
                    throw CocoaError(.fileReadInapplicableStringEncoding)
                }
                return content
            })
            refreshSystemHosts()
            driftMonitor?.start { [weak self] hasDrift in
                guard let self else { return }
                self.refreshSystemHosts()
                if !hasDrift, self.isReconciling || self.reconciliationNeedsAttention {
                    self.hasHostsDrift = true
                    return
                }
                self.hasHostsDrift = hasDrift
                if hasDrift {
                    self.refreshHostsDriftComparison()
                } else {
                    self.hostsDriftComparison = nil
                    if self.switchFeedback == .hostsDrift {
                        self.reconciliationError = nil
                        self.switchFeedback = nil
                    }
                }
            }
        } catch {
            loadError = String(localized: "Cannot open workspace: \(String(describing: error))")
        }
    }

    var baseHostsContent: String {
        model?.baseHosts.content ?? ""
    }

    func refreshSystemHosts() {
        do {
            let data = try readSystemHosts()
            guard let content = String(data: data, encoding: .utf8) else {
                systemHostsContent = nil
                systemHostsReadError = String(localized: "Cannot display /etc/hosts because it is not valid UTF-8.")
                return
            }
            systemHostsContent = content
            systemHostsReadError = nil
        } catch {
            systemHostsContent = nil
            systemHostsReadError = String(localized: "Cannot read /etc/hosts: \(String(describing: error))")
        }
    }

    /// Subscribes to the external writers' change signal (ADR-0010 ③), filtered to this
    /// workspace. Production wiring only: tests drive refreshFromExternalChange directly.
    private func observeExternalWorkspaceChanges() {
        let refresh: @MainActor @Sendable () -> Void = { [weak self] in
            self?.refreshFromExternalChange()
        }
        externalChangeObserver = DistributedNotificationCenter.default().addObserver(
            forName: Workspace.changeNotification,
            object: workspace.changeNotificationObject,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated(refresh)
        }
    }

    /// Re-reads the workspace after an external writer announced a change (ADR-0010 ③) and
    /// refreshes the display; the notification is untrusted, so receipt only ever triggers this
    /// re-read. Skipped whenever local state may diverge from disk — a failed save keeps unsaved
    /// edits in memory, and an in-flight switch or reconciliation commits through its own
    /// reload-and-replay — those paths reconcile with external changes at save time instead.
    func refreshFromExternalChange() {
        // Always re-evaluate drift, even when the model refresh below is skipped: the writer's
        // hosts file event may have outrun its manifest record, and this notification (posted
        // after the record) is what clears the resulting stale drift verdict.
        driftMonitor?.recheck()
        guard model != nil, saveError == nil, !isSwitching, !isReconciling else { return }
        guard let latest = try? workspace.openReadOnly() else { return }
        model = latest
        if hasHostsDrift {
            refreshHostsDriftComparison()
        }
    }

    // MARK: - Managing standalone profiles (#21)

    var standaloneProfiles: [Profile] {
        model?.standaloneProfiles ?? []
    }

    func isActive(_ profileID: Profile.ID) -> Bool {
        model?.activeProfileIDs.contains(profileID) ?? false
    }

    var isPaused: Bool {
        model?.isPaused ?? false
    }

    var hasEffectiveProfiles: Bool {
        !(model?.effectiveCombination.profiles.isEmpty ?? true)
    }

    /// Creates an inactive standalone profile and returns its ID so the caller can select it for editing;
    /// the default name avoids existing profile names so the sidebar can tell them apart.
    @discardableResult
    func createStandaloneProfile() -> Profile.ID? {
        guard model != nil else { return nil }
        let profileID = Profile.ID(UUID().uuidString)
        let name = defaultProfileName()
        applyEdit { try $0.addProfile(id: profileID, name: name, content: "# Add hosts entries here\n") }
        return profileID
    }

    /// Same as createStandaloneProfile, but the new profile lands directly in the
    /// group — a single edit, so one manifest write covers the add and the move.
    @discardableResult
    func createProfile(in groupID: Group.ID) -> Profile.ID? {
        guard model != nil else { return nil }
        let profileID = Profile.ID(UUID().uuidString)
        let name = defaultProfileName()
        applyEdit {
            try $0.addProfile(id: profileID, name: name, content: "# Add hosts entries here\n")
            try $0.moveProfile(profileID, toGroup: groupID)
        }
        return profileID
    }

    /// Duplicates a profile in place (#89): the copy lands right after the original in the
    /// same container, inactive, so it is a purely local edit — no helper interaction. Returns
    /// the copy's ID so the caller can select it for renaming. The suffixed name is not made
    /// unique, matching the rename semantics.
    @discardableResult
    func duplicateProfile(_ profileID: Profile.ID) -> Profile.ID? {
        guard profile(profileID) != nil else { return nil }
        let copyID = Profile.ID(UUID().uuidString)
        applyEdit { model in
            // The name derives from the replayed model, so a concurrent foreign rename is
            // reflected; a foreign deletion drops the edit like any other.
            guard let latest = model.profile(profileID) else {
                throw ActivationModelError.unknownProfile(profileID)
            }
            // Semantic key: the suffix is a name fragment, not a command, and each language
            // places it differently (see PROFILE_DEFAULT_NAME).
            let name = String(localized: "PROFILE_COPY_NAME", defaultValue: "\(latest.name) Copy")
            try model.duplicateProfile(profileID, as: copyID, name: name)
        }
        return profile(copyID) == nil ? nil : copyID
    }

    func renameProfile(_ profileID: Profile.ID, to name: String) {
        guard let profile = profile(profileID),
              let normalized = normalizedRenameName(name, currentName: profile.name) else { return }
        applyEdit { try $0.renameProfile(profileID, to: normalized) }
    }

    func updateProfileContent(_ profileID: Profile.ID, content: String) {
        guard let profile = profile(profileID) else { return }
        guard profile.content != content else {
            // E.g. an undo back to the stored content while a conversion was pending.
            clearPendingRemoteConversion(for: profileID)
            return
        }
        // Remote content only changes through Refresh or the remote-profile edits (ADR-0012),
        // mirroring the CLI's write refusal; the editor is read-only for remote profiles anyway.
        guard !profile.isRemote else { return }
        // A local profile whose new first line reads as a Remote Header must not flip silently:
        // hold the edit and let the confirmation dialog decide (ADR-0012).
        if let header = RemoteHeader.parse(fromContent: content) {
            pendingRemoteConversion = PendingRemoteConversion(
                profileID: profileID,
                draftContent: content,
                baselineContent: profile.content,
                header: header
            )
            return
        }
        clearPendingRemoteConversion(for: profileID)
        applyEdit { try $0.updateProfileContent(profileID, content: content) }
    }

    /// The content the editor shows for a profile: the held conversion draft while its
    /// confirmation is up, the stored content otherwise.
    func editedProfileContent(_ profileID: Profile.ID) -> String {
        if let pending = pendingRemoteConversion, pending.profileID == profileID {
            return pending.draftContent
        }
        return profile(profileID)?.content ?? ""
    }

    /// Deleting a profile touches only the profile itself: Base Hosts and other profiles are unaffected.
    /// Deleting an active profile is also an active-state change: it takes the authorized switch
    /// path and only deletes once the merge succeeds; an inactive profile is a purely local edit
    /// that never goes through the helper.
    func deleteProfile(_ profileID: Profile.ID) {
        guard isActive(profileID) else {
            applyEdit { try $0.deleteProfile(profileID) }
            return
        }
        performAuthorizedSwitch { try $0.deleteProfile(profileID) }
    }

    func profile(_ profileID: Profile.ID) -> Profile? {
        standaloneProfiles.first(where: { $0.id == profileID })
            ?? group(containing: profileID)?.profiles.first(where: { $0.id == profileID })
    }

    func group(containing profileID: Profile.ID) -> Group? {
        groups.first { group in
            group.profiles.contains(where: { $0.id == profileID })
        }
    }

    private func defaultProfileName() -> String {
        let existing = Set((model?.standaloneProfiles ?? []).map(\.name)
            + (model?.groups ?? []).flatMap { $0.profiles.map(\.name) })
        // Semantic keys: the literal "New Profile" is already the menu command's
        // key, and a command phrasing makes a poor default name in translation.
        var candidate = String(localized: "PROFILE_DEFAULT_NAME", defaultValue: "New Profile")
        var counter = 2
        while existing.contains(candidate) {
            candidate = String(
                localized: "PROFILE_DEFAULT_NAME_NUMBERED", defaultValue: "New Profile \(counter)"
            )
            counter += 1
        }
        return candidate
    }

    // MARK: - Creating remote profiles (ADR-0012)

    /// Creates a Remote Profile by fetching and validating the Source URL's content first: a
    /// failed fetch or validation gate creates nothing, so no empty-shell remote profile can
    /// exist. The profile lands inactive in the standalone area — a purely local edit; the
    /// system hosts only changes once the user activates it.
    func createRemoteProfile(
        sourceURL: URL,
        name: String,
        interval: RemoteHeader.RefreshInterval
    ) async -> RemoteProfileCreationOutcome {
        guard model != nil else {
            return .failed(String(localized: "The workspace is not loaded."))
        }
        guard let header = RemoteHeader(sourceURL: sourceURL, interval: interval) else {
            return .failed(String(localized: "The Source URL must be an HTTPS address."))
        }
        let fetched: String
        let fetchedValidators: RemoteContentValidators?
        do {
            (fetched, fetchedValidators) = try await fetchContent(from: sourceURL)
        } catch {
            // The dialog's Cancel cancels this task, which the fetcher surfaces as an
            // ordinary transport error; report it as the cancellation it is.
            if Task.isCancelled {
                return .failed(String(localized: "The fetch was cancelled."))
            }
            return .failed(Self.remoteFetchFailureMessage(for: error))
        }
        // A cancellation that lands after the fetch succeeded must still mean "nothing is
        // stored", so re-check before persisting.
        guard !Task.isCancelled else {
            return .failed(String(localized: "The fetch was cancelled."))
        }
        let profileID = Profile.ID(UUID().uuidString)
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let profileName = trimmedName.isEmpty ? defaultRemoteProfileName(for: sourceURL) : trimmedName
        let fetchedAt = now()
        let addProfile: (inout ActivationModel) throws -> Void = {
            try $0.addProfile(
                id: profileID,
                name: profileName,
                content: header.storedContent(forFetched: fetched)
            )
            // The dialog's validation fetch is the first successful refresh (ADR-0012).
            try $0.recordRemoteRefreshSuccess(profileID, at: fetchedAt, validators: fetchedValidators)
        }
        // Committed only when the save succeeds (the importFiles precedent): fetched content
        // is re-fetchable, so a disk failure must fail the dialog rather than leave an
        // in-memory profile a relaunch would silently drop — which keeps this path off
        // persistByReplaying and applyEdit. The profile lands inactive, so no follow-up
        // merge is needed.
        do {
            if saveError == nil {
                switch try workspace.save(applying: addProfile) {
                case .saved(let saved):
                    model = saved
                case .conflict(let latest, let reason):
                    model = latest
                    throw reason
                }
            } else {
                guard var updated = model else {
                    return .failed(String(localized: "The workspace is not loaded."))
                }
                try addProfile(&updated)
                try workspace.save(updated)
                model = updated
                saveError = nil
            }
        } catch {
            return .failed(String(localized: "Save failed: \(String(describing: error))"))
        }
        return .created(profileID)
    }

    /// An omitted name falls back to the Source URL's host; like the other default names, it
    /// avoids existing profile names so the sidebar can tell two Remote Profiles apart. A name
    /// the user typed is taken verbatim (duplicates allowed, matching rename semantics).
    private func defaultRemoteProfileName(for sourceURL: URL) -> String {
        let existing = Set((model?.standaloneProfiles ?? []).map(\.name)
            + (model?.groups ?? []).flatMap { $0.profiles.map(\.name) })
        let base = sourceURL.host ?? "Remote"
        var candidate = base
        var counter = 2
        while existing.contains(candidate) {
            candidate = "\(base) \(counter)"
            counter += 1
        }
        return candidate
    }

    private static func remoteFetchFailureMessage(for error: any Error) -> String {
        guard let fetchError = error as? RemoteFetchError else {
            return String(localized: "The content could not be fetched: \(String(describing: error))")
        }
        return switch fetchError {
        case .notHTTPS:
            String(localized: "The Source URL must be an HTTPS address.")
        case .insecureRedirect:
            String(localized: "The URL redirected to a non-HTTPS address.")
        case .requestFailed(let message):
            String(localized: "The Source URL could not be reached: \(message)")
        case .httpStatus(let code):
            String(localized: "The server responded with HTTP \(code).")
        case .tooLarge:
            String(localized: "The fetched content is larger than 10 MB.")
        case .notUTF8:
            String(localized: "The fetched content is not UTF-8 text.")
        case .looksLikeHTML:
            String(localized: "The URL returned a web page, not hosts content.")
        }
    }

    // MARK: - Refreshing remote profiles (#70, ADR-0012)

    /// Every Remote Profile wherever it lives; Refresh All and its command enablement iterate this.
    var remoteProfiles: [Profile] {
        guard let model else { return [] }
        return (model.standaloneProfiles + model.groups.flatMap(\.profiles)).filter(\.isRemote)
    }

    /// The scheduler's view of the Remote Profiles (#71): each profile's interval, last
    /// successful refresh time, and last started attempt, re-derived from the model on every
    /// resync so interval edits and refresh results take effect immediately.
    var remoteScheduleEntries: [RemoteRefreshSchedule.Entry] {
        remoteProfiles.compactMap { profile in
            profile.remoteHeader.map { header in
                RemoteRefreshSchedule.Entry(
                    profileID: profile.id,
                    interval: header.interval,
                    lastSuccessAt: profile.remoteRefreshState?.lastSuccessAt,
                    lastAttemptAt: remoteRefreshAttempts[profile.id]
                )
            }
        }
    }

    /// Refreshes one Remote Profile: fetch, then apply through the edit path. A failed fetch
    /// keeps the old content and records the failure passively (row and menu bar markers — no
    /// system notification); a successful fetch updates the workspace, and only a changed body
    /// of an active, unpaused profile schedules the follow-up merge (mergeIfAuthorized: the
    /// drift monitor's self-write suppression applies, and registration or approval prompts
    /// can never trigger). Under unreconciled drift the merge attempt is rejected by the
    /// daemon's existing gate, so the workspace still updates but the system hosts stays
    /// untouched until reconciliation carries the content over.
    func refreshRemoteProfile(_ profileID: Profile.ID) async {
        guard !refreshingProfileIDs.contains(profileID),
              let profile = profile(profileID),
              let header = profile.remoteHeader else { return }
        refreshingProfileIDs.insert(profileID)
        defer { refreshingProfileIDs.remove(profileID) }
        remoteRefreshAttempts[profileID] = now()
        // The last recorded success plus the stored body identify the content revision this
        // fetch starts from: a concurrent writer (e.g. the CLI) refreshing the same URL
        // mid-flight bumps the time or the body, making this fetch's possibly older response
        // stale — it must not overwrite the newer stored content or its validators. The body
        // backs the timestamp up because the manifest stores whole seconds: two refreshes
        // landing within one second would otherwise compare equal.
        let baseline = RemoteRefreshBaseline(
            lastSuccessAt: profile.remoteRefreshState?.lastSuccessAt,
            body: RemoteHeader.storedBody(of: profile.content)
        )
        let outcome: RemoteFetchOutcome
        do {
            // Stored validators make the fetch conditional (#71): an unchanged source
            // answers 304 instead of a full download.
            outcome = try await fetchRemote(header.sourceURL, profile.remoteRefreshState?.validators)
        } catch {
            // A cancelled refresh is not the source's failure; record nothing.
            guard !Task.isCancelled else { return }
            recordRefreshFailure(
                profileID,
                fetchedFrom: header.sourceURL,
                baseline: baseline,
                message: Self.remoteFetchFailureMessage(for: error)
            )
            return
        }
        guard !Task.isCancelled else { return }
        switch outcome {
        case .content(let fetched, let validators):
            applyRefreshedContent(
                fetched,
                validators: validators,
                fetchedFrom: header.sourceURL,
                baseline: baseline,
                to: profileID
            )
        case .notModified(let validators):
            recordRefreshNotModified(
                of: profileID, fetchedFrom: header.sourceURL, baseline: baseline, validators: validators
            )
        }
    }

    /// Refreshes every Remote Profile; the fetches run concurrently and each result is
    /// applied as it arrives.
    func refreshAllRemoteProfiles() async {
        await withTaskGroup(of: Void.self) { group in
            for profileID in remoteProfiles.map(\.id) {
                group.addTask { await self.refreshRemoteProfile(profileID) }
            }
        }
    }

    /// Thrown inside a replay closure when the profile the fetch was started for is gone, no
    /// longer remote, now points at a different Source URL, or was refreshed by a concurrent
    /// writer while the fetch was in flight (the success-time or body baseline moved): the
    /// stale result is dropped through the replay-conflict path.
    private struct StaleRemoteRefresh: Error {}

    /// The content revision a fetch started from; see refreshRemoteProfile for why the body
    /// backs the whole-second timestamp up.
    private struct RemoteRefreshBaseline {
        let lastSuccessAt: Date?
        let body: String?

        func matches(_ profile: Profile) -> Bool {
            profile.remoteRefreshState?.lastSuccessAt == lastSuccessAt
                && RemoteHeader.storedBody(of: profile.content) == body
        }
    }

    private func applyRefreshedContent(
        _ fetched: String,
        validators: RemoteContentValidators?,
        fetchedFrom sourceURL: URL,
        baseline: RemoteRefreshBaseline,
        to profileID: Profile.ID
    ) {
        var shouldMerge = false
        let apply: (inout ActivationModel) throws -> Void = { [now] latest in
            guard let profile = latest.profile(profileID),
                  let header = profile.remoteHeader,
                  header.sourceURL == sourceURL,
                  baseline.matches(profile) else {
                throw StaleRemoteRefresh()
            }
            let newBody = RemoteHeader.escapingEmbeddedHeader(in: fetched)
            if RemoteHeader.storedBody(of: profile.content) != newBody {
                try latest.updateProfileContent(
                    profileID,
                    content: header.storedContent(forFetched: fetched)
                )
                // "No change after header stripping" writes nothing to the system hosts; an
                // inactive or paused profile updates the workspace only.
                shouldMerge = latest.activeProfileIDs.contains(profileID) && !latest.isPaused
            }
            try latest.recordRemoteRefreshSuccess(profileID, at: now(), validators: validators)
        }
        // The comparison derives from the model; recompute it on every exit path (applyEdit's rule).
        defer {
            if hasHostsDrift {
                refreshHostsDriftComparison()
            }
        }
        do {
            guard case .saved = try persistByReplaying(apply) else {
                // Stale fetch dropped; any failure copy belongs to the old identity.
                remoteRefreshErrors[profileID] = nil
                return
            }
        } catch {
            // The refreshed content stays in memory (persistByReplaying); only the disk write
            // failed, and like applyEdit unpersisted content is not merged — including by a
            // follow-up merge an earlier edit left pending, which would read it from the
            // in-memory model when it fires.
            followUpMergeTask?.cancel()
            saveError = String(localized: "Save failed: \(String(describing: error))")
            return
        }
        remoteRefreshErrors[profileID] = nil
        if shouldMerge {
            // The refreshed content supersedes any pending follow-up merge, like a new edit.
            followUpMergeTask?.cancel()
            scheduleFollowUpMerge()
        }
    }

    private func recordRefreshFailure(
        _ profileID: Profile.ID,
        fetchedFrom sourceURL: URL,
        baseline: RemoteRefreshBaseline,
        message: String
    ) {
        let apply: (inout ActivationModel) throws -> Void = { latest in
            // The failure belongs to the URL that was fetched: a profile deleted, converted,
            // or retargeted mid-fetch must not inherit the old URL's failure marker — and a
            // concurrent writer's newer success (a moved baseline) must not be marked failed
            // by this older attempt.
            guard let profile = latest.profile(profileID),
                  profile.remoteHeader?.sourceURL == sourceURL,
                  baseline.matches(profile) else {
                throw StaleRemoteRefresh()
            }
            try latest.recordRemoteRefreshFailure(profileID)
        }
        // The comparison derives from the model; recompute it on every exit path (applyEdit's
        // rule) — the replay may absorb external changes beyond the failure flag itself.
        defer {
            if hasHostsDrift {
                refreshHostsDriftComparison()
            }
        }
        do {
            guard case .saved = try persistByReplaying(apply) else {
                remoteRefreshErrors[profileID] = nil
                return
            }
            remoteRefreshErrors[profileID] = message
        } catch {
            // The failed flag stays in memory; only the manifest write failed.
            remoteRefreshErrors[profileID] = message
            saveError = String(localized: "Save failed: \(String(describing: error))")
        }
    }

    /// A 304 answer to a conditional refresh (#71): the stored content is current, so only
    /// the success time advances — validator fields the answer resent replace the stored
    /// ones (the rest stay), nothing merges, and any failure marker clears exactly as a full
    /// successful download would clear it.
    private func recordRefreshNotModified(
        of profileID: Profile.ID,
        fetchedFrom sourceURL: URL,
        baseline: RemoteRefreshBaseline,
        validators: RemoteContentValidators?
    ) {
        let apply: (inout ActivationModel) throws -> Void = { [now] latest in
            // Like a stale fetch result: the 304 answers the URL (and content revision)
            // that was asked about.
            guard let profile = latest.profile(profileID),
                  profile.remoteHeader?.sourceURL == sourceURL,
                  baseline.matches(profile) else {
                throw StaleRemoteRefresh()
            }
            try latest.recordRemoteRefreshSuccess(
                profileID,
                at: now(),
                validators: RemoteContentValidators.merged(
                    stored: profile.remoteRefreshState?.validators,
                    refreshed: validators
                )
            )
        }
        // The comparison derives from the model; recompute it on every exit path (applyEdit's
        // rule) — the replay may absorb external changes beyond the timestamp itself.
        defer {
            if hasHostsDrift {
                refreshHostsDriftComparison()
            }
        }
        do {
            guard case .saved = try persistByReplaying(apply) else {
                remoteRefreshErrors[profileID] = nil
                return
            }
            remoteRefreshErrors[profileID] = nil
        } catch {
            // The success is recorded in memory; only the manifest write failed.
            remoteRefreshErrors[profileID] = nil
            saveError = String(localized: "Save failed: \(String(describing: error))")
        }
    }

    // MARK: - Converting between local and remote (ADR-0012)

    /// Confirms the held local→remote conversion: the Source URL is fetched and validated like
    /// creation, and only a fully saved result makes the profile remote — with the fetched
    /// content as the body and the validation fetch recorded as the first successful refresh.
    /// Every failure — the fetch, an external change to the profile, or the save itself —
    /// keeps the stored content and the held draft, so the dialog shows the copy and offers
    /// retry or cancel.
    func confirmRemoteConversion() async -> RemoteConversionOutcome {
        guard let pending = pendingRemoteConversion else {
            return .failed(String(localized: "The profile was changed outside this dialog."))
        }
        let fetched: String
        let fetchedValidators: RemoteContentValidators?
        switch await fetchContentForDialog(from: pending.header.sourceURL) {
        case .fetched(let content, let validators): (fetched, fetchedValidators) = (content, validators)
        case .refused(let message): return .failed(message)
        }
        guard pendingRemoteConversion == pending else {
            return .failed(String(localized: "The profile was changed outside this dialog."))
        }
        let fetchedAt = now()
        // Validated under the manifest lock against the content the draft was typed over: an
        // external writer's mid-fetch save wins, and the stale conversion reports instead of
        // overwriting it. The baseline check also covers deletion and a foreign conversion.
        let outcome = saveValidatedRemoteChange { latest in
            guard let current = latest.profile(pending.profileID),
                  current.content == pending.baselineContent else {
                throw StaleRemoteDialogEdit()
            }
            try latest.updateProfileContent(
                pending.profileID,
                content: pending.header.storedContent(forFetched: fetched)
            )
            try latest.recordRemoteRefreshSuccess(
                pending.profileID, at: fetchedAt, validators: fetchedValidators
            )
        }
        switch outcome {
        case .saved:
            pendingRemoteConversion = nil
            return .converted
        case .stale:
            return .failed(String(localized: "The profile was changed outside this dialog."))
        case .failed(let message):
            return .failed(message)
        }
    }

    /// Drops the held conversion draft: the profile's stored content was never touched, so
    /// cancelling is purely forgetting the edit.
    func cancelRemoteConversion() {
        pendingRemoteConversion = nil
    }

    private func clearPendingRemoteConversion(for profileID: Profile.ID) {
        if pendingRemoteConversion?.profileID == profileID {
            pendingRemoteConversion = nil
        }
    }

    /// Convert to Local (ADR-0012): strips the Remote Header line and keeps the last fetched
    /// content as an ordinary editable local profile — the only way a Remote Profile stops
    /// being remote, and one-way. Grouping and active state stay; the model clears the refresh
    /// state with the header. The body is derived from the latest saved content under the
    /// manifest lock, so what survives is genuinely the last fetched content even when an
    /// external writer refreshed it moments ago; the stored body also keeps any escaped
    /// embedded token escaped, so stripping one header can never expose another.
    func convertRemoteProfileToLocal(_ profileID: Profile.ID) {
        guard profile(profileID)?.isRemote == true else { return }
        applyEdit { latest in
            guard let current = latest.profile(profileID),
                  let body = RemoteHeader.storedBody(of: current.content) else {
                throw StaleRemoteDialogEdit()
            }
            try latest.updateProfileContent(profileID, content: body)
        }
        // The failure copy belongs to the Source URL the profile no longer fetches from.
        remoteRefreshErrors[profileID] = nil
    }

    /// Applies an edited Source URL and/or interval to a Remote Profile (ADR-0012). A URL
    /// change re-validates like creation: the new URL is fetched first and only a fully saved
    /// result stores the new header and content — refresh state reset to this first success —
    /// so any failure leaves the old Source URL's content untouched. An interval-only change
    /// keeps the same Source URL: the header line is rewritten above the latest saved body
    /// without a fetch, and the refresh state survives. Both paths re-validate under the
    /// manifest lock that the profile still carries the header the dialog was opened for.
    func editRemoteProfile(
        _ profileID: Profile.ID,
        sourceURL: URL,
        interval: RemoteHeader.RefreshInterval
    ) async -> RemoteProfileEditOutcome {
        guard let profile = profile(profileID), let oldHeader = profile.remoteHeader else {
            return .failed(String(localized: "The profile is no longer a remote profile."))
        }
        guard let newHeader = RemoteHeader(sourceURL: sourceURL, interval: interval) else {
            return .failed(String(localized: "The Source URL must be an HTTPS address."))
        }
        guard newHeader != oldHeader else { return .updated }

        let outcome: RemoteDialogSaveOutcome
        if newHeader.sourceURL == oldHeader.sourceURL {
            outcome = saveValidatedRemoteChange { latest in
                guard let current = latest.profile(profileID),
                      current.remoteHeader?.sourceURL == oldHeader.sourceURL,
                      let body = RemoteHeader.storedBody(of: current.content) else {
                    throw StaleRemoteDialogEdit()
                }
                try latest.updateProfileContent(profileID, content: newHeader.line + "\n" + body)
            }
        } else {
            let fetched: String
            let fetchedValidators: RemoteContentValidators?
            switch await fetchContentForDialog(from: newHeader.sourceURL) {
            case .fetched(let content, let validators): (fetched, fetchedValidators) = (content, validators)
            case .refused(let message): return .failed(message)
            }
            let fetchedAt = now()
            outcome = saveValidatedRemoteChange { latest in
                guard latest.profile(profileID)?.remoteHeader?.sourceURL
                    == oldHeader.sourceURL else {
                    throw StaleRemoteDialogEdit()
                }
                try latest.updateProfileContent(
                    profileID,
                    content: newHeader.storedContent(forFetched: fetched)
                )
                try latest.recordRemoteRefreshSuccess(
                    profileID, at: fetchedAt, validators: fetchedValidators
                )
            }
        }
        switch outcome {
        case .saved:
            if newHeader.sourceURL != oldHeader.sourceURL {
                // The failure copy belongs to the old Source URL; an interval-only edit keeps
                // it, like it keeps the rest of the refresh state.
                remoteRefreshErrors[profileID] = nil
            }
            return .updated
        case .stale:
            return .failed(String(localized: "The profile was changed outside this dialog."))
        case .failed(let message):
            return .failed(message)
        }
    }

    /// Thrown inside a replay closure when the profile a dialog operation was validated
    /// against is gone or was changed by an external writer while the dialog was open: the
    /// stale operation is refused through the replay-conflict path instead of overwriting
    /// the external work.
    private struct StaleRemoteDialogEdit: Error {}

    /// How `saveValidatedRemoteChange` concluded a dialog-driven remote change.
    private enum RemoteDialogSaveOutcome {
        case saved
        /// The profile was changed outside the dialog; nothing was written.
        case stale
        /// The save itself failed; nothing was committed (display copy attached).
        case failed(String)
    }

    /// The save path shared by the remote dialogs (conversion and Source URL/interval edits),
    /// following the creation precedent: the change replays on the latest on-disk state and is
    /// committed only when the save fully succeeds — fetched or re-enterable dialog input must
    /// fail the dialog rather than linger as an unsaved in-memory edit (unlike applyEdit's
    /// degraded mode, which exists so typed content is never lost). A successful save
    /// schedules the follow-up merge like any other edit.
    private func saveValidatedRemoteChange(
        _ change: @escaping (inout ActivationModel) throws -> Void
    ) -> RemoteDialogSaveOutcome {
        guard model != nil else {
            return .failed(String(localized: "The workspace is not loaded."))
        }
        // A pending merge's content is superseded by this change (applyEdit's rule).
        followUpMergeTask?.cancel()
        // The comparison derives from the model; recompute it on every exit path.
        defer {
            if hasHostsDrift {
                refreshHostsDriftComparison()
            }
        }
        do {
            if saveError == nil {
                switch try workspace.save(applying: change) {
                case .saved(let saved):
                    model = saved
                case .conflict(let latest, _):
                    model = latest
                    return .stale
                }
            } else {
                // Degraded mode (an earlier save failure keeps unsaved edits in memory): the
                // replay target is the in-memory model, written whole, so those edits
                // self-heal on this save — persistByReplaying's rule.
                guard var updated = model else {
                    return .failed(String(localized: "The workspace is not loaded."))
                }
                try change(&updated)
                try workspace.save(updated)
                model = updated
                saveError = nil
            }
        } catch is StaleRemoteDialogEdit {
            return .stale
        } catch {
            return .failed(String(localized: "Save failed: \(String(describing: error))"))
        }
        scheduleFollowUpMerge()
        return .saved
    }

    /// A dialog fetch either yields validated content (with the response's cache validators
    /// to store alongside it) or display copy for the refusal.
    private enum DialogFetchOutcome {
        case fetched(String, RemoteContentValidators?)
        case refused(String)
    }

    /// The unconditional fetch for dialogs and creation: no validators are sent, so the
    /// outcome always carries content (the fetcher refuses a 304 nobody asked for).
    private func fetchContent(from url: URL) async throws -> (String, RemoteContentValidators?) {
        guard case .content(let text, let validators) = try await fetchRemote(url, nil) else {
            throw RemoteFetchError.httpStatus(304)
        }
        return (text, validators)
    }

    /// One validated dialog fetch, with cancellation reported as its own copy — re-checked
    /// after a successful fetch, so a dialog cancelled mid-fetch never stores anything.
    private func fetchContentForDialog(from url: URL) async -> DialogFetchOutcome {
        let fetched: String
        let validators: RemoteContentValidators?
        do {
            (fetched, validators) = try await fetchContent(from: url)
        } catch {
            if Task.isCancelled {
                return .refused(String(localized: "The fetch was cancelled."))
            }
            return .refused(Self.remoteFetchFailureMessage(for: error))
        }
        guard !Task.isCancelled else {
            return .refused(String(localized: "The fetch was cancelled."))
        }
        return .fetched(fetched, validators)
    }

    // MARK: - Managing groups (#22)

    var groups: [Group] {
        model?.groups ?? []
    }

    /// Creates an empty group and returns its ID so the sidebar can locate the new group.
    @discardableResult
    func createGroup() -> Group.ID? {
        guard model != nil else { return nil }
        let groupID = Group.ID(UUID().uuidString)
        let name = defaultGroupName()
        applyEdit { try $0.addGroup(id: groupID, name: name) }
        return groupID
    }

    func renameGroup(_ groupID: Group.ID, to name: String) {
        guard let group = groups.first(where: { $0.id == groupID }),
              let normalized = normalizedRenameName(name, currentName: group.name) else { return }
        applyEdit { try $0.renameGroup(groupID, to: normalized) }
    }

    func deleteGroup(_ groupID: Group.ID) {
        applyEdit { try $0.deleteGroup(groupID) }
    }

    /// Moves a profile into the target container (`nil` = the standalone area) at the given position within it.
    func moveProfile(_ profileID: Profile.ID, toGroup groupID: Group.ID?, at index: Int) {
        let move: (inout ActivationModel) throws -> Void = {
            try $0.moveProfile(profileID, toGroup: groupID)
            try $0.moveProfile(profileID, toIndex: index)
        }
        guard let current = model, let preview = model(afterApplying: move) else { return }
        // Moving between groups is usually a local edit; if the target group's exclusivity rule
        // would deactivate a profile, the merge must succeed first, and only then are the
        // in-memory state and the manifest committed.
        if current.activeProfileIDs == preview.activeProfileIDs {
            applyEdit(move)
        } else {
            performAuthorizedSwitch(move)
        }
    }

    /// Inserts a profile at a boundary of the target container; when moving down within the same container, first subtract the slot occupied by the source profile.
    func insertProfile(_ profileID: Profile.ID, toGroup groupID: Group.ID?, at insertionIndex: Int) {
        let destinationProfiles: [Profile]
        if let groupID {
            guard let group = groups.first(where: { $0.id == groupID }) else { return }
            destinationProfiles = group.profiles
        } else {
            destinationProfiles = standaloneProfiles
        }
        let boundaryIndex = min(max(0, insertionIndex), destinationProfiles.count)
        let destinationIndex: Int
        if let sourceIndex = destinationProfiles.firstIndex(where: { $0.id == profileID }),
           sourceIndex < boundaryIndex {
            destinationIndex = boundaryIndex - 1
        } else {
            destinationIndex = boundaryIndex
        }
        moveProfile(profileID, toGroup: groupID, at: destinationIndex)
    }

    func moveGroup(_ groupID: Group.ID, toIndex index: Int) {
        applyEdit { try $0.moveGroup(groupID, toIndex: index) }
    }

    /// Inserts a group at a boundary of the group list; when moving down within the same list, first subtract the slot occupied by the source group.
    func insertGroup(_ groupID: Group.ID, at insertionIndex: Int) {
        let boundaryIndex = min(max(0, insertionIndex), groups.count)
        let destinationIndex: Int
        if let sourceIndex = groups.firstIndex(where: { $0.id == groupID }),
           sourceIndex < boundaryIndex {
            destinationIndex = boundaryIndex - 1
        } else {
            destinationIndex = boundaryIndex
        }
        moveGroup(groupID, toIndex: destinationIndex)
    }

    private func defaultGroupName() -> String {
        let existing = Set(groups.map(\.name))
        var candidate = String(localized: "GROUP_DEFAULT_NAME", defaultValue: "New Group")
        var counter = 2
        while existing.contains(candidate) {
            candidate = String(
                localized: "GROUP_DEFAULT_NAME_NUMBERED", defaultValue: "New Group \(counter)"
            )
            counter += 1
        }
        return candidate
    }

    private func normalizedRenameName(_ proposedName: String, currentName: String) -> String? {
        let normalized = proposedName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty, normalized != currentName else { return nil }
        return normalized
    }

    // MARK: - Switching active state (#21)

    /// Switches a profile's active state through the authorization flow: committed and persisted
    /// only after the merge succeeds; when blocked or failed, the state stays unchanged and
    /// feedback is presented. Only one in-flight switch is allowed at a time.
    func setProfileActive(_ profileID: Profile.ID, _ active: Bool) {
        guard isActive(profileID) != active else { return }
        performAuthorizedSwitch { updated in
            // Replayed on the latest model at commit time; comparing against the target state keeps the replay from flipping by mistake
            guard updated.activeProfileIDs.contains(profileID) != active else { return }
            try updated.toggleProfile(profileID)
        }
    }

    /// While paused, only Base Hosts is written, but every profile's active state is kept; on resume the original state rejoins the merge.
    func setPaused(_ paused: Bool) {
        guard isPaused != paused else { return }
        performAuthorizedSwitch { updated in
            updated.setPaused(paused)
        }
    }

    /// Shared path for active-state changes: merges from a snapshot of the current model plus the
    /// change; on success, replays the change on the latest model and persists it — edits saved to
    /// disk while in flight are not rolled back by the snapshot.
    private func performAuthorizedSwitch(_ change: @escaping (inout ActivationModel) throws -> Void) {
        guard !hasHostsDrift else {
            switchTask = nil
            switchFeedback = .hostsDrift
            return
        }
        guard !isSwitching, let preview = model(afterApplying: change) else { return }
        // The switch itself writes the latest merged content, so any in-flight follow-up merge is obsolete
        followUpMergeTask?.cancel()
        isSwitching = true
        switchFeedback = nil
        switchTask = Task { [coordinator] in
            defer { isSwitching = false }
            do {
                let outcome = try await coordinator.performSwitch(preview.mergedHosts)
                switch outcome.guidance(targetHash: preview.mergedHosts.hash) {
                case .merged:
                    commitSwitched(change)
                case .unavailable:
                    switchFeedback = .unavailable
                case .needsApproval:
                    switchFeedback = .needsApproval
                case .hostsDrift:
                    hasHostsDrift = true
                    refreshHostsDriftComparison()
                    switchFeedback = .hostsDrift
                case .writtenButFlushFailed(let failure):
                    // The replacement physically landed (the daemon recorded the new
                    // hash), so the switch is committed; only the flush failure is
                    // surfaced. Not committing would leave the UI contradicting the
                    // file until an unrelated merge.
                    commitSwitched(change)
                    switchFeedback = .failed(
                        String(localized: "System hosts was updated, but DNS refresh failed: \(failure.message)")
                    )
                case .failed(let error):
                    switchFeedback = .failed(
                        String(localized: "Failed to update the system hosts file: \(String(describing: error))")
                    )
                }
            } catch {
                switchFeedback = .failed(String(localized: "Switch failed: \(String(describing: error))"))
            }
        }
    }

    private func model(
        afterApplying change: (inout ActivationModel) throws -> Void
    ) -> ActivationModel? {
        guard var preview = model else { return nil }
        do {
            try change(&preview)
        } catch {
            assertionFailure("Failed to apply the change to the current model: \(error)")
            return nil
        }
        return preview
    }

    /// The merge has succeeded: commit this change by replaying it on the latest persisted state —
    /// neither edits saved while the switch was in flight nor an external writer's changes are
    /// rolled back (ADR-0010 ②). The system hosts is already updated at this point, so a save
    /// failure only affects the manifest — the feedback is still a successful switch, with the
    /// save error reported separately.
    /// A follow-up merge is scheduled at the end: if in-flight edits were queued ahead of this
    /// switch, it converges the latest content into the system hosts; when the content matches,
    /// the daemon short-circuits idempotently and no extra write happens.
    private func commitSwitched(_ change: (inout ActivationModel) throws -> Void) {
        defer { scheduleFollowUpMerge() }
        do {
            guard case .saved = try persistByReplaying(change) else {
                // Replay conflict (e.g. the profile was deleted mid-flight): do not commit; the
                // follow-up merge converges the system hosts back to the current model
                return
            }
            backgroundSyncError = nil
        } catch {
            // The change stays committed in memory (persistByReplaying); only the disk write failed
            saveError = String(localized: "Save failed: \(String(describing: error))")
        }
        switchFeedback = .merged
    }

    func clearSwitchFeedback() {
        switchFeedback = nil
    }

    /// Retires feedback that only described the helper not being ready, and that neither the
    /// switch nor the reconciliation path has any other way to notice is over. Every read is
    /// forwarded, repeats included: a switch made from the menu bar with the window closed can
    /// observe a revocation that no status read ever did, so a later `.enabled` is fresh news
    /// even when it matches the previous read. Every other feedback kind stays.
    func helperStatusDidChange(_ status: DaemonRegistrationStatus) {
        let retire: Bool = switch switchFeedback {
        // "Needs approval" holds only while the system still says so; enabled, not registered,
        // and not found (helper removed) all make the approval guidance meaningless.
        case .needsApproval: status != .requiresApproval
        // "Unavailable" (app outside Applications) is over only once the helper registered.
        case .unavailable: status == .enabled
        default: false
        }
        guard retire, let feedback = switchFeedback else { return }
        // The reconciliation path records the verdict a second time, as its error copy, using the
        // feedback's own message; matching on it retires exactly that record and leaves an
        // unrelated reconciliation error (a DNS flush failure kept after the drift resolved) alone.
        if reconciliationError == feedback.message {
            reconciliationError = nil
        }
        switchFeedback = nil
    }

    func clearBackgroundSyncError() {
        backgroundSyncError = nil
    }

    /// Opens the Login Items pane in System Settings, used by the guidance button of the "approval required" feedback.
    func openApprovalSettings() {
        openApproval()
    }

    func reconcileHosts(_ choice: HostsReconciliationChoice) {
        guard hasHostsDrift,
              !isReconciling,
              let comparison = hostsDriftComparison,
              var updated = model else { return }
        let reviewedGeneration = hostsDriftGeneration

        // The reviewed change in replayable form: replayed on the latest persisted state at commit
        // time (ADR-0010 ②), so profile and active-state changes made while the reconcile is in
        // flight are not rolled back. The base content is deliberately the snapshot value computed
        // at review time — it is exactly what this reconcile writes into the system hosts, and the
        // CLI (the only external writer) has no command that edits Base Hosts.
        let change: (inout ActivationModel) -> Void
        switch choice {
        case .addDriftLinesToBaseHosts:
            let reviewedBase = comparison.appendingDriftAdditions(to: updated.baseHosts.content)
            change = { $0.baseHosts.content = reviewedBase }
        case .overwriteDriftWithActiveState:
            change = { _ in }
        case .later:
            reconciliationTask = nil
            return
        }
        change(&updated)

        followUpMergeTask?.cancel()
        isReconciling = true
        switchFeedback = nil
        reconciliationError = nil
        reconciliationTask = Task { [coordinator] in
            defer { isReconciling = false }
            do {
                let outcome = try await coordinator.reconcile(
                    updated.mergedHosts,
                    observedCurrentHash: comparison.observedActualHash
                )
                switch outcome.guidance(targetHash: updated.mergedHosts.hash) {
                case .merged:
                    guard reconciliationSnapshotIsCurrent(reviewedGeneration),
                          persistReconciledModel(applying: change) else { return }
                    hasHostsDrift = false
                    hostsDriftComparison = nil
                    reconciliationError = nil
                    switchFeedback = .merged
                case .unavailable:
                    reconciliationError = SwitchFeedback.unavailable.message
                    switchFeedback = .unavailable
                case .needsApproval:
                    reconciliationError = SwitchFeedback.needsApproval.message
                    switchFeedback = .needsApproval
                case .writtenButFlushFailed(let failure):
                    // The atomic replace already completed and only the DNS refresh failed. The
                    // user's choice about the drifted content must be saved now, or the next
                    // normal write would overwrite the preserved lines.
                    guard reconciliationSnapshotIsCurrent(reviewedGeneration),
                          persistReconciledModel(applying: change, writtenHash: failure.writtenHash)
                    else { return }
                    hasHostsDrift = false
                    hostsDriftComparison = nil
                    let message = String(
                        localized: "System hosts was updated, but DNS refresh failed: \(failure.message)"
                    )
                    reconciliationError = message
                    switchFeedback = .failed(message)
                case .hostsDrift:
                    refreshHostsDriftComparison()
                    reconciliationError = String(
                        localized: "System hosts changed again. Review the latest diff before retrying."
                    )
                    switchFeedback = .hostsDrift
                case .failed(let error):
                    let message = String(
                        localized: "Failed to reconcile the system hosts file: \(String(describing: error))"
                    )
                    reconciliationError = message
                    switchFeedback = .failed(message)
                }
            } catch {
                let message = String(
                    localized: "Hosts reconciliation failed: \(String(describing: error))"
                )
                reconciliationError = message
                switchFeedback = .failed(message)
            }
        }
    }

    var useSystemHostsAsBaseUnavailableReason: String? {
        guard !isSwitching, !isReconciling else {
            return String(localized: "Wait for the current hosts operation to finish.")
        }
        guard hasHostsDrift, let comparison = hostsDriftComparison else {
            return String(localized: "No unresolved hosts drift is available to adopt.")
        }
        guard model?.activeProfileIDs.isEmpty == true else {
            return String(localized: "Deactivate every active profile before using System Hosts as Base Hosts.")
        }
        guard comparison.actualContent != nil else {
            return String(localized: "System Hosts must be valid UTF-8 before it can replace Base Hosts.")
        }
        guard !comparison.containsGeneratedHostflipOutput else {
            return String(localized: "System Hosts already contains hostflip-generated sections and cannot be used as Base Hosts.")
        }
        return nil
    }

    /// Accepts the user-reviewed system hosts state as the new Base Hosts. This path only updates
    /// the workspace and the accepted hash; it does not go through the helper or rewrite /etc/hosts.
    func useSystemHostsAsBase() {
        guard useSystemHostsAsBaseUnavailableReason == nil,
              let comparison = hostsDriftComparison,
              model != nil else { return }

        followUpMergeTask?.cancel()
        followUpMergeTask = nil
        do {
            let latestData = try readSystemHosts()
            let latestHash = MergedHosts.hash(of: latestData)
            guard latestHash == comparison.observedActualHash else {
                refreshSystemHosts()
                refreshHostsDriftComparison()
                reconciliationError = String(
                    localized: "System hosts changed again. Review the latest diff before retrying."
                )
                switchFeedback = .hostsDrift
                return
            }
            guard let latestContent = String(data: latestData, encoding: .utf8) else {
                refreshSystemHosts()
                reconciliationError = String(
                    localized: "System Hosts must be valid UTF-8 before it can replace Base Hosts."
                )
                switchFeedback = .hostsDrift
                return
            }

            guard case .saved = try persistByReplaying(
                { $0.baseHosts.content = latestContent },
                acceptingSystemHostsHash: latestHash
            ) else {
                assertionFailure("a non-throwing base replacement cannot conflict")
                return
            }
            systemHostsContent = latestContent
            systemHostsReadError = nil
            reconciliationNeedsAttention = false
            hasHostsDrift = false
            hostsDriftComparison = nil
            reconciliationError = nil
            saveError = nil
            backgroundSyncError = nil
            switchFeedback = .baseHostsReplaced
        } catch {
            let message = String(localized: "Base Hosts could not be replaced: \(String(describing: error))")
            reconciliationError = message
            switchFeedback = .failed(message)
        }
    }

    private func reconciliationSnapshotIsCurrent(_ reviewedGeneration: Int) -> Bool {
        guard reviewedGeneration == hostsDriftGeneration else {
            reconciliationNeedsAttention = true
            hasHostsDrift = true
            refreshHostsDriftComparison()
            reconciliationError = String(
                localized: "System hosts changed while reconciliation was in progress. Review the latest diff before retrying."
            )
            switchFeedback = .hostsDrift
            return false
        }
        return true
    }

    private func persistReconciledModel(
        applying change: (inout ActivationModel) -> Void,
        writtenHash: String? = nil
    ) -> Bool {
        do {
            guard case .saved = try persistByReplaying(change) else {
                assertionFailure("a non-throwing reconciliation change cannot conflict")
                return false
            }
            if let writtenHash {
                try workspace.recordLastWrittenHash(writtenHash)
            }
            reconciliationNeedsAttention = false
            saveError = nil
            backgroundSyncError = nil
            return true
        } catch {
            // The change stays committed in memory (persistByReplaying); only the disk write failed
            saveError = String(localized: "Save failed: \(String(describing: error))")
            reconciliationNeedsAttention = true
            hasHostsDrift = true
            refreshHostsDriftComparison()
            let message = String(
                localized: "System hosts was updated, but the reconciliation could not be saved: \(String(describing: error))"
            )
            reconciliationError = message
            switchFeedback = .failed(message)
            return false
        }
    }

    private func refreshHostsDriftComparison() {
        guard let model else { return }
        // Before the first confirmed write, the drift verdict compares against hosts.orig, so the
        // review must diff against that same baseline: diffing against the merged output — whose
        // Base Hosts left the SwitchHosts block out at capture (#81) — would show the block as
        // additions and hand it back to "Add to Base Hosts" (#82). An unreadable baseline fails
        // closed as no comparison, like the monitor's verdict — falling back to the merged output
        // would resurrect exactly the weld-back this guards against.
        let expectedContent: String?
        do {
            expectedContent = try workspace.expectedSystemHostsContentBeforeFirstWrite()
                ?? model.mergedHosts.content
        } catch {
            expectedContent = nil
        }
        let refreshed = try? expectedContent.map {
            try HostsDriftComparison(expectedContent: $0, actualData: readSystemHosts())
        }
        guard refreshed != hostsDriftComparison else { return }
        hostsDriftComparison = refreshed
        hostsDriftGeneration &+= 1
    }

    // MARK: - Import / Export (#40, ADR-0008)

    /// Every file is parsed and validated before anything is applied, so one bad file means zero
    /// change. Imported content lands inactive, making this a purely local edit: it must not go
    /// through applyEdit, whose follow-up merge would touch the system hosts. The in-memory model
    /// is committed only after the workspace save succeeds.
    func importFiles(at urls: [URL]) -> ImportOutcome {
        guard model != nil else {
            return .failed(String(localized: "Nothing was imported: the workspace is not loaded."))
        }
        do {
            let contents = try urls.map { url in
                do {
                    return try ImportReader.read(
                        data: Data(contentsOf: url),
                        fileName: url.lastPathComponent
                    )
                } catch {
                    throw ImportFileFailure(fileName: url.lastPathComponent, underlying: error)
                }
            }
            let applyImports: (inout ActivationModel) throws -> Void = { updated in
                for content in contents {
                    switch content {
                    case .snapshot(let snapshot):
                        try updated.importSnapshot(snapshot)
                    case .plainText(let name, let text):
                        try updated.addProfile(id: Profile.ID(UUID().uuidString), name: name, content: text)
                    }
                }
            }
            try commitImportBatch(applying: applyImports)
            return .imported(ImportSummary(of: contents))
        } catch {
            return .failed(Self.importFailureMessage(for: error))
        }
    }

    /// One-click SwitchHosts migration (#74/#75, ADR-0013): reads whatever generation the
    /// directory holds offline, maps it to native profiles, and applies the plan through
    /// the same commit path as importFiles — inactive content, no applyEdit, and any parse
    /// failure means zero change. The detected format rides on the summary; the mapping
    /// engine never sees it.
    func importSwitchHosts(at directory: URL) -> SwitchHostsImportOutcome {
        guard model != nil else {
            return .failed(String(localized: "Nothing was imported: the workspace is not loaded."))
        }
        do {
            let (data, format) = try SwitchHostsReader.read(at: directory)
            var plan = SwitchHostsMapper.plan(for: data)
            plan.summary.detectedFormat = format
            try commitImportBatch { [plan] in try $0.importSnapshot(plan.snapshot) }
            return .imported(plan.summary)
        } catch {
            return .failed(Self.switchHostsImportFailureMessage(for: error))
        }
    }

    /// Shared commit path of the import entries: the batch commits only when the save
    /// succeeds, so imports stay off persistByReplaying, whose disk-failure fallback would
    /// keep the imported content in memory.
    private func commitImportBatch(applying applyImports: (inout ActivationModel) throws -> Void) throws {
        if saveError == nil {
            switch try workspace.save(applying: applyImports) {
            case .saved(let saved):
                model = saved
            case .conflict(let latest, let reason):
                model = latest
                throw reason
            }
        } else {
            guard var updated = model else {
                throw ImportCommitError.workspaceNotLoaded
            }
            try applyImports(&updated)
            try workspace.save(updated)
            model = updated
            saveError = nil
        }
    }

    private enum ImportCommitError: Error {
        case workspaceNotLoaded
    }

    /// A portable snapshot of every profile and the group structure; Base Hosts and active state
    /// stay on this machine. Nil until the workspace has loaded.
    func exportSnapshotData() throws -> Data? {
        guard let model else { return nil }
        return try ExportSnapshot(of: model).encoded()
    }

    private struct ImportFileFailure: Error {
        let fileName: String
        let underlying: any Error
    }

    private static func importFailureMessage(for error: any Error) -> String {
        if case ImportCommitError.workspaceNotLoaded = error {
            return String(localized: "Nothing was imported: the workspace is not loaded.")
        }
        guard let failure = error as? ImportFileFailure else {
            return String(localized: "Nothing was imported: \(String(describing: error))")
        }
        let reason = switch failure.underlying as? ImportError {
        case .unsupportedVersion(let version):
            String(localized: "this file was created by a newer version of hostflip (format version \(version))")
        case .malformedSnapshot:
            String(localized: "this file is JSON but not a valid hostflip export")
        case .blankName:
            String(localized: "the export contains a profile or group with an empty name")
        case .invalidTextEncoding:
            String(localized: "this file is not UTF-8 text")
        case nil:
            "\(failure.underlying)"
        }
        return String(localized: "Nothing was imported. \(failure.fileName): \(reason).")
    }

    private static func switchHostsImportFailureMessage(for error: any Error) -> String {
        switch error {
        case SwitchHostsImportError.dataNotFound:
            String(localized: "Nothing was imported: no SwitchHosts data was found in that folder.")
        case SwitchHostsImportError.malformedData(let file):
            String(localized: "Nothing was imported: the SwitchHosts data could not be read (\(file)).")
        case ImportCommitError.workspaceNotLoaded:
            String(localized: "Nothing was imported: the workspace is not loaded.")
        default:
            String(localized: "Nothing was imported: \(String(describing: error))")
        }
    }

    // MARK: - Persisting and follow-up merging

    /// Shared path for edit-type changes: persist the edit synchronously by replaying it on the
    /// latest state (persistByReplaying) → schedule a follow-up merge.
    private func applyEdit(_ edit: (inout ActivationModel) throws -> Void) {
        guard model != nil else { return }
        // Every new edit first cancels the old follow-up merge: its content is stale. This must
        // happen before saving — if the save fails and returns early, a late success from the old
        // task must not clear this save error
        followUpMergeTask?.cancel()
        // The comparison derives from the model; recompute it once the model reaches its final
        // state on every exit path (a failed save keeps the edit in memory)
        defer {
            if hasHostsDrift {
                refreshHostsDriftComparison()
            }
        }
        do {
            guard case .saved = try persistByReplaying(edit) else {
                // The edit's target no longer exists on disk (an external writer removed it):
                // the edit is dropped and the model now shows the latest state
                return
            }
        } catch {
            saveError = String(localized: "Save failed: \(String(describing: error))")
            return
        }
        scheduleFollowUpMerge()
    }

    /// ADR-0010 ② for every GUI save: replays `change` on the latest on-disk state under the
    /// manifest lock, so changes an external writer made since the last load survive the save.
    /// Two deliberate departures:
    /// - Degraded mode: while an earlier save failure keeps unsaved edits in the in-memory model
    ///   (saveError != nil), the replay target is that model and it is written whole, so the
    ///   unsaved edits self-heal on the next successful save instead of being dropped by a reload.
    /// - Disk failure: the change is still committed to the in-memory model — the user's edit must
    ///   not vanish while the disk is unwritable — before rethrowing for the caller to report.
    /// On .saved the in-memory model equals the persisted state; on .conflict nothing was written
    /// and the in-memory model shows the latest on-disk state, which lacks the change's target.
    private func persistByReplaying(
        _ change: (inout ActivationModel) throws -> Void,
        acceptingSystemHostsHash acceptedHash: String? = nil
    ) throws -> Workspace.ReplayedSaveOutcome {
        if saveError != nil {
            guard var current = model else { throw WorkspaceError.notInitialized }
            try change(&current)
            model = current
            if let acceptedHash {
                try workspace.save(current, acceptingSystemHostsHash: acceptedHash)
            } else {
                try workspace.save(current)
            }
            saveError = nil
            return .saved(current)
        }
        let outcome: Workspace.ReplayedSaveOutcome
        do {
            if let acceptedHash {
                outcome = try workspace.save(applying: change, acceptingSystemHostsHash: acceptedHash)
            } else {
                outcome = try workspace.save(applying: change)
            }
        } catch {
            if var current = model, (try? change(&current)) != nil {
                model = current
            }
            throw error
        }
        switch outcome {
        case .saved(let saved):
            model = saved
        case .conflict(let latest, _):
            model = latest
        }
        return outcome
    }

    /// Converges with one merge 800ms after typing stops; stale schedules were already cancelled
    /// at the edit entry point. The merged content is taken from the latest model when it fires,
    /// so active-state changes committed while scheduled are not overwritten by an outdated
    /// snapshot. When not yet approved, mergeIfAuthorized silently skips and the content waits
    /// to be written by the next real switch.
    private func scheduleFollowUpMerge() {
        followUpMergeTask = Task { [coordinator] in
            do {
                try await Task.sleep(for: .milliseconds(800))
            } catch {
                return
            }
            guard let merged = model?.mergedHosts else { return }
            let failure: String?
            do {
                if case .channelFailed(let error, _)? = try await coordinator.mergeIfAuthorized(merged) {
                    failure = backgroundSyncFailureMessage(for: error)
                } else {
                    failure = nil
                }
            } catch {
                failure = backgroundSyncFailureMessage(for: error)
            }
            // An old task superseded by a newer edit does not report; a late stale result must not
            // overwrite the new state. On success, clear any failure copy left by earlier follow-up merges
            guard !Task.isCancelled else { return }
            backgroundSyncError = failure
        }
    }

    private func backgroundSyncFailureMessage(for error: any Error) -> String {
        if let channelError = error as? DaemonChannelError {
            return backgroundSyncFailureMessage(for: channelError)
        }
        return String(
            localized: "Changes were saved locally, but the system hosts file could not be updated: \(String(describing: error))"
        )
    }

    private func backgroundSyncFailureMessage(for error: DaemonChannelError) -> String {
        if error == .selfSigningUnavailable {
            return String(
                localized: "Changes were saved locally, but this build is not properly signed, so the system hosts file could not be updated."
            )
        }
        return String(
            localized: "Changes were saved locally, but the system hosts file could not be updated: \(String(describing: error))"
        )
    }
}
