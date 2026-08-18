import Foundation
import HostflipCore
import HostflipXPC

/// `hostflip refresh [target]` (ADR-0012): fetches Remote Profile content from the Source
/// URLs — every remote profile without a target, exactly one with — and commits the results
/// in one locked save. The two layers report independently: the workspace content update
/// always lands, and only when a changed profile is active and not paused does the command
/// try to rewrite the system hosts — a write blocked by drift exits 3, an unavailable daemon
/// exits 4, both with the fetched content kept, never rolled back. Fetches are conditional
/// when validators are stored (a 304 advances the refresh state without a download), run
/// concurrently, and report per profile in `--json`; a partial source failure exits 1 unless
/// a blocked write's 3/4 outranks it.
enum RefreshCommand {
    /// What one profile's refresh concluded; the raw strings are the `--json` contract.
    enum ProfileStatus: String, Encodable {
        /// Fetched, validated, and stored: the content changed.
        case updated
        /// The source is current — a 304, or a full body identical to the stored one.
        case unchanged
        /// The fetch or a validation gate refused; the stored content stays.
        case failed
        /// Dropped: a peer writer refreshed or changed the profile while the fetch was in
        /// flight, and its newer state wins over this response.
        case stale
    }

    /// A failure in the `--json` result: the stable `code` is the semantic carrier.
    struct ReportedError: Encodable {
        let code: String
        let message: String
    }

    struct ProfileResult: Encodable {
        let id: String
        let name: String
        /// The containing group's name; absent for a standalone profile.
        let group: String?
        let url: String
        let status: ProfileStatus
        /// Present only when the status is `failed`.
        let error: ReportedError?

        var reference: String {
            group.map { "\($0)/\(name)" } ?? name
        }
    }

    /// What the system hosts write layer concluded; the raw strings are the `--json` contract.
    enum WriteStatus: String, Encodable {
        /// An active, unpaused profile changed and the daemon rewrote the system hosts.
        case written
        /// No active, unpaused profile changed; the system hosts already matches.
        case notNeeded = "not-needed"
        /// The write was blocked or failed; the saved content stays and `error` says why.
        case failed
    }

    struct WriteReport: Encodable {
        let status: WriteStatus
        /// Present only when the status is `failed`.
        let error: ReportedError?
    }

    struct Payload: CommandPayload {
        let profiles: [ProfileResult]
        let write: WriteReport
        /// The blocked write's exit code (3 for drift, 4 for daemon-unavailable, 1
        /// otherwise); nil when the write layer succeeded or was not needed. Not part of the
        /// JSON — the stable error codes carry the same distinction there.
        let writeFailureExit: ExitCode?

        private enum CodingKeys: String, CodingKey {
            case profiles, write
        }

        /// A blocked write outranks a partial fetch failure: 3/4 demand human action on the
        /// live system state, while the per-profile results still carry every fetch outcome.
        var exitCode: ExitCode {
            if let writeFailureExit {
                return writeFailureExit
            }
            return profiles.contains { $0.status == .failed } ? .failure : .success
        }

        var humanText: String {
            guard !profiles.isEmpty else { return "No remote profiles." }
            let succeeded = profiles.count { $0.status == .updated || $0.status == .unchanged }
            var text = "Refreshed \(succeeded) of \(profiles.count) remote "
                + (profiles.count == 1 ? "profile" : "profiles") + ".\n"
            text += CLIColumns.render(profiles.map { profile in
                (
                    label: "  " + profile.status.rawValue,
                    trailing: profile.reference
                        + (profile.error.map { ": \($0.message)" } ?? "")
                )
            })
            if write.status == .written {
                text += "\nThe system hosts was updated."
            }
            return text
        }

        /// The blocked-write diagnostic belongs on stderr in human mode; the messages are
        /// self-contained about the content having been saved.
        var humanStandardError: String {
            guard let error = write.error else { return "" }
            return "hostflip: \(error.message)\n"
        }
    }

