import Foundation
import HostflipCore

/// What the editor header's persistent Freshness line shows for a Remote Profile (#77/#78).
/// An in-flight refresh outranks the stored state; a failed latest attempt is reported
/// alongside the last success rather than replacing it.
enum RemoteFreshness: Equatable {
    case refreshing
    case refreshed(Date)
    case failed(lastSuccessAt: Date?)
    case neverRefreshed

    static func evaluate(state: RemoteRefreshState?, isRefreshing: Bool) -> RemoteFreshness {
        if isRefreshing { return .refreshing }
        guard let state else { return .neverRefreshed }
        if state.lastAttemptFailed { return .failed(lastSuccessAt: state.lastSuccessAt) }
        if let lastSuccessAt = state.lastSuccessAt { return .refreshed(lastSuccessAt) }
        return .neverRefreshed
    }
}
