import Foundation
import HostflipCore

/// The app-side channel client: manages the NSXPCConnection to the daemon and maps
/// XPC callbacks to DaemonChannelError's recoverable states. An invalidated connection
/// is dropped automatically and rebuilt on the next call.
public actor DaemonClient {
    private var connection: NSXPCConnection?

    public init() {}

    /// Probes liveness and checks the protocol version.
    public func handshake() async throws -> HandshakeReply {
        let data = try await send { daemon, reply in
            daemon.handshake(reply: reply)
        }
        return try Self.decodeHandshake(data)
    }

    /// Asks the daemon to perform the merge; returns the daemon-confirmed hash.
    public func merge(
        _ merged: MergedHosts,
        expectedCurrentHash: String,
        mergeID: UUID,
        isInterruptedRetry: Bool
    ) async throws -> String {
        let request = XPCPayload.encode(MergeRequest(
            merged: merged,
            expectedCurrentHash: expectedCurrentHash,
            mergeID: mergeID,
            isInterruptedRetry: isInterruptedRetry
        ))
        let data = try await send { daemon, reply in
            daemon.merge(request, reply: reply)
        }
        return try Self.decodeMergeOutcome(data)
    }

    // MARK: - Connection management

    /// Lazily establishes the connection. The peer must be a daemon signed with this
    /// process's Team ID; if this process is unsigned, fail closed and never connect.
    private func activeConnection() throws -> NSXPCConnection {
        if let connection { return connection }
        let requirement = try SigningIdentity.peerRequirement(
            identifier: ChannelIdentity.daemonIdentifier
        )
        let connection = NSXPCConnection(
            machServiceName: ChannelIdentity.daemonIdentifier,
            options: .privileged
        )
        connection.remoteObjectInterface = NSXPCInterface(with: DaemonXPC.self)
        connection.setCodeSigningRequirement(requirement)
        // An interruption (daemon restart) keeps the connection — launchd relaunches the peer on demand; only invalidation triggers a rebuild.
        connection.invalidationHandler = { [weak self] in
            Task { await self?.dropConnection() }
        }
        connection.resume()
        self.connection = connection
        return connection
    }

    private func dropConnection() {
        connection = nil
    }

    private func send(
        _ invoke: @escaping @Sendable (any DaemonXPC, @escaping @Sendable (Data) -> Void) -> Void
    ) async throws -> Data {
        let connection = try activeConnection()
        return try await withCheckedThrowingContinuation { continuation in
            // NSXPC contract: exactly one of reply and errorHandler is called
            let proxy = connection.remoteObjectProxyWithErrorHandler { error in
                continuation.resume(throwing: DaemonChannelError(xpcError: error as NSError))
            }
            invoke(proxy as! any DaemonXPC) { data in
                continuation.resume(returning: data)
            }
        }
    }

    // MARK: - Reply decoding

    static func decodeHandshake(_ data: Data) throws -> HandshakeReply {
        guard let reply = try? XPCPayload.decode(HandshakeReply.self, from: data) else {
            throw DaemonChannelError.protocolViolation(.undecodablePayload)
        }
        guard reply.protocolVersion == XPCChannel.protocolVersion else {
            throw DaemonChannelError.protocolViolation(
                .versionMismatch(daemon: reply.protocolVersion, app: XPCChannel.protocolVersion)
            )
        }
        return reply
    }

    static func decodeMergeOutcome(_ data: Data) throws -> String {
        guard let reply = try? XPCPayload.decode(MergeReply.self, from: data) else {
            throw DaemonChannelError.protocolViolation(.undecodablePayload)
        }
        switch reply {
        case .accepted(let hash):
            return hash
        case .rejected(let reason):
            throw DaemonChannelError.mergeRejected(reason)
        case .writeFailed(let error):
            throw DaemonChannelError.mergeWriteFailed(error)
        }
    }
}
