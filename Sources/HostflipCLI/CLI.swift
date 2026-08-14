import Foundation
import HostflipCore

/// Parses one invocation and dispatches to the command implementations. Help and documentation
/// show canonical verbs only; any future aliases stay out of both.
enum CLI {
    static let usageText = """
        Usage: hostflip [--json] <command>

        Commands:
          status  Report the pause state, active profiles, and system hosts drift
          list    List the group structure and every profile with its ID

        Options:
          --json  Machine-readable output: result object on stdout, JSON errors on stderr
          --help  Show this help
        """

    static func run(
        arguments: [String],
        workspaceRootDirectory: URL,
        systemHostsURL: URL
    ) -> CLIResult {
        // The output mode is decided by scanning the whole argv, not during parsing, so even a
        // usage error earlier in the argument list is rendered in the requested format.
        let wantsJSON = arguments.contains("--json")
        do {
            let invocation = try parse(arguments)
            if invocation.wantsHelp {
                return CLIResult(exitCode: .success, standardOutput: usageText + "\n", standardError: "")
            }
            let payload = try dispatch(
                invocation,
                workspace: Workspace(rootDirectory: workspaceRootDirectory),
                systemHostsURL: systemHostsURL
            )
            let output = wantsJSON ? CLIJSON.encode(payload) : payload.humanText
            return CLIResult(exitCode: .success, standardOutput: output + "\n", standardError: "")
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
        var commandArguments: [String] = []
    }

    private static func parse(_ arguments: [String]) throws -> Invocation {
        var invocation = Invocation()
        for argument in arguments {
            switch argument {
            case "--json":
                break // Handled by the argv scan in run.
            case "--help", "-h":
                invocation.wantsHelp = true
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
        systemHostsURL: URL
    ) throws -> any CommandPayload {
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
        default:
            throw CLIError.usage("unknown command '\(command)'")
        }
    }

    private static func requireNoArguments(in invocation: Invocation) throws {
        if let extra = invocation.commandArguments.dropFirst().first {
            throw CLIError.usage("unexpected argument '\(extra)'")
        }
    }

    // MARK: - Error rendering

    private static func normalize(_ error: any Error) -> CLIError {
        switch error {
        case let error as CLIError:
            return error
        case WorkspaceError.notInitialized:
            return CLIError(
                code: "workspace-not-initialized",
                message: "workspace not initialized; launch the Hostflip app once to capture the system hosts",
                exitCode: .failure
            )
        default:
            return CLIError(code: "internal-error", message: error.localizedDescription, exitCode: .failure)
        }
    }

    private static func render(_ error: CLIError, asJSON: Bool) -> String {
        if asJSON {
            return CLIJSON.encode(ErrorEnvelope(error: .init(code: error.code, message: error.message)))
        }
        var text = "hostflip: \(error.message)"
        if error.exitCode == .usage {
            text += "\nRun 'hostflip --help' for usage."
        }
        return text
    }
}
