import Foundation
import HostflipXPC

extension DaemonChannelError {
    /// The detail shown after "Failed to update the system hosts file:" and its
    /// reconciliation twin. `String(describing:)` would surface the bare case name
    /// ("unavailable"), which tells the user neither what happened nor what to do.
    var userMessage: String {
        switch self {
        case .unavailable:
            String(localized: "The helper could not be reached. Quit and reopen hostflip; if it keeps failing, remove the helper in Settings > Helper, then switch again.")
        case .interrupted:
            String(localized: "The helper was interrupted. Try again.")
        case .peerRejected:
            String(localized: "The helper’s code signature was rejected. Reinstall hostflip.")
        case .selfSigningUnavailable:
            String(localized: "This build of hostflip is not properly signed, so it cannot connect to the helper.")
        case .protocolViolation(.undecodablePayload):
            String(localized: "The helper returned an unreadable response. Quit and reopen hostflip, then try again.")
        case .protocolViolation(.versionMismatch), .mergeRejected(.versionMismatch):
            String(localized: "The helper is from a different version of hostflip. Quit and reopen hostflip to finish the update.")
        case .mergeRejected(let reason):
            String(localized: "The helper rejected the request (\(String(describing: reason))).")
        case .mergeWriteFailed(let failure):
            String(localized: "The helper could not write the file (\(failure.stage.rawValue)): \(failure.message)")
        case .transport(let domain, let code):
            String(localized: "The connection to the helper failed (\(domain) \(code)). Try again.")
        }
    }
}
