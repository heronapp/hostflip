import Foundation
import HostflipCore

/// Entry point of the standalone `hostflip` CLI (ADR-0009): argv/exit glue only, so every
/// command and its output contract stay testable through CLI.run.
@main
enum CLIMain {
    static func main() async {
        let result = await CLI.run(
            arguments: Array(CommandLine.arguments.dropFirst()),
            workspaceRootDirectory: Workspace.defaultRootDirectory,
            systemHostsURL: URL(fileURLWithPath: "/etc/hosts")
        )
        if !result.standardOutput.isEmpty {
            FileHandle.standardOutput.write(Data(result.standardOutput.utf8))
        }
        if !result.standardError.isEmpty {
            FileHandle.standardError.write(Data(result.standardError.utf8))
        }
        exit(result.exitCode.rawValue)
    }
}
