import ServiceManagement

/// Injection seam for SMAppService operations: DaemonRegistrar implements its state
/// machine against this protocol, and tests inject a scriptable fake (real
/// registration can only be verified on a signed, installed app).
public protocol DaemonServiceManaging: Sendable {
    func status() -> DaemonRegistrationStatus
    func register() throws
    func unregister() async throws
    /// Opens the Login Items pane in System Settings for the user to approve the helper.
    func openApprovalSettings()
}

/// Production implementation: wraps SMAppService for the daemon embedded in the app.
public struct SMAppServiceDaemonManager: DaemonServiceManaging {
    public init() {}

    private var service: SMAppService {
        SMAppService.daemon(plistName: ChannelIdentity.daemonPlistName)
    }

    public func status() -> DaemonRegistrationStatus {
        DaemonRegistrationStatus(service.status)
    }

    public func register() throws {
        try service.register()
    }

    public func unregister() async throws {
        try await service.unregister()
    }

    public func openApprovalSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
