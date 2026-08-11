import Foundation

/// The specific violation when the peer's reply breaks the protocol.
public enum ProtocolViolation: Equatable, Sendable {
    case undecodablePayload
    case versionMismatch(daemon: Int, app: Int)
}

/// Failure states of a channel call, all returned to the caller as values — neither a
/// dropped connection nor a protocol error ends up as a crash or an unclassified
/// exception. The caller uses isRetryable to decide between retrying directly and
/// guiding the user.
public enum DaemonChannelError: Error, Equatable, Sendable {
    /// This process is unsigned or has no Team ID, so the peer requirement cannot be
    /// built; fail closed — a signed build is required (see docs/signed-build-verification.md).
    case selfSigningUnavailable
    /// A single call was interrupted (the daemon crashed or is restarting); launchd relaunches the daemon on demand, so just retry.
    case interrupted
    /// The connection cannot be established: the daemon is unregistered, unapproved,
    /// disabled, or the peer rejected this process's signature. The caller should
    /// query DaemonRegistrationStatus to pick a guidance path.
    case unavailable
    /// The peer's signature failed this side's requirement, so this side rejected the connection.
    case peerRejected
    /// The peer's reply violates the protocol.
    case protocolViolation(ProtocolViolation)
    /// The daemon explicitly rejected the merge request.
    case mergeRejected(MergeRejection)
    /// The daemon's transaction failed at the given stage; writtenHash means the replacement completed but the subsequent flush failed.
    case mergeWriteFailed(HostsWriteError)
    /// Any other low-level transport error.
    case transport(domain: String, code: Int)

    public var isRetryable: Bool { self == .interrupted }

    /// Classifies an NSError from an NSXPCConnection callback into a recoverable state.
    public init(xpcError: NSError) {
        switch (xpcError.domain, xpcError.code) {
        case (NSCocoaErrorDomain, NSXPCConnectionInterrupted):
            self = .interrupted
        case (NSCocoaErrorDomain, NSXPCConnectionInvalid):
            self = .unavailable
        case (NSCocoaErrorDomain, NSXPCConnectionCodeSigningRequirementFailure):
            self = .peerRejected
        default:
            self = .transport(domain: xpcError.domain, code: xpcError.code)
        }
    }
}
