import ServiceManagement

/// The daemon's SMAppService registration status, queried from the app side.
/// Read-only — registering and guiding approval are the scope of #19.
public enum DaemonRegistrationStatus: String, Sendable {
    case notRegistered
    case enabled
    case requiresApproval
    case notFound

    public init(_ status: SMAppService.Status) {
        switch status {
        case .notRegistered: self = .notRegistered
        case .enabled: self = .enabled
        case .requiresApproval: self = .requiresApproval
        case .notFound: self = .notFound
        @unknown default: self = .notFound // Conservatively treat as unavailable; guide the user to reinstall or re-approve
        }
    }

    /// Queries the embedded daemon's current registration status.
    public static func current() -> DaemonRegistrationStatus {
        DaemonRegistrationStatus(SMAppService.daemon(plistName: ChannelIdentity.daemonPlistName).status)
    }
}