    /// One fetch target, with the state captured before the fetch: the success-time baseline
    /// plus the stored body identify the content revision the fetch starts from — a peer
    /// refreshing the same URL mid-flight bumps the time or the body, making this fetch's
    /// possibly older response stale (the same discipline as the app's refresh path). The
    /// body backs the timestamp up because the manifest stores whole seconds: two refreshes
    /// landing within one second would otherwise compare equal.
    private struct Target {
        let profile: Profile
        let groupName: String?
        let header: RemoteHeader
        let baseline: Date?
        let baselineBody: String?
        let validators: RemoteContentValidators?

        init(profile: Profile, groupName: String?, header: RemoteHeader) {
            self.profile = profile
            self.groupName = groupName
            self.header = header
            baseline = profile.remoteRefreshState?.lastSuccessAt
            baselineBody = RemoteHeader.storedBody(of: profile.content)
            validators = profile.remoteRefreshState?.validators
        }
    }

    private enum FetchConclusion {
        case outcome(RemoteFetchOutcome)
        case refused(ReportedError)
    }

    /// A child task's result as a named struct, deliberately not a tuple: with the current
    /// toolchain (Swift 6.3.3), a `(Profile.ID, FetchConclusion)` child result made the
    /// release-optimized task group yield nothing — every fetch conclusion was dropped and
    /// each profile reported stale. Debug builds and instrumented release builds were
    /// unaffected (codegen-sensitive), so this shape is load-bearing; verified against the
    /// miscompiling workspace bytes before and after.
    private struct FetchedConclusion {
        let profileID: Profile.ID
        let conclusion: FetchConclusion
    }

