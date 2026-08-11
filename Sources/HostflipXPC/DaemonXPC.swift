import Foundation

/// The channel's @objc protocol surface. Methods exchange only Data (encoded
/// XPCPayloads types); any new capability must also be weighed against ADR 0002's
/// minimal-interface constraint.
@objc(HostflipDaemonXPC)
public protocol DaemonXPC {
    /// Replies with an encoded HandshakeReply.
    func handshake(reply: @escaping @Sendable (Data) -> Void)
    /// Performs the merge. The request is an encoded MergeRequest; the reply an encoded MergeReply.
    func merge(_ request: Data, reply: @escaping @Sendable (Data) -> Void)
}
