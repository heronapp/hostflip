import AppKit
import Foundation
import HostflipCore

extension DiagnosticSnapshot {
    /// The live snapshot from state the app already holds — read-only, no workspace access,
    /// and usable while the helper is unapproved or the app is paused (#90).
    @MainActor
    static func current(store: WorkspaceStore, maintenanceStore: MaintenanceStore, now: Date = .now) -> DiagnosticSnapshot {
        let info = Bundle.main.infoDictionary ?? [:]
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let profiles = store.standaloneProfiles + store.groups.flatMap(\.profiles)
        return DiagnosticSnapshot(
            appVersion: info["CFBundleShortVersionString"] as? String ?? "unknown",
            build: info["CFBundleVersion"] as? String ?? "unknown",
            macOSVersion: "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)",
            architecture: architecture,
            installSource: installSource(bundleURL: Bundle.main.bundleURL),
            helperStatus: maintenanceStore.helperStatus,
            isPaused: store.isPaused,
            hasHostsDrift: store.hasHostsDrift,
            groupCount: store.groups.count,
            profileCount: profiles.count,
            activeProfileCount: profiles.filter { store.isActive($0.id) }.count,
            remoteFreshness: store.remoteProfiles.map { profile in
                RemoteFreshness(
                    lastSuccessAge: profile.remoteRefreshState?.lastSuccessAt.map { now.timeIntervalSince($0) },
                    lastAttemptFailed: profile.remoteRefreshState?.lastAttemptFailed ?? false
                )
            }
        )
    }

    private static var architecture: String {
        #if arch(arm64)
        "arm64"
        #else
        "x86_64"
        #endif
    }

    /// Best effort: the cask installs into /Applications and leaves its Caskroom entry behind;
    /// anything else counts as a direct download.
    static func installSource(
        bundleURL: URL, fileManager: FileManager = .default
    ) -> InstallSource {
        let caskrooms = ["/opt/homebrew/Caskroom/hostflip", "/usr/local/Caskroom/hostflip"]
        let inApplications = bundleURL.deletingLastPathComponent().path == "/Applications"
        if inApplications, caskrooms.contains(where: { fileManager.fileExists(atPath: $0) }) {
            return .homebrewCask
        }
        return .direct
    }
}
