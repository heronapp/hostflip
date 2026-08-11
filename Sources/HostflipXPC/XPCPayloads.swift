import Foundation
import HostflipCore

public enum XPCChannel {
    /// Channel protocol version. App and daemon ship as a pair in the same bundle; a
    /// mismatch means an incomplete upgrade, and both sides reject it as a protocol
    /// violation rather than attempt compatibility.
    ///
    /// v5 (#24): merge requests carry a stable mergeID; an interrupted retry must verify the target file's receipt.
    /// v4 (#24): only an interrupted retry may accept the live file already matching the target content.
    /// v3 (#24): MergeRequest gains the expected current hash; the daemon rejects external drift before writing.
    /// v2 (#18): accepted changed from "channel confirmed (content discarded)" to "written to disk and flushed".
    /// v1 daemons replied accepted without writing to disk; a newer app would record a
    /// never-written hash into the manifest, so v1 must be rejected by the version check.
    public static let protocolVersion = 5
}

/// Reply to handshake: a liveness probe plus version check.
public struct HandshakeReply: Codable, Equatable, Sendable {
    public let protocolVersion: Int
    public let daemonVersion: String

    init(protocolVersion: Int, daemonVersion: String) {
        self.protocolVersion = protocolVersion
        self.daemonVersion = daemonVersion
    }
}

/// The request handing a merge to the daemon. This is the only business payload the
/// channel carries — no target path, no arbitrary commands (ADR 0002's
/// minimal-interface constraint).
public struct MergeRequest: Codable, Equatable, Sendable {
    /// The caller's channel protocol version; the daemon rejects on mismatch, closing off call paths that skip the handshake.
    public let protocolVersion: Int
    public let content: String
    /// Target hash: the daemon recomputes and compares, rejecting requests corrupted in transit or whose content and hash disagree.
    public let targetHash: String
    /// The system hosts hash the app last confirmed; the daemon must re-verify it against the live file inside the transaction lock.
    public let expectedCurrentHash: String
    /// Stable identifier for one logical merge; atomically replaced along with the target file, verified by interrupted retries.
    public let mergeID: UUID
    /// True only for the single retry after interrupted; the daemon must still verify the mergeID receipt.
    public let isInterruptedRetry: Bool

    public init(
        merged: MergedHosts,
        expectedCurrentHash: String,
        mergeID: UUID = UUID(),
        isInterruptedRetry: Bool = false
    ) {
        self.protocolVersion = XPCChannel.protocolVersion
        self.content = merged.content
        self.targetHash = merged.hash
        self.expectedCurrentHash = expectedCurrentHash
        self.mergeID = mergeID
        self.isInterruptedRetry = isInterruptedRetry
    }

    /// For tests forging malformed requests; the normal path can only construct from MergedHosts.
    init(
        protocolVersion: Int,
        content: String,
        targetHash: String,
        expectedCurrentHash: String,
        mergeID: UUID = UUID(),
        isInterruptedRetry: Bool = false
    ) {
        self.protocolVersion = protocolVersion
        self.content = content
        self.targetHash = targetHash
        self.expectedCurrentHash = expectedCurrentHash
        self.mergeID = mergeID
        self.isInterruptedRetry = isInterruptedRetry
    }
}

public enum MergeRejection: Codable, Equatable, Sendable {
    case undecodableRequest
    case versionMismatch(daemon: Int, client: Int)
    case hashMismatch(declared: String, computed: String)
    case hostsDrift(expected: String, actual: String)
}

/// Stages of the fixed merge transaction, also the locator carried in failure replies (transaction order from #18).
public enum HostsWriteStage: String, Codable, Equatable, Sendable {
    /// Roll the previous system hosts over to hosts.prev
    case backup
    /// Write the full content to a temporary file
    case writeTemp
    /// Set 644 root:wheel
    case setAttributes
    /// Atomically replace the system hosts
    case replace
    /// Flush the DNS cache
    case flushDNS
}

/// A merge transaction failure: carries the exact stage and the underlying error description for app-side presentation and diagnosis.
public struct HostsWriteError: Error, Codable, Equatable, Sendable {
    public let stage: HostsWriteStage
    public let message: String
    /// Non-nil means the atomic replacement completed and the failure happened in a later flush stage.
    public let writtenHash: String?

    public init(stage: HostsWriteStage, message: String, writtenHash: String? = nil) {
        self.stage = stage
        self.message = message
        self.writtenHash = writtenHash
    }
}

public enum MergeReply: Codable, Equatable, Sendable {
    case accepted(hash: String)
    case rejected(reason: MergeRejection)
    /// The request passed validation but the transaction failed; stage pinpoints the failing step, and writtenHash tells whether the replacement had completed.
    case writeFailed(HostsWriteError)
}

/// All payloads use JSON coding: the @objc protocol surface carries only Data, Swift
/// types stay on both ends of the channel, so coding and validation can be unit-tested
/// without XPC.
public enum XPCPayload {
    public static func encode(_ value: some Encodable) -> Data {
        // Payload types contain only String/Int and enums; JSON encoding cannot fail
        try! JSONEncoder().encode(value)
    }

    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        try JSONDecoder().decode(type, from: data)
    }
}
