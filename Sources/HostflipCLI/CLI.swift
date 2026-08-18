import Foundation
import HostflipCore
import HostflipXPC

/// Parses one invocation and dispatches to the command implementations. Help and documentation
/// show canonical verbs only; any future aliases stay out of both.
enum CLI {
    static let usageText = """
        Usage: hostflip [--json] <command> [<argument>]

        Commands:
          status      Report the pause state, active profiles, and system hosts drift
          doctor      Diagnose one hostname: profiles, merge, file, resolver, guidance
          list        List the group structure and every profile with its ID
          cat         Print a profile's content exactly as stored
          create      Create an empty profile: standalone by default, in a group via group/name
          write       Replace a profile's content from stdin or --file
          delete      Delete a profile; an active profile leaves the merge first
          refresh     Refresh remote profiles from their Source URLs (all, or one target)
          activate    Activate a profile and rewrite the system hosts via the daemon
          deactivate  Deactivate a profile and rewrite the system hosts via the daemon
          pause       Rewrite the system hosts with Base Hosts only, keeping active state
          resume      Rewrite the system hosts with the kept active profiles restored

        Profiles are addressed by name, by group/profile path, or by --id when the
        name is ambiguous (names are not unique; IDs are — see 'hostflip list').
        'refresh' may omit its target to refresh every remote profile: fetched
        content is always saved to the workspace, and the system hosts is only
        rewritten when an active profile changed — a write blocked by drift exits
        3, an unavailable daemon exits 4, with the content kept either way.
        'doctor' takes a hostname instead and is read-only: it never contacts the
        daemon and exits 7 when the diagnosis finds an inconsistency.

        Options:
          --id <id>      Address a profile by its unique ID
          --file <path>  Read the new content for 'write' from a file instead of stdin
          --json         Machine-readable output: result object on stdout, JSON errors on stderr
          --version      Print the version and exit
          --help         Show this help
        """

    static func run(
        arguments: [String],
        workspaceRootDirectory: URL,
        systemHostsURL: URL,
        makeHostsMerger: @Sendable (Workspace) -> any HostsMerging = { DaemonHostsMerger(workspace: $0) },
        resolveHostname: @Sendable (String) -> ResolverReply = { SystemResolver.query($0) },
        fetchRemote: @escaping @Sendable (URL, RemoteContentValidators?) async throws -> RemoteFetchOutcome = {
            try await RemoteFetcher().fetch(from: $0, validators: $1)
        },
        postWorkspaceChanged: @escaping @Sendable (Workspace) -> Void = CLI.postDistributedWorkspaceChange,
        readStandardInput: @Sendable () throws -> Data = { try FileHandle.standardInput.readToEnd() ?? Data() }
    ) async -> CLIResult {
        // The output mode is decided by scanning the whole argv, not during parsing, so even a
        // usage error earlier in the argument list is rendered in the requested format.
        let wantsJSON = arguments.contains("--json")
        do {
            let invocation = try parse(arguments)
            if invocation.wantsHelp {
                return CLIResult(exitCode: .success, standardOutput: usageText + "\n", standardError: "")
            }
            let payload: any CommandPayload
            if invocation.wantsVersion {
                payload = VersionPayload()
            } else {
                payload = try await dispatch(
                    invocation,
                    workspace: Workspace(rootDirectory: workspaceRootDirectory),
                    systemHostsURL: systemHostsURL,
                    makeHostsMerger: makeHostsMerger,
                    resolveHostname: resolveHostname,
                    fetchRemote: fetchRemote,
                    postWorkspaceChanged: postWorkspaceChanged,
                    readStandardInput: readStandardInput
                )
            }
            let output: String
            if wantsJSON {
                output = CLIJSON.encode(payload) + "\n"
            } else if payload.humanTextIsVerbatim {
                output = payload.humanText
            } else {
                output = payload.humanText + "\n"
            }
            return CLIResult(
                exitCode: payload.exitCode,
                standardOutput: output,
                standardError: wantsJSON ? "" : payload.humanStandardError
            )
        } catch {
            let normalized = normalize(error)
            return CLIResult(
                exitCode: normalized.exitCode,
                standardOutput: "",
                standardError: render(normalized, asJSON: wantsJSON) + "\n"
            )
        }
    }

    // MARK: - Parsing

