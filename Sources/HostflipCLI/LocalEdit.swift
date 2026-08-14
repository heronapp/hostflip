import Foundation
import HostflipCore

/// The commit path of a content change that stays outside the merged system hosts output
/// (write or delete on an inactive profile): a reload-and-replay save under the manifest
/// lock (ADR-0010 ②), with a replay conflict (a peer writer removed the target mid-flight)
/// reported instead of silently dropped.
enum LocalEdit {
    static func persist(
        _ change: (inout ActivationModel) throws -> Void,
        to workspace: Workspace
    ) throws {
        guard case .saved = try workspace.save(applying: change) else {
            throw CLIError(
                code: "state-save-conflict",
                message: "a peer writer changed the workspace so the change could not be saved; check 'hostflip status' and retry",
                exitCode: .failure
            )
        }
    }
}
