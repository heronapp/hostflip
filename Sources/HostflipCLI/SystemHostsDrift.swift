import Foundation
import HostflipCore

/// The shared drift primitive: compares the actual system hosts bytes against the workspace's
/// expected hash — the same baseline as the app's monitor: the last confirmed merge write, or
/// the pristine first-capture backup before any write. `status` reports the verdict; the switch
/// commands gate on it.
enum SystemHostsDrift {
    struct Observation {
        let drifted: Bool
        /// The system hosts bytes decoded as UTF-8 (lossily), for content-level reporting;
        /// the verdict itself is computed over the raw bytes.
        let actualContent: String
    }

    static func detect(workspace: Workspace, systemHostsURL: URL) throws -> Bool {
        try observe(workspace: workspace, systemHostsURL: systemHostsURL).drifted
    }

    static func observe(workspace: Workspace, systemHostsURL: URL) throws -> Observation {
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
        return Observation(
            drifted: try MergedHosts.hash(of: actualData) != workspace.expectedSystemHostsHash(),
            actualContent: String(decoding: actualData, as: UTF8.self)
        )
    }
}