    private struct Invocation {
        var wantsHelp = false
        var wantsVersion = false
        var profileID: String?
        var filePath: String?
        var commandArguments: [String] = []
    }

    /// The CLI ships in the app bundle at the app's version (ADR-0009), so this is the one
    /// version constant release.sh already guards against the bundle plist.
    private struct VersionPayload: CommandPayload {
        let version = HostflipBuild.version
        var humanText: String { version }
    }

    private static func parse(_ arguments: [String]) throws -> Invocation {
        var invocation = Invocation()
        var iterator = arguments.makeIterator()
        while let argument = iterator.next() {
            switch argument {
            case "--json":
                break // Handled by the argv scan in run.
            case "--help", "-h":
                invocation.wantsHelp = true
            case "--version":
                invocation.wantsVersion = true
            case "--id":
                guard let value = iterator.next() else {
                    throw CLIError.usage("option '--id' requires a value")
                }
                invocation.profileID = value
            case "--file":
                guard let value = iterator.next() else {
                    throw CLIError.usage("option '--file' requires a value")
                }
                invocation.filePath = value
            case _ where argument.hasPrefix("-"):
                throw CLIError.usage("unknown option '\(argument)'")
            default:
                invocation.commandArguments.append(argument)
            }
        }
        return invocation
    }

    // MARK: - Dispatch

    private static func dispatch(
        _ invocation: Invocation,
        workspace: Workspace,
        systemHostsURL: URL,
        makeHostsMerger: @Sendable (Workspace) -> any HostsMerging,
        resolveHostname: @Sendable (String) -> ResolverReply,
        fetchRemote: @escaping @Sendable (URL, RemoteContentValidators?) async throws -> RemoteFetchOutcome,
        postWorkspaceChanged: @escaping @Sendable (Workspace) -> Void,
        readStandardInput: @Sendable () throws -> Data
    ) async throws -> any CommandPayload {
        guard let command = invocation.commandArguments.first else {
            throw CLIError.usage("no command given")
        }
        if invocation.filePath != nil, command != "write" {
            throw CLIError.usage("option '--file' is only valid with 'write'")
        }
        switch command {
        case "status":
            try requireNoArguments(in: invocation)
            return try StatusCommand.run(workspace: workspace, systemHostsURL: systemHostsURL)
        case "doctor":
            return try DoctorCommand.run(
                hostname: requireHostname(in: invocation),
                workspace: workspace,
                systemHostsURL: systemHostsURL,
                resolveHostname: resolveHostname
            )
        case "list":
            try requireNoArguments(in: invocation)
            return try ListCommand.run(workspace: workspace)
        case "cat":
            return try CatCommand.run(
                reference: requireProfileReference(in: invocation, command: command),
                workspace: workspace
            )
        case "create":
            return try CreateCommand.run(
                target: requireCreateTarget(in: invocation),
                workspace: workspace,
                postWorkspaceChanged: postWorkspaceChanged
            )
        case "write":
            return try await WriteCommand.run(
                reference: requireProfileReference(in: invocation, command: command),
                filePath: invocation.filePath,
                readStandardInput: readStandardInput,
                workspace: workspace,
                systemHostsURL: systemHostsURL,
                merger: makeHostsMerger(workspace),
                postWorkspaceChanged: postWorkspaceChanged
            )
        case "delete":
            return try await DeleteCommand.run(
                reference: requireProfileReference(in: invocation, command: command),
                workspace: workspace,
                systemHostsURL: systemHostsURL,
                merger: makeHostsMerger(workspace),
                postWorkspaceChanged: postWorkspaceChanged
            )
        case "refresh":
            return try await RefreshCommand.run(
                reference: optionalProfileReference(in: invocation),
                workspace: workspace,
                systemHostsURL: systemHostsURL,
                merger: makeHostsMerger(workspace),
                fetchRemote: fetchRemote,
                postWorkspaceChanged: postWorkspaceChanged
            )
        // "on"/"off" are entry aliases only: they always require the profile argument (a bare
        // `off` is a usage error, keeping it unmistakable from `pause`) and never appear in help.
        case "activate", "on", "deactivate", "off":
            return try await SwitchCommand.setActive(
                command == "activate" || command == "on",
                reference: requireProfileReference(in: invocation, command: command),
                workspace: workspace,
                systemHostsURL: systemHostsURL,
                merger: makeHostsMerger(workspace),
                postWorkspaceChanged: postWorkspaceChanged
            )
        case "pause", "resume":
            try requireNoArguments(in: invocation)
            return try await SwitchCommand.setPaused(
                command == "pause",
                workspace: workspace,
                systemHostsURL: systemHostsURL,
                merger: makeHostsMerger(workspace),
                postWorkspaceChanged: postWorkspaceChanged
            )
        default:
            throw CLIError.usage("unknown command '\(command)'")
        }
    }

