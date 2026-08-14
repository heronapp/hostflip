import Foundation
import HostflipCore

/// `hostflip list`: the group structure and every profile in manifest order, each with its
/// globally unique ID — the stable handle for the future `--id` addressing (names are not
/// unique in any scope).
enum ListCommand {
    struct Payload: CommandPayload {
        struct ProfileEntry: Encodable {
            let id: String
            let name: String
        }

        struct GroupEntry: Encodable {
            let id: String
            let name: String
            let profiles: [ProfileEntry]
        }

        let standaloneProfiles: [ProfileEntry]
        let groups: [GroupEntry]

        var humanText: String {
            var rows: [(label: String, trailing: String)] = []
            for profile in standaloneProfiles {
                rows.append((profile.name, profile.id))
            }
            for group in groups {
                rows.append(("\(group.name)/", group.id))
                for profile in group.profiles {
                    rows.append(("  \(profile.name)", profile.id))
                }
            }
            guard !rows.isEmpty else { return "No profiles." }
            return CLIColumns.render(rows)
        }
    }

    static func run(workspace: Workspace) throws -> Payload {
        let model = try workspace.openReadOnly()
        return Payload(
            standaloneProfiles: model.standaloneProfiles.map { .init(id: $0.id.rawValue, name: $0.name) },
            groups: model.groups.map { group in
                .init(
                    id: group.id.rawValue,
                    name: group.name,
                    profiles: group.profiles.map { .init(id: $0.id.rawValue, name: $0.name) }
                )
            }
        )
    }
}
