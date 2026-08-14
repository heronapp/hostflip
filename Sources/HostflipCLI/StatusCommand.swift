import Foundation
import HostflipCore

/// `hostflip status`: reports the pause state, the active profiles (preserved even while paused),
/// and whether the system hosts drifted. Drift uses the same baseline as the app's monitor: the
/// workspace's expected hash (last confirmed merge write, or the pristine first-capture backup
/// before any write) against the hash of the actual system hosts bytes. The CLI only reports
/// drift, it never reconciles.
enum StatusCommand {
    struct Payload: CommandPayload {
        struct ActiveProfile: Encodable {
            let id: String
            let name: String
            /// The containing group's name; absent for a standalone profile.
            let group: String?
        }

        let paused: Bool
        let active: [ActiveProfile]
        let drift: Bool

        var humanText: String {
            let references = active.map { profile in
                profile.group.map { "\($0)/\(profile.name)" } ?? profile.name
            }
            return """
                Status: \(paused ? "paused" : "running")
                Active: \(references.isEmpty ? "none" : references.joined(separator: ", "))
                Drift:  \(drift ? "detected (reconcile in the Hostflip app)" : "none")
                """
        }
    }

    static func run(workspace: Workspace, systemHostsURL: URL) throws -> Payload {
        let model = try workspace.openReadOnly()

        var active: [Payload.ActiveProfile] = []
        for profile in model.standaloneProfiles where model.activeProfileIDs.contains(profile.id) {
            active.append(.init(id: profile.id.rawValue, name: profile.name, group: nil))
        }
        for group in model.groups {
            for profile in group.profiles where model.activeProfileIDs.contains(profile.id) {
                active.append(.init(id: profile.id.rawValue, name: profile.name, group: group.name))
            }
        }

        let expectedHash = try workspace.expectedSystemHostsHash()
        let actualData: Data
        do {
            actualData = try Data(contentsOf: systemHostsURL)
        } catch {
            throw CLIError(
                code: "hosts-unreadable",
                message: "cannot read \(systemHostsURL.path): \(error.localizedDescription)",
                exitCode: .failure
            )
        }
        return Payload(
            paused: model.isPaused,
            active: active,
            drift: MergedHosts.hash(of: actualData) != expectedHash
        )
    }
}
