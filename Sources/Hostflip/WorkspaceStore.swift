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
        case .merged: "System Hosts Updated"
        case .baseHostsReplaced: "Base Hosts Replaced"
        case .needsApproval: "Approval Required"
        case .unavailable: "Helper Unavailable"
        case .hostsDrift: "Hosts Drift Detected"
        case .failed: "Switch Failed"
        }
    }

    var message: String {
        switch self {
        case .merged:
            "System hosts file updated"
        case .baseHostsReplaced:
            "Base Hosts replaced with the current /etc/hosts content. The system file was not changed."
        case .needsApproval:
            "Switch blocked: hostflip’s background helper needs system approval"
        case .unavailable:
            "Helper unavailable: move the app to the Applications folder and reopen it"
        case .hostsDrift:
            "Switch blocked: system hosts contains changes made outside hostflip"
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

/// Result of one import (#40): either every file was applied, or none was.
enum ImportOutcome: Equatable {
    case imported
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
    private(set) var model: ActivationModel?
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
    /// The in-flight follow-up merge task; tests await its completion before asserting the result.
    private(set) var followUpMergeTask: Task<Void, Never>?
    private var hostsDriftGeneration = 0
    /// While a reconcile has written the system hosts but the latest reviewed state or the
    /// workspace persistence is not yet confirmed, keep blocking new writes even if the
    /// monitor briefly reports no drift.
    private var reconciliationNeedsAttention = false

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
    }

    /// Injection seam: tests substitute a temporary workspace + a coordinator stub for real XPC.
    init(
        workspace: Workspace,
        coordinator: any SwitchCoordinating,
        openApproval: @escaping @Sendable () -> Void = {},
        driftMonitor: (any HostsDriftMonitoring)? = nil,
        readSystemHosts: @escaping @Sendable () throws -> Data = {
            try Data(contentsOf: URL(fileURLWithPath: "/etc/hosts"))
        }
    ) {
        self.workspace = workspace
        self.coordinator = coordinator
        self.openApproval = openApproval
        self.driftMonitor = driftMonitor
        self.readSystemHosts = readSystemHosts
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
            loadError = "Cannot open workspace: \(error)"
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
                systemHostsReadError = "Cannot display /etc/hosts because it is not valid UTF-8."
                return
            }
            systemHostsContent = content
            systemHostsReadError = nil
        } catch {
            systemHostsContent = nil
            systemHostsReadError = "Cannot read /etc/hosts: \(error)"
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

    func renameProfile(_ profileID: Profile.ID, to name: String) {
        guard let profile = profile(profileID),
              let normalized = normalizedRenameName(name, currentName: profile.name) else { return }
        applyEdit { try $0.renameProfile(profileID, to: normalized) }
    }

    func updateProfileContent(_ profileID: Profile.ID, content: String) {
        guard let profile = profile(profileID), profile.content != content else { return }
        applyEdit { try $0.updateProfileContent(profileID, content: content) }
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
        var candidate = "New Profile"
        var counter = 2
        while existing.contains(candidate) {
            candidate = "New Profile \(counter)"
            counter += 1
        }
        return candidate
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
        var candidate = "New Group"
        var counter = 2
        while existing.contains(candidate) {
            candidate = "New Group \(counter)"
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
                        "System hosts was updated, but DNS refresh failed: \(failure.message)"
                    )
                case .failed(let error):
                    switchFeedback = .failed("Failed to update the system hosts file: \(error)")
                }
            } catch {
                switchFeedback = .failed("Switch failed: \(error)")
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

    /// The merge has succeeded: replay this change on the latest model and persist it. The system
    /// hosts is already updated at this point, so a save failure only affects the manifest — the
    /// feedback is still a successful switch, with the save error reported separately.
    /// A follow-up merge is scheduled at the end: if in-flight edits were queued ahead of this
    /// switch, it converges the latest content into the system hosts; when the content matches,
    /// the daemon short-circuits idempotently and no extra write happens.
    private func commitSwitched(_ change: (inout ActivationModel) throws -> Void) {
        defer { scheduleFollowUpMerge() }
        guard var current = model else { return }
        do {
            try change(&current)
        } catch {
            // Replay conflict (e.g. the profile was deleted mid-flight): do not commit; the follow-up merge converges the system hosts back to the current model
            return
        }
        model = current
        do {
            try workspace.save(current)
            saveError = nil
            backgroundSyncError = nil
        } catch {
            saveError = "Save failed: \(error)"
        }
        switchFeedback = .merged
    }

    func clearSwitchFeedback() {
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

        switch choice {
        case .addDriftLinesToBaseHosts:
            updated.baseHosts.content = comparison.appendingDriftAdditions(
                to: updated.baseHosts.content
            )
        case .overwriteDriftWithActiveState:
            break
        case .later:
            reconciliationTask = nil
            return
        }

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
                          persistReconciledModel(updated) else { return }
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
                          persistReconciledModel(updated, writtenHash: failure.writtenHash)
                    else { return }
                    hasHostsDrift = false
                    hostsDriftComparison = nil
                    let message = "System hosts was updated, but DNS refresh failed: \(failure.message)"
                    reconciliationError = message
                    switchFeedback = .failed(message)
                case .hostsDrift:
                    refreshHostsDriftComparison()
                    reconciliationError = "System hosts changed again. Review the latest diff before retrying."
                    switchFeedback = .hostsDrift
                case .failed(let error):
                    let message = "Failed to reconcile the system hosts file: \(error)"
                    reconciliationError = message
                    switchFeedback = .failed(message)
                }
            } catch {
                let message = "Hosts reconciliation failed: \(error)"
                reconciliationError = message
                switchFeedback = .failed(message)
            }
        }
    }

    var useSystemHostsAsBaseUnavailableReason: String? {
        guard !isSwitching, !isReconciling else {
            return "Wait for the current hosts operation to finish."
        }
        guard hasHostsDrift, let comparison = hostsDriftComparison else {
            return "No unresolved hosts drift is available to adopt."
        }
        guard model?.activeProfileIDs.isEmpty == true else {
            return "Deactivate every active profile before using System Hosts as Base Hosts."
        }
        guard comparison.actualContent != nil else {
            return "System Hosts must be valid UTF-8 before it can replace Base Hosts."
        }
        guard !comparison.containsGeneratedHostflipOutput else {
            return "System Hosts already contains hostflip-generated sections and cannot be used as Base Hosts."
        }
        return nil
    }

    /// Accepts the user-reviewed system hosts state as the new Base Hosts. This path only updates
    /// the workspace and the accepted hash; it does not go through the helper or rewrite /etc/hosts.
    func useSystemHostsAsBase() {
        guard useSystemHostsAsBaseUnavailableReason == nil,
              let comparison = hostsDriftComparison,
              var updated = model else { return }

        followUpMergeTask?.cancel()
        followUpMergeTask = nil
        do {
            let latestData = try readSystemHosts()
            let latestHash = MergedHosts.hash(of: latestData)
            guard latestHash == comparison.observedActualHash else {
                refreshSystemHosts()
                refreshHostsDriftComparison()
                reconciliationError = "System hosts changed again. Review the latest diff before retrying."
                switchFeedback = .hostsDrift
                return
            }
            guard let latestContent = String(data: latestData, encoding: .utf8) else {
                refreshSystemHosts()
                reconciliationError = "System Hosts must be valid UTF-8 before it can replace Base Hosts."
                switchFeedback = .hostsDrift
                return
            }

            updated.baseHosts.content = latestContent
            try workspace.save(updated, acceptingSystemHostsHash: latestHash)
            model = updated
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
            let message = "Base Hosts could not be replaced: \(error)"
            reconciliationError = message
            switchFeedback = .failed(message)
        }
    }

    private func reconciliationSnapshotIsCurrent(_ reviewedGeneration: Int) -> Bool {
        guard reviewedGeneration == hostsDriftGeneration else {
            reconciliationNeedsAttention = true
            hasHostsDrift = true
            refreshHostsDriftComparison()
            reconciliationError = "System hosts changed while reconciliation was in progress. Review the latest diff before retrying."
            switchFeedback = .hostsDrift
            return false
        }
        return true
    }

    private func persistReconciledModel(
        _ updated: ActivationModel,
        writtenHash: String? = nil
    ) -> Bool {
        model = updated
        do {
            try workspace.save(updated)
            if let writtenHash {
                try workspace.recordLastWrittenHash(writtenHash)
            }
            reconciliationNeedsAttention = false
            saveError = nil
            backgroundSyncError = nil
            return true
        } catch {
            saveError = "Save failed: \(error)"
            reconciliationNeedsAttention = true
            hasHostsDrift = true
            refreshHostsDriftComparison()
            let message = "System hosts was updated, but the reconciliation could not be saved: \(error)"
            reconciliationError = message
            switchFeedback = .failed(message)
            return false
        }
    }

    private func refreshHostsDriftComparison() {
        guard let model else { return }
        let refreshed = try? HostsDriftComparison(
            expectedContent: model.mergedHosts.content,
            actualData: readSystemHosts()
        )
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
        guard var updated = model else {
            return .failed("Nothing was imported: the workspace is not loaded.")
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
            for content in contents {
                switch content {
                case .snapshot(let snapshot):
                    try updated.importSnapshot(snapshot)
                case .plainText(let name, let text):
                    try updated.addProfile(id: Profile.ID(UUID().uuidString), name: name, content: text)
                }
            }
            try workspace.save(updated)
            model = updated
            return .imported
        } catch {
            return .failed(Self.importFailureMessage(for: error))
        }
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
        guard let failure = error as? ImportFileFailure else {
            return "Nothing was imported: \(error)"
        }
        let reason = switch failure.underlying as? ImportError {
        case .unsupportedVersion(let version):
            "this file was created by a newer version of hostflip (format version \(version))"
        case .malformedSnapshot:
            "this file is JSON but not a valid hostflip export"
        case .blankName:
            "the export contains a profile or group with an empty name"
        case .invalidTextEncoding:
            "this file is not UTF-8 text"
        case nil:
            "\(failure.underlying)"
        }
        return "Nothing was imported. \(failure.fileName): \(reason)."
    }

    // MARK: - Persisting and follow-up merging

    /// Shared path for edit-type changes: mutate the in-memory model → save to disk synchronously → schedule a follow-up merge.
    private func applyEdit(_ edit: (inout ActivationModel) throws -> Void) {
        guard var updated = model else { return }
        // Every new edit first cancels the old follow-up merge: its content is stale. This must
        // happen before saving — if the save fails and returns early, a late success from the old
        // task must not clear this save error
        followUpMergeTask?.cancel()
        do {
            try edit(&updated)
        } catch {
            assertionFailure("Failed to apply the edit to the current model: \(error)")
            return
        }
        model = updated
        if hasHostsDrift {
            refreshHostsDriftComparison()
        }
        do {
            try workspace.save(updated)
            saveError = nil
        } catch {
            saveError = "Save failed: \(error)"
            return
        }
        scheduleFollowUpMerge()
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
        return "Changes were saved locally, but the system hosts file could not be updated: \(error)"
    }

    private func backgroundSyncFailureMessage(for error: DaemonChannelError) -> String {
        if error == .selfSigningUnavailable {
            return "Changes were saved locally, but this build is not properly signed, so the system hosts file could not be updated."
        }
        return "Changes were saved locally, but the system hosts file could not be updated: \(error)"
    }
}
