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
            /// Present only for Remote Profiles; omitted from the JSON otherwise.
            let remote: RemoteMetadata?
        }

        struct GroupEntry: Encodable {
            let id: String
            let name: String
            let profiles: [ProfileEntry]
        }

        let standaloneProfiles: [ProfileEntry]
        let groups: [GroupEntry]

        var humanText: String {
            // Remote metadata rides behind the ID column: IDs are UUIDs of equal width in
            // practice, and scripts read --json, so the annotation is not itself aligned.
            func trailing(for profile: ProfileEntry) -> String {
                guard let remote = profile.remote else { return profile.id }
                return "\(profile.id)  [remote: \(remote.url), \(remote.interval)]"
            }
            var rows: [(label: String, trailing: String)] = []
            for profile in standaloneProfiles {
                rows.append((profile.name, trailing(for: profile)))
            }
            for group in groups {
                rows.append(("\(group.name)/", group.id))
                for profile in group.profiles {
                    rows.append(("  \(profile.name)", trailing(for: profile)))
                }
            }
            guard !rows.isEmpty else { return "No profiles." }
            return CLIColumns.render(rows)
        }
    }

    static func run(workspace: Workspace) throws -> Payload {
        let model = try workspace.openReadOnly()
        func entry(for profile: Profile) -> Payload.ProfileEntry {
            .init(id: profile.id.rawValue, name: profile.name, remote: RemoteMetadata(of: profile))
        }
        return Payload(
            standaloneProfiles: model.standaloneProfiles.map(entry),
            groups: model.groups.map { group in
                .init(
                    id: group.id.rawValue,
                    name: group.name,
                    profiles: group.profiles.map(entry)
                )
            }
        )
    }
}
