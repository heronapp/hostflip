import Foundation
import HostflipCore

/// `hostflip create <name>` / `hostflip create <group>/<name>`: adds an inactive profile, so the
/// system hosts is never touched and no drift gate applies. The CLI does not manage groups: a
/// path pointing at a group that does not exist is an error, never an implicit group creation.
/// A namesake in the same location (the standalone area, or the same group) is rejected — a
/// retried create must fail instead of piling ambiguous namesakes into the addressing space.
enum CreateCommand {
    struct Payload: CommandPayload {
        let id: String
        let name: String
        /// The containing group's name; absent for a standalone profile.
        let group: String?

        var humanText: String {
            "Created \(group.map { "\($0)/\(name)" } ?? name)."
        }
    }

    static func run(
        target: String,
        workspace: Workspace,
        postWorkspaceChanged: @Sendable (Workspace) -> Void
    ) throws -> Payload {
        // The same first-slash path rule the resolver applies to profile references. Either
        // half coming out empty is a malformed target, not a lookup miss.
        let groupName: String?
        let profileName: String
        if let path = ProfileResolver.splitPath(target) {
            groupName = path.group
            profileName = path.name
            guard !path.group.isEmpty else {
                throw CLIError.usage("the group name is empty")
            }
        } else {
            groupName = nil
            profileName = target
        }
        guard !profileName.isEmpty else {
            throw CLIError.usage("the profile name is empty")
        }

        let profileID = Profile.ID(UUID().uuidString)
        // Location resolution and the duplicate check run inside the replayed change, i.e. on
        // the latest on-disk state under the manifest lock: a namesake a peer writer just
        // created cannot slip past the check.
        switch try workspace.save(applying: { model in
            try add(profileName, id: profileID, toGroupNamed: groupName, in: &model)
        }) {
        case .saved:
            postWorkspaceChanged(workspace)
            return Payload(id: profileID.rawValue, name: profileName, group: groupName)
        case .conflict(_, let reason):
            throw reason
        }
    }

    /// A new profile starts empty: the CLI's consumers are scripts and agents, so no editor
    /// placeholder comment is injected (unlike the GUI's create).
    private static func add(
        _ name: String,
        id: Profile.ID,
        toGroupNamed groupName: String?,
        in model: inout ActivationModel
    ) throws {
        guard let groupName else {
            guard !model.standaloneProfiles.contains(where: { $0.name == name }) else {
                throw CLIError(
                    code: "profile-exists",
                    message: "a standalone profile named '\(name)' already exists",
                    exitCode: .failure
                )
            }
            try model.addProfile(id: id, name: name, content: "")
            return
        }
        let candidates = model.groups.filter { $0.name == groupName }
        guard let group = candidates.first else {
            throw CLIError(
                code: "group-not-found",
                message: "no group matches '\(groupName)'; the CLI does not create groups — create it in the Hostflip app first",
                exitCode: .notFound
            )
        }
        guard candidates.count == 1 else {
            throw CLIError(
                code: "group-ambiguous",
                message: "'\(groupName)' matches multiple groups; rename them apart in the Hostflip app",
                exitCode: .ambiguous
            )
        }
        guard !group.profiles.contains(where: { $0.name == name }) else {
            throw CLIError(
                code: "profile-exists",
                message: "'\(groupName)' already has a profile named '\(name)'",
                exitCode: .failure
            )
        }
        try model.addProfile(id: id, name: name, content: "")
        try model.moveProfile(id, toGroup: group.id)
    }
}