    private static func requireNoArguments(in invocation: Invocation) throws {
        if let extra = invocation.commandArguments.dropFirst().first {
            throw CLIError.usage("unexpected argument '\(extra)'")
        }
        if invocation.profileID != nil {
            throw CLIError.usage("unexpected option '--id'")
        }
    }

    /// Extracts create's one positional target: a new profile's name, or a group/name path.
    /// The target names something that does not exist yet, so the --id addressing form has no
    /// meaning here and is rejected.
    private static func requireCreateTarget(in invocation: Invocation) throws -> String {
        if invocation.profileID != nil {
            throw CLIError.usage("unexpected option '--id'")
        }
        let positionals = invocation.commandArguments.dropFirst()
        if let extra = positionals.dropFirst().first {
            throw CLIError.usage("unexpected argument '\(extra)'")
        }
        guard let target = positionals.first else {
            throw CLIError.usage("'create' needs a profile name or group/name path")
        }
        return target
    }

    /// Extracts doctor's one positional hostname. doctor addresses a hostname, never a
    /// profile, so the --id addressing form has no meaning here and is rejected.
    private static func requireHostname(in invocation: Invocation) throws -> String {
        if invocation.profileID != nil {
            throw CLIError.usage("unexpected option '--id'")
        }
        let positionals = invocation.commandArguments.dropFirst()
        if let extra = positionals.dropFirst().first {
            throw CLIError.usage("unexpected argument '\(extra)'")
        }
        guard let hostname = positionals.first else {
            throw CLIError.usage("'doctor' needs a hostname")
        }
        return hostname
    }

    /// Extracts refresh's optional profile reference: at most one of a positional name/path
    /// or --id; nil (no target at all) means "every remote profile".
    private static func optionalProfileReference(in invocation: Invocation) throws -> ProfileReference? {
        let positionals = invocation.commandArguments.dropFirst()
        if let extra = positionals.dropFirst().first {
            throw CLIError.usage("unexpected argument '\(extra)'")
        }
        switch (positionals.first, invocation.profileID) {
        case (let reference?, nil):
            return .nameOrPath(reference)
        case (nil, let id?):
            return .id(id)
        case (nil, nil):
            return nil
        case (.some, .some):
            throw CLIError.usage("give a profile name or --id, not both")
        }
    }

    /// Extracts the one profile reference of a profile-addressed command: exactly one of a
    /// positional name/path or --id.
    private static func requireProfileReference(
        in invocation: Invocation,
        command: String
    ) throws -> ProfileReference {
        let positionals = invocation.commandArguments.dropFirst()
        if let extra = positionals.dropFirst().first {
            throw CLIError.usage("unexpected argument '\(extra)'")
        }
        switch (positionals.first, invocation.profileID) {
        case (let reference?, nil):
            return .nameOrPath(reference)
        case (nil, let id?):
            return .id(id)
        case (nil, nil):
            throw CLIError.usage("'\(command)' needs a profile name, group/profile path, or --id")
        case (.some, .some):
            throw CLIError.usage("give a profile name or --id, not both")
        }
    }

    // MARK: - Cross-process change notification (ADR-0010 ③)

    /// Tells a running GUI that this process changed the workspace on disk. Display-refresh
    /// optimization only: delivery is not guaranteed and correctness never depends on it.
    static func postDistributedWorkspaceChange(for workspace: Workspace) {
        DistributedNotificationCenter.default().postNotificationName(
            Workspace.changeNotification,
            object: workspace.changeNotificationObject,
            userInfo: nil,
            deliverImmediately: true
        )
    }

    // MARK: - Error rendering

