import Foundation
import HostflipCore

/// `hostflip cat <profile>`: prints a profile's content to stdout exactly as stored on disk.
/// The JSON payload also names the resolved profile so scripts can confirm which one matched.
enum CatCommand {
    struct Payload: CommandPayload {
        let id: String
        let name: String
        /// The containing group's name; absent for a standalone profile.
        let group: String?
        let content: String

        var humanText: String { content }
        var humanTextIsVerbatim: Bool { true }
    }

    static func run(reference: ProfileReference, workspace: Workspace) throws -> Payload {
        let model = try workspace.openReadOnly()
        let match = try ProfileResolver.resolve(reference, in: model)
        return Payload(
            id: match.profile.id.rawValue,
            name: match.profile.name,
            group: match.groupName,
            content: match.profile.content
        )
    }
}
