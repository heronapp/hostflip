import Foundation
import HostflipCore

/// The shared drift primitive: compares the actual system hosts bytes against the workspace's
/// expected hash — the same baseline as the app's monitor: the last confirmed merge write, or
/// the pristine first-capture backup before any write. `status` reports the verdict; the switch
/// commands gate on it.
enum SystemHostsDrift {
    static func detect(workspace: Workspace, systemHostsURL: URL) throws -> Bool {
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
        return try MergedHosts.hash(of: actualData) != workspace.expectedSystemHostsHash()
    }
}
