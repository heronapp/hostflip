import Foundation
import HostflipCore

/// `hostflip write <profile>`: replaces a profile's content whole, from stdin or `--file`.
/// A Remote Profile is refused outright — remote content is read-only everywhere (ADR-0012),
/// and a write could silently strip the Remote Header, which only Convert to Local may do.
/// The new content must pass the structural hosts validation before anything happens; a
/// rejected write leaves the stored content untouched. Writing an active profile changes the
/// merged system hosts output, so it takes the shared daemon path (drift gate, merge, then
/// commit); an inactive profile is a purely local edit that never gates on drift and never
/// touches the daemon — mirroring the GUI's edit-versus-switch split.
enum WriteCommand {
    struct Payload: CommandPayload {
        let id: String
        let name: String
        /// The containing group's name; absent for a standalone profile.
        let group: String?
        /// False when the profile already had exactly this content and nothing was written.
        let changed: Bool

        var humanText: String {
            let reference = group.map { "\($0)/\(name)" } ?? name
            return changed ? "Wrote \(reference)." : "\(reference) already has this content."
        }
    }

    static func run(
        reference: ProfileReference,
        filePath: String?,
        readStandardInput: @Sendable () throws -> Data,
        workspace: Workspace,
        systemHostsURL: URL,
        merger: any HostsMerging,
        postWorkspaceChanged: @Sendable (Workspace) -> Void
    ) async throws -> Payload {
        let model = try workspace.openReadOnly()
        let match = try ProfileResolver.resolve(reference, in: model)
        let profileID = match.profile.id
        // Checked before the content is even read: a remote target is invalid no matter what
        // would be written.
        if match.profile.isRemote {
            let reference = match.groupName.map { "\($0)/\(match.profile.name)" } ?? match.profile.name
            throw CLIError(
                code: "profile-is-remote",
                message: "'\(reference)' is a remote profile; its content is read-only and comes from its source URL",
                exitCode: .failure
            )
        }
        let content = try readContent(filePath: filePath, readStandardInput: readStandardInput)
        if let line = HostsSyntax.firstIncompleteLine(in: content) {
            throw CLIError(
                code: "invalid-hosts-syntax",
                message: "invalid hosts content: line \(line) has a single field; every entry needs an IP address and at least one hostname",
                exitCode: .failure
            )
        }

        func payload(changed: Bool) -> Payload {
            Payload(id: profileID.rawValue, name: match.profile.name, group: match.groupName, changed: changed)
        }

        if model.activeProfileIDs.contains(profileID) {
            // Same discipline as the switch commands: the drift gate runs before the idempotent
            // no-op check, because writing an active profile vouches for the hosts content.
            try MergeCommitFlow.requireNoDrift(workspace: workspace, systemHostsURL: systemHostsURL)
            guard match.profile.content != content else {
                return payload(changed: false)
            }
            try await MergeCommitFlow.run(
                change: { try $0.updateProfileContent(profileID, content: content) },
                on: model,
                workspace: workspace,
                systemHostsURL: systemHostsURL,
                merger: merger,
                postWorkspaceChanged: postWorkspaceChanged
            )
            return payload(changed: true)
        }

        guard match.profile.content != content else {
            return payload(changed: false)
        }
        try LocalEdit.persist(
            { try $0.updateProfileContent(profileID, content: content) },
            to: workspace
        )
        postWorkspaceChanged(workspace)
        return payload(changed: true)
    }

    private static func readContent(
        filePath: String?,
        readStandardInput: () throws -> Data
    ) throws -> String {
        let data: Data
        if let filePath {
            do {
                data = try Data(contentsOf: URL(fileURLWithPath: filePath))
            } catch {
                throw CLIError(
                    code: "file-unreadable",
                    message: "cannot read \(filePath): \(error.localizedDescription)",
                    exitCode: .failure
                )
            }
        } else {
            data = try readStandardInput()
        }
        guard let content = String(data: data, encoding: .utf8) else {
            throw CLIError(
                code: "invalid-encoding",
                message: "the new content is not valid UTF-8 text",
                exitCode: .failure
            )
        }
        return content
    }
}