    /// Internal rather than private: refresh (#73) reports write-layer failures through the
    /// same mapping in its result instead of failing the whole command.
    static func normalize(_ error: any Error) -> CLIError {
        switch error {
        case let error as CLIError:
            return error
        case ProfileResolver.Failure.notFound(let reference):
            return CLIError(
                code: "profile-not-found",
                message: "no profile matches '\(reference)'",
                exitCode: .notFound
            )
        case ProfileResolver.Failure.idPassedAsName(let reference):
            return CLIError(
                code: "profile-not-found",
                message: "'\(reference)' is a profile ID, not a profile name; use --id \(reference)",
                exitCode: .notFound
            )
        case ProfileResolver.Failure.ambiguous(let reference, let candidates):
            return CLIError(
                code: "profile-ambiguous",
                message: "'\(reference)' matches multiple profiles; disambiguate with a group/profile path or --id",
                exitCode: .ambiguous,
                candidates: candidates
            )
        case WorkspaceError.notInitialized:
            return CLIError(
                code: "workspace-not-initialized",
                message: "workspace not initialized; launch the Hostflip app once to capture the system hosts",
                exitCode: .failure
            )
        case let error as DaemonChannelError:
            return normalize(error)
        case let error as ConfirmedWriteBaselineError:
            // The write itself landed: the message must say so, or the caller would undo or
            // retry a change that is already live.
            return CLIError(
                code: "baseline-record-failed",
                message: "the system hosts was updated, but the write baseline could not be recorded: \(String(describing: error.underlying)); 'hostflip status' may report drift until the next successful write",
                exitCode: .failure
            )
        default:
            return CLIError(code: "internal-error", message: error.localizedDescription, exitCode: .failure)
        }
    }

    /// Maps a daemon channel failure onto the exit-code contract: drift means "stop and hand
    /// back to a human" (3), an unreachable or restarting daemon is "not ready" (4), everything
    /// else is a general failure with a string code integrations can key on. Internal rather
    /// than private: refresh (#73) reports a blocked write through this mapping in its result
    /// instead of failing the whole command.
    static func normalize(_ error: DaemonChannelError) -> CLIError {
        switch error {
        case .mergeRejected(.hostsDrift):
            return .hostsDrift
        case .unavailable:
            return CLIError(
                code: "daemon-unavailable",
                message: "the privileged daemon is not available; launch the Hostflip app and perform a switch once to install and approve it",
                exitCode: .daemonUnavailable
            )
        case .interrupted:
            return CLIError(
                code: "daemon-unavailable",
                message: "the privileged daemon was interrupted twice in a row; try again, or relaunch the Hostflip app",
                exitCode: .daemonUnavailable
            )
        case .peerRejected:
            return CLIError(
                code: "daemon-unavailable",
                message: "the daemon's code signature was rejected; reinstall the Hostflip app",
                exitCode: .daemonUnavailable
            )
        case .selfSigningUnavailable:
            return CLIError(
                code: "unsigned-build",
                message: "this hostflip binary is unsigned, so it cannot connect to the daemon; use a signed build",
                exitCode: .failure
            )
        case .protocolViolation, .mergeRejected(.versionMismatch):
            return CLIError(
                code: "version-mismatch",
                message: "the daemon and this hostflip binary are from different versions; finish the upgrade by relaunching the Hostflip app",
                exitCode: .failure
            )
        case .mergeRejected(let reason):
            return CLIError(
                code: "merge-rejected",
                message: "the daemon rejected the merge: \(reason)",
                exitCode: .failure
            )
        case .mergeWriteFailed(let failure):
            return CLIError(
                code: "hosts-write-failed",
                message: "the daemon could not write the system hosts (stage \(failure.stage.rawValue)): \(failure.message)",
                exitCode: .failure
            )
        case .transport(let domain, let code):
            return CLIError(
                code: "transport-error",
                message: "the daemon channel failed (\(domain) \(code)); try again",
                exitCode: .failure
            )
        }
    }

    private static func render(_ error: CLIError, asJSON: Bool) -> String {
        if asJSON {
            return CLIJSON.encode(ErrorEnvelope(error: .init(
                code: error.code,
                message: error.message,
                candidates: error.candidates
            )))
        }
        var text = "hostflip: \(error.message)"
        if let candidates = error.candidates {
            text += ":\n" + CLIColumns.render(candidates.map { ("  " + $0.reference, $0.id) })
        }
        if error.exitCode == .usage {
            text += "\nRun 'hostflip --help' for usage."
        }
        return text
    }
}
