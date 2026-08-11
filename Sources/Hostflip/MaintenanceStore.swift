import Foundation
import HostflipXPC
import Observation

struct GitHubRelease: Equatable, Sendable {
    let version: String
    let pageURL: URL
}

enum MaintenanceFeedback: Equatable {
    case helperRemoved
    case helperRemovalFailed(String)
    case updateOpened(version: String)
    case upToDate(version: String)
    case updateCheckFailed(String)

    struct Presentation {
        let title: String
        let message: String
        let isFailure: Bool
    }

    var presentation: Presentation {
        switch self {
        case .helperRemoved:
            Presentation(
                title: "Helper Removed",
                message: "The helper was deactivated and removed. Your profiles were not changed.",
                isFailure: false
            )
        case .helperRemovalFailed(let message):
            Presentation(title: "Could Not Remove Helper", message: message, isFailure: true)
        case .updateOpened(let version):
            Presentation(
                title: "Update Available",
                message: "Opened the GitHub release page for v\(version).",
                isFailure: false
            )
        case .upToDate(let version):
            Presentation(
                title: "hostflip Is Up to Date",
                message: "You are running the latest version (v\(version)).",
                isFailure: false
            )
        case .updateCheckFailed(let message):
            Presentation(title: "Could Not Check for Updates", message: message, isFailure: true)
        }
    }
}

private struct SemanticVersion: Comparable {
    let major: Int
    let minor: Int
    let patch: Int

    init?(_ value: String) {
        let normalized = value.hasPrefix("v") ? String(value.dropFirst()) : value
        let components = normalized.split(separator: ".", omittingEmptySubsequences: false)
        guard components.count == 3,
              let major = Int(components[0]),
              let minor = Int(components[1]),
              let patch = Int(components[2]) else { return nil }
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }
}

/// State behind the main window's maintenance entry point: only orchestrates helper management and update checks, never touches workspace data.
@MainActor
@Observable
final class MaintenanceStore {
    private(set) var helperStatus: DaemonRegistrationStatus?
    private(set) var feedback: MaintenanceFeedback?
    private(set) var isRemovingHelper = false
    private(set) var isCheckingForUpdates = false

    let currentVersion: String
    private let loadHelperStatus: @Sendable () async -> DaemonRegistrationStatus
    private let unregisterHelper: @Sendable () async throws -> Void
    private let latestRelease: @Sendable () async throws -> GitHubRelease
    private let openRelease: (URL) -> Bool

    init(
        currentVersion: String,
        helperStatus: @escaping @Sendable () async -> DaemonRegistrationStatus,
        unregisterHelper: @escaping @Sendable () async throws -> Void,
        latestRelease: @escaping @Sendable () async throws -> GitHubRelease,
        openRelease: @escaping (URL) -> Bool
    ) {
        self.currentVersion = currentVersion
        loadHelperStatus = helperStatus
        self.unregisterHelper = unregisterHelper
        self.latestRelease = latestRelease
        self.openRelease = openRelease
    }

    func refreshHelperStatus() async {
        helperStatus = await loadHelperStatus()
    }

    func removeHelper() async {
        guard !isRemovingHelper else { return }
        isRemovingHelper = true
        feedback = nil
        defer { isRemovingHelper = false }

        do {
            try await unregisterHelper()
            helperStatus = await loadHelperStatus()
            feedback = .helperRemoved
        } catch {
            helperStatus = await loadHelperStatus()
            feedback = .helperRemovalFailed(
                "Could not remove the helper. Try again. Your profiles were not changed. \(error.localizedDescription)"
            )
        }
    }

    func checkForUpdates() async {
        guard !isCheckingForUpdates else { return }
        isCheckingForUpdates = true
        feedback = nil
        defer { isCheckingForUpdates = false }

        guard let current = SemanticVersion(currentVersion) else {
            feedback = .updateCheckFailed("The current app version is invalid. Reinstall hostflip and try again.")
            return
        }
        do {
            let release = try await latestRelease()
            guard let latest = SemanticVersion(release.version) else {
                feedback = .updateCheckFailed("GitHub returned an invalid release version. Try again later.")
                return
            }
            guard current < latest else {
                feedback = .upToDate(version: currentVersion)
                return
            }
            guard openRelease(release.pageURL) else {
                feedback = .updateCheckFailed("Could not open the release page. Try again.")
                return
            }
            feedback = .updateOpened(
                version: release.version.trimmingCharacters(in: CharacterSet(charactersIn: "v"))
            )
        } catch {
            feedback = .updateCheckFailed(
                "Could not check GitHub for updates. Try again. \(error.localizedDescription)"
            )
        }
    }
}
