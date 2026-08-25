import AppKit
import Foundation
import HostflipCore
import HostflipXPC

extension DiagnosticSnapshot {
    /// The live snapshot from state the app already holds — read-only, no workspace access,
    /// and usable while the helper is unapproved or the app is paused (#90).
    @MainActor
    static func current(store: WorkspaceStore, maintenanceStore: MaintenanceStore, now: Date = .now) -> DiagnosticSnapshot {
        let info = Bundle.main.infoDictionary ?? [:]
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let profiles = store.standaloneProfiles + store.groups.flatMap(\.profiles)
        return DiagnosticSnapshot(
            // A bare `swift run` binary has no Info.plist; the compiled-in version still applies.
            appVersion: info["CFBundleShortVersionString"] as? String ?? HostflipBuild.version,
            build: info["CFBundleVersion"] as? String ?? "unknown",
            macOSVersion: "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)",
            architecture: architecture,
            installSource: installSource(),
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

    /// Best effort: the cask leaves its Caskroom entry behind (Apple silicon and Intel
    /// prefixes). The app's own location is not consulted — `brew --appdir` can put it
    /// anywhere — so anything without an entry counts as a direct download.
    static let caskrooms = ["/opt/homebrew/Caskroom/hostflip", "/usr/local/Caskroom/hostflip"]

    static func installSource(
        caskrooms: [String] = caskrooms, fileManager: FileManager = .default
    ) -> InstallSource {
        caskrooms.contains(where: { fileManager.fileExists(atPath: $0) }) ? .homebrewCask : .direct
    }
}