    static func run(
        reference: ProfileReference?,
        workspace: Workspace,
        systemHostsURL: URL,
        merger: any HostsMerging,
        fetchRemote: @escaping @Sendable (URL, RemoteContentValidators?) async throws -> RemoteFetchOutcome,
        postWorkspaceChanged: @Sendable (Workspace) -> Void
    ) async throws -> Payload {
        let model = try workspace.openReadOnly()
        let targets = try resolveTargets(reference, in: model)
        guard !targets.isEmpty else {
            return Payload(
                profiles: [],
                write: WriteReport(status: .notNeeded, error: nil),
                writeFailureExit: nil
            )
        }

        let conclusions = await fetchAll(targets, fetchRemote: fetchRemote)

        // One locked save commits every fetch result by replaying it on the latest on-disk
        // state (ADR-0010 ②). Per-profile staleness marks the result dropped instead of
        // throwing: one stale profile must not abort the batch, and Workspace.save treats a
        // throwing closure as a whole-save conflict.
        var statuses: [Profile.ID: ProfileStatus] = [:]
        var changedIDs: Set<Profile.ID> = []
        let refreshedAt = Date()
        let apply: (inout ActivationModel) throws -> Void = { latest in
            statuses = [:]
            changedIDs = []
            for target in targets {
                guard let conclusion = conclusions[target.profile.id] else { continue }
                let profileID = target.profile.id
                guard let current = latest.profile(profileID),
                      let header = current.remoteHeader,
                      header.sourceURL == target.header.sourceURL,
                      current.remoteRefreshState?.lastSuccessAt == target.baseline,
                      RemoteHeader.storedBody(of: current.content) == target.baselineBody else {
                    statuses[profileID] = .stale
                    continue
                }
                switch conclusion {
                case .refused:
                    try latest.recordRemoteRefreshFailure(profileID)
                    statuses[profileID] = .failed
                case .outcome(.notModified(let validators)):
                    try latest.recordRemoteRefreshSuccess(
                        profileID,
                        at: refreshedAt,
                        validators: RemoteContentValidators.merged(
                            stored: current.remoteRefreshState?.validators,
                            refreshed: validators
                        )
                    )
                    statuses[profileID] = .unchanged
                case .outcome(.content(let fetched, let validators)):
                    let newBody = RemoteHeader.escapingEmbeddedHeader(in: fetched)
                    if RemoteHeader.storedBody(of: current.content) != newBody {
                        try latest.updateProfileContent(
                            profileID,
                            content: header.storedContent(forFetched: fetched)
                        )
                        changedIDs.insert(profileID)
                        statuses[profileID] = .updated
                    } else {
                        statuses[profileID] = .unchanged
                    }
                    try latest.recordRemoteRefreshSuccess(
                        profileID, at: refreshedAt, validators: validators
                    )
                }
            }
        }
        guard case .saved(let saved) = try workspace.save(applying: apply) else {
            // Unreachable while apply never throws; kept as the honest report if it ever does.
            throw CLIError(
                code: "state-save-conflict",
                message: "a peer writer changed the workspace so the refresh results could not be saved; retry",
                exitCode: .failure
            )
        }

        let results = targets.map { target in
            let status = statuses[target.profile.id] ?? .stale
            var error: ReportedError?
            if status == .failed, case .refused(let refusal)? = conclusions[target.profile.id] {
                error = refusal
            }
            return ProfileResult(
                id: target.profile.id.rawValue,
                name: target.profile.name,
                group: target.groupName,
                url: target.header.sourceURL.absoluteString,
                status: status,
                error: error
            )
        }

        // Only a changed, active, unpaused profile makes the merged output differ; everything
        // else already matches the system hosts.
        let write: WriteReport
        var writeFailureExit: ExitCode?
        if !saved.isPaused, changedIDs.contains(where: { saved.activeProfileIDs.contains($0) }) {
            // Merged from the latest on-disk state, not the save's snapshot: a peer committing
            // between the save and this write would otherwise have its newer state overwritten
            // by the snapshot (the app's follow-up merge reads the latest model the same way).
            // The remaining read-to-write window is inherent to the current daemon protocol.
            let merged = (try? workspace.openReadOnly().mergedHosts) ?? saved.mergedHosts
            let (report, exit) = await writeSystemHosts(
                merged,
                workspace: workspace,
                systemHostsURL: systemHostsURL,
                merger: merger
            )
            write = report
            writeFailureExit = exit
        } else {
            write = WriteReport(status: .notNeeded, error: nil)
        }
        // Announced once the whole run concluded (ADR-0010 ③): the notification then also
        // covers the write layer's manifest updates (a landed write's recorded hash), so a
        // running GUI never sees a state the very next change would contradict.
        postWorkspaceChanged(workspace)
        return Payload(profiles: results, write: write, writeFailureExit: writeFailureExit)
    }

    // MARK: - Target resolution

    private static func resolveTargets(
        _ reference: ProfileReference?,
        in model: ActivationModel
    ) throws -> [Target] {
        guard let reference else {
            // Every Remote Profile in model order: standalone first, then each group's members.
            let entries = model.standaloneProfiles.map { ($0, String?.none) }
                + model.groups.flatMap { group in group.profiles.map { ($0, String?.some(group.name)) } }
            return entries.compactMap { profile, groupName in
                profile.remoteHeader.map { Target(profile: profile, groupName: groupName, header: $0) }
            }
        }
        let match = try ProfileResolver.resolve(reference, in: model)
        guard let header = match.profile.remoteHeader else {
            let reference = match.groupName.map { "\($0)/\(match.profile.name)" } ?? match.profile.name
            throw CLIError(
                code: "profile-not-remote",
                message: "'\(reference)' is not a remote profile; only remote profiles have a Source URL to refresh",
                exitCode: .failure
            )
        }
        return [Target(profile: match.profile, groupName: match.groupName, header: header)]
    }

    // MARK: - Fetching

