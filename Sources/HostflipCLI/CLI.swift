import Foundation
import HostflipCore
import HostflipXPC

/// Parses one invocation and dispatches to the command implementations. Help and documentation
/// show canonical verbs only; any future aliases stay out of both.
enum CLI {
    static let usageText = """
        Usage: hostflip [--json] <command> [<profile>]

        Commands:
          status      Report the pause state, active profiles, and system hosts drift
          list        List the group structure and every profile with its ID
          cat         Print a profile's content exactly as stored
          activate    Activate a profile and rewrite the system hosts via the daemon
          deactivate  Deactivate a profile and rewrite the system hosts via the daemon
          pause       Rewrite the system hosts with Base Hosts only, keeping active state
          resume      Rewrite the system hosts with the kept active profiles restored

        Profiles are addressed by name, by group/profile path, or by --id when the
        name is ambiguous (names are not unique; IDs are — see 'hostflip list').

        Options:
          --id <id>  Address a profile by its unique ID
          --json     Machine-readable output: result object on stdout, JSON errors on stderr
          --help     Show this help
        """

    static func run(
        arguments: [String],
        workspaceRootDirectory: URL,
        systemHostsURL: URL,
        makeHostsMerger: @Sendable (Workspace) -> any HostsMerging = { DaemonHostsMerger(workspace: $0) },
        postWorkspaceChanged: @escaping @Sendable (Workspace) -> Void = CLI.postDistributedWorkspaceChange
    ) async -> CLIResult {
        // The output mode is decided by scanning the whole argv, not during parsing, so even a
        // usage error earlier in the argument list is rendered in the requested format.
        let wantsJSON = arguments.contains("--json")
        do {
            let invocation = try parse(arguments)
            if invocation.wantsHelp {
                return CLIResult(exitCode: .success, standardOutput: usageText + "\n", standardError: "")
            }
            let payload = try await dispatch(
                invocation,
                workspace: Workspace(rootDirectory: workspaceRootDirectory),
                systemHostsURL: systemHostsURL,
                makeHostsMerger: makeHostsMerger,
                postWorkspaceChanged: postWorkspaceChanged
            )
            let output: String
            if wantsJSON {
                output = CLIJSON.encode(payload) + "\n"
            } else if payload.humanTextIsVerbatim {
                output = payload.humanText
            } else {
                output = payload.humanText + "\n"
            }
            return CLIResult(exitCode: .success, standardOutput: output, standardError: "")
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
        var profileID: String?
        var commandArguments: [String] = []
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
            case "--id":
                guard let value = iterator.next() else {
                    throw CLIError.usage("option '--id' requires a value")
                }
                invocation.profileID = value
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
        postWorkspaceChanged: @escaping @Sendable (Workspace) -> Void
    ) async throws -> any CommandPayload {
        guard let command = invocation.commandArguments.first else {
            throw CLIError.usage("no command given")
        }
        switch command {
        case "status":
            try requireNoArguments(in: invocation)
            return try StatusCommand.run(workspace: workspace, systemHostsURL: systemHostsURL)
        case "list":
            try requireNoArguments(in: invocation)
            return try ListCommand.run(workspace: workspace)
        case "cat":
            return try CatCommand.run(
                reference: requireProfileReference(in: invocation, command: command),
                workspace: workspace
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

    private static func normalize(_ error: any Error) -> CLIError {
        switch error {
        case let error as CLIError:
            return error
        case ProfileResolver.Failure.notFound(let reference):
            return CLIError(
                code: "profile-not-found",
                message: "no profile matches '\(reference)'",
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
        default:
            return CLIError(code: "internal-error", message: error.localizedDescription, exitCode: .failure)
        }
    }

    /// Maps a daemon channel failure onto the exit-code contract: drift means "stop and hand
    /// back to a human" (3), an unreachable or restarting daemon is "not ready" (4), everything
    /// else is a general failure with a string code integrations can key on.
    private static func normalize(_ error: DaemonChannelError) -> CLIError {
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
