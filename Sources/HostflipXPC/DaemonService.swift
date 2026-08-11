import Foundation
import HostflipCore

/// The daemon-side downstream for merges: writes validated merged content to the
/// system hosts. Failures must be thrown with an explicit stage; DaemonService relays
/// them to the app side as-is.
public protocol MergedHostsSink: Sendable {
    func accept(
        _ merged: MergedHosts,
        expectedCurrentHash: String,
        mergeID: UUID,
        isInterruptedRetry: Bool
    ) throws(HostsWriteError) -> HostsWriteOutcome
}

/// The XPC service object the daemon exports: decodes the request, checks the protocol
/// version, re-verifies the declared hash, and hands trusted merged content to the
/// sink. Validation failures reply with MergeReply.rejected, never a silent drop.
public final class DaemonService: NSObject, DaemonXPC, @unchecked Sendable {
    // @unchecked: all stored properties are immutable; may be called concurrently from XPC queues
    private let sink: any MergedHostsSink
    private let daemonVersion: String

    public init(sink: any MergedHostsSink, daemonVersion: String) {
        self.sink = sink
        self.daemonVersion = daemonVersion
    }

    public func handshake(reply: @escaping @Sendable (Data) -> Void) {
        reply(XPCPayload.encode(
            HandshakeReply(protocolVersion: XPCChannel.protocolVersion, daemonVersion: daemonVersion)
        ))
    }

    public func merge(_ request: Data, reply: @escaping @Sendable (Data) -> Void) {
        reply(XPCPayload.encode(process(request)))
    }

    private func process(_ request: Data) -> MergeReply {
        guard let request = try? XPCPayload.decode(MergeRequest.self, from: request) else {
            return .rejected(reason: .undecodableRequest)
        }
        guard request.protocolVersion == XPCChannel.protocolVersion else {
            return .rejected(reason: .versionMismatch(
                daemon: XPCChannel.protocolVersion,
                client: request.protocolVersion
            ))
        }
        let merged = MergedHosts(content: request.content)
        guard merged.hash == request.targetHash else {
            return .rejected(reason: .hashMismatch(declared: request.targetHash, computed: merged.hash))
        }
        do {
            switch try sink.accept(
                merged,
                expectedCurrentHash: request.expectedCurrentHash,
                mergeID: request.mergeID,
                isInterruptedRetry: request.isInterruptedRetry
            ) {
            case .accepted:
                break
            case .drift(let expected, let actual):
                return .rejected(reason: .hostsDrift(expected: expected, actual: actual))
            }
        } catch {
            return .writeFailed(error)
        }
        return .accepted(hash: merged.hash)
    }
}