    private static func fetchAll(
        _ targets: [Target],
        fetchRemote: @escaping @Sendable (URL, RemoteContentValidators?) async throws -> RemoteFetchOutcome
    ) async -> [Profile.ID: FetchConclusion] {
        let collected = await withTaskGroup(of: FetchedConclusion.self) { group in
            for target in targets {
                group.addTask {
                    do {
                        let outcome = try await fetchRemote(target.header.sourceURL, target.validators)
                        return FetchedConclusion(profileID: target.profile.id, conclusion: .outcome(outcome))
                    } catch {
                        return FetchedConclusion(
                            profileID: target.profile.id,
                            conclusion: .refused(reportedError(for: error))
                        )
                    }
                }
            }
            var results: [FetchedConclusion] = []
            for await result in group {
                results.append(result)
            }
            return results
        }
        var conclusions: [Profile.ID: FetchConclusion] = [:]
        for result in collected {
            conclusions[result.profileID] = result.conclusion
        }
        return conclusions
    }

    /// The fetch engine's refusals as stable string codes (the `--json` contract) with plain
    /// human copy, mirroring the app's failure messages.
    private static func reportedError(for error: any Error) -> ReportedError {
        guard let fetchError = error as? RemoteFetchError else {
            return ReportedError(code: "fetch-failed", message: error.localizedDescription)
        }
        return switch fetchError {
        case .notHTTPS:
            ReportedError(code: "source-not-https", message: "the Source URL must be an HTTPS address")
        case .insecureRedirect:
            ReportedError(code: "insecure-redirect", message: "the URL redirected to a non-HTTPS address")
        case .requestFailed(let message):
            ReportedError(code: "fetch-failed", message: "the Source URL could not be reached: \(message)")
        case .httpStatus(let code):
            ReportedError(code: "http-status", message: "the server responded with HTTP \(code)")
        case .tooLarge:
            ReportedError(code: "content-too-large", message: "the fetched content is larger than 10 MB")
        case .notUTF8:
            ReportedError(code: "content-not-utf8", message: "the fetched content is not UTF-8 text")
        case .looksLikeHTML:
            ReportedError(code: "content-is-html", message: "the URL returned a web page, not hosts content")
        }
    }

    // MARK: - The system hosts write layer

    /// Attempts the daemon write for already-saved content. Every refusal becomes a report,
    /// not a thrown error: the content commit above must stand, and the payload carries both
    /// layers' outcomes. The daemon is never registered from here (DaemonHostsMerger).
    private static func writeSystemHosts(
        _ merged: MergedHosts,
        workspace: Workspace,
        systemHostsURL: URL,
        merger: any HostsMerging
    ) async -> (WriteReport, ExitCode?) {
        do {
            try MergeCommitFlow.requireNoDrift(workspace: workspace, systemHostsURL: systemHostsURL)
            _ = try await MergeCommitFlow.mergeWithOneRetry(merged, via: merger)
            return (WriteReport(status: .written, error: nil), nil)
        } catch let DaemonChannelError.mergeWriteFailed(failure) where failure.writtenHash == merged.hash {
            // The atomic replacement physically landed and only a later flush stage failed:
            // record the baseline hash so the very next status does not misreport drift
            // (MergeCommitFlow's rule); a failure to record joins the report.
            let recorded: Bool = (try? workspace.recordLastWrittenHash(merged.hash)) != nil
            let suffix = recorded ? "" : "; the write baseline could not be recorded, so 'hostflip status' may report drift"
            let shared = MergeCommitFlow.dnsFlushFailure(failure)
            return (
                WriteReport(status: .failed, error: ReportedError(
                    code: shared.code,
                    message: shared.message + suffix
                )),
                .failure
            )
        } catch let error as ConfirmedWriteBaselineError {
            // The daemon did write: "was not updated" would be false. CLI.normalize's
            // message already states both facts.
            let normalized = CLI.normalize(error)
            return (
                WriteReport(status: .failed, error: ReportedError(
                    code: normalized.code, message: normalized.message
                )),
                normalized.exitCode
            )
        } catch {
            let normalized = CLI.normalize(error)
            return (
                WriteReport(status: .failed, error: ReportedError(
                    code: normalized.code,
                    message: "refreshed content was saved, but the system hosts was not updated: \(normalized.message)"
                )),
                normalized.exitCode
            )
        }
    }
}
