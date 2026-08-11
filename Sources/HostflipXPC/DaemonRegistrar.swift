import Foundation

/// The helper's readiness verdict for one switch attempt.
public enum DaemonReadiness: String, Equatable, Sendable {
    /// Approved; merges may proceed.
    case ready
    /// Registration submitted, awaiting user approval in System Settings; switching is blocked and the UI shows an explanation plus a shortcut into Settings.
    case needsApproval
    /// Still unavailable after registering (app in an unexpected location, blocked by management policy, etc.); switching is blocked and the user is guided to reinstall.
    case unavailable
}

/// SMAppService registration state machine (#19): authorization is lazily triggered —
/// only an actual switch registers; creating profiles or editing content never comes
/// through here. While unapproved it blocks switching and guides the user to approve,
/// with no osascript fallback.
public actor DaemonRegistrar {
    private let manager: any DaemonServiceManaging
    private let currentBuildVersion: String
    private let recordedVersion: @Sendable () -> String?
    private let recordVersion: @Sendable (String?) -> Void
    private let wait: @Sendable (Duration) async -> Void

    /// Injection seams: manager stands in for SMAppService, the version closures
    /// replace UserDefaults, and wait lets tests skip the real backoff.
    init(
        manager: any DaemonServiceManaging,
        currentBuildVersion: String,
        recordedVersion: @escaping @Sendable () -> String?,
        recordVersion: @escaping @Sendable (String?) -> Void,
        wait: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) }
    ) {
        self.manager = manager
        self.currentBuildVersion = currentBuildVersion
        self.recordedVersion = recordedVersion
        self.recordVersion = recordVersion
        self.wait = wait
    }

    /// Production initializer: real SMAppService, with the registered version recorded
    /// in UserDefaults. CFBundleVersion is unreadable when running as a bare binary
    /// (not an .app bundle) and is recorded as "0".
    public init() {
        let key = "helperRegisteredBuildVersion"
        self.init(
            manager: SMAppServiceDaemonManager(),
            currentBuildVersion: Bundle.main
                .object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0",
            recordedVersion: { UserDefaults.standard.string(forKey: key) },
            recordVersion: { version in
                if let version {
                    UserDefaults.standard.set(version, forKey: key)
                } else {
                    UserDefaults.standard.removeObject(forKey: key)
                }
            }
        )
    }

    /// The single entry point before a switch: enabled passes straight through; if not
    /// registered, register on the spot (lazy trigger). The verdict follows the actual
    /// post-registration status — SMAppService's register() throws while approval is
    /// pending, but the registration request has taken effect and the system has
    /// notified the user, so the throw itself is not a failure.
    public func ensureReadyForSwitch() async -> DaemonReadiness {
        switch manager.status() {
        case .enabled:
            return .ready
        case .requiresApproval:
            // Already awaiting approval; registering again would only nag the user
            return .needsApproval
        case .notRegistered, .notFound:
            await registerAwaitingSettlement()
            switch manager.status() {
            case .enabled:
                recordVersion(currentBuildVersion)
                return .ready
            case .requiresApproval:
                recordVersion(currentBuildVersion)
                return .needsApproval
            case .notRegistered, .notFound:
                return .unavailable
            }
        }
    }

    /// Launch-time self-healing: re-checks the actual registration status; a registered
    /// helper (including approval-pending) gets unregister + register when the app
    /// build number changes, so launchd picks up the new content. Unregistered helpers
    /// stay lazily triggered — launch never registers. Pre-existing registrations with
    /// no recorded version adopt the current build number.
    public func healOnLaunch() async -> DaemonRegistrationStatus {
        let status = manager.status()
        switch status {
        case .enabled, .requiresApproval:
            guard let recorded = recordedVersion() else {
                recordVersion(currentBuildVersion)
                return status
            }
            guard recorded != currentBuildVersion else { return status }
            do {
                try await manager.unregister()
            } catch {
                // Unregister failed: the helper is still on the old registration.
                // Recording the new version now would misreport the migration as
                // complete (and lazy registration never fires again while enabled),
                // so leave it for a retry on the next launch
                return manager.status()
            }
            await registerAwaitingSettlement()
            // Unregistration has taken effect, so record the version once and for all:
            // even if register retries are exhausted, the next launch does not replay
            // this fragile sequence; both registration and the version record converge
            // via lazy registration
            recordVersion(currentBuildVersion)
            return manager.status()
        case .notRegistered, .notFound:
            return status
        }
    }

    /// Registers until the status settles (enabled / requiresApproval) or the backoff
    /// is exhausted. An unregister takes about 0.5–4 seconds to settle on the BTM side,
    /// during which every register is rejected (measured in
    /// docs/helper-reregistration-verification.md); 500ms × 12 covers that settling
    /// window, and a genuinely unavailable install gets guidance from the caller after
    /// exhaustion.
    private func registerAwaitingSettlement() async {
        for attempt in 0 ..< 12 {
            if attempt > 0 { await wait(.milliseconds(500)) }
            try? manager.register()
            let settled = manager.status()
            if settled == .enabled || settled == .requiresApproval { return }
        }
    }

    /// Re-checks the actual registration status; after an XPC error the caller uses this to pick a guidance path.
    public func refreshStatus() -> DaemonRegistrationStatus {
        manager.status()
    }

    /// "Disable and remove helper": unregisters and clears the version record; the next switch goes through lazy registration again.
    public func unregister() async throws {
        try await manager.unregister()
        recordVersion(nil)
    }

    /// Opens the Login Items pane in System Settings, used by the approval guidance.
    public nonisolated func openApprovalSettings() {
        manager.openApprovalSettings()
    }
}
