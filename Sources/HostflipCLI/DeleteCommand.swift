import Foundation
import HostflipCore

/// `hostflip delete <profile>`: removes a profile from the workspace. Deleting an active
/// profile mirrors the GUI — it is also an active-state change, so the merge without the
/// profile must land before the profile is removed (drift gate included); an inactive profile
/// is a purely local edit that never goes through the daemon.
enum DeleteCommand {
    struct Payload: CommandPayload {
        let id: String
        let name: String
        /// The containing group's name; absent for a standalone profile.
        let group: String?

        var humanText: String {
            "Deleted \(group.map { "\($0)/\(name)" } ?? name)."
        }
    }

    static func run(
        reference: ProfileReference,
        workspace: Workspace,
        systemHostsURL: URL,
        merger: any HostsMerging,
        postWorkspaceChanged: @Sendable (Workspace) -> Void
    ) async throws -> Payload {
        let model = try workspace.openReadOnly()
        let match = try ProfileResolver.resolve(reference, in: model)
        let profileID = match.profile.id
        let payload = Payload(id: profileID.rawValue, name: match.profile.name, group: match.groupName)

        if model.activeProfileIDs.contains(profileID) {
            try MergeCommitFlow.requireNoDrift(workspace: workspace, systemHostsURL: systemHostsURL)
            try await MergeCommitFlow.run(
                change: { try $0.deleteProfile(profileID) },
                on: model,
                workspace: workspace,
                systemHostsURL: systemHostsURL,
                merger: merger,
                postWorkspaceChanged: postWorkspaceChanged
            )
            return payload
        }

        try LocalEdit.persist({ try $0.deleteProfile(profileID) }, to: workspace)
        postWorkspaceChanged(workspace)
        return payload
    }
}
