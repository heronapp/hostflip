import Darwin
import Foundation
import HostflipCore

public enum HostsWriteOutcome: Equatable, Sendable {
    case accepted
    case drift(expected: String, actual: String)
}

/// Seam for command execution: the real implementation launches a Process; isolated tests inject a spy.
protocol CommandRunner: Sendable {
    /// Returns the exit code; throws when the process cannot be launched.
    func run(executable: String, arguments: [String]) throws -> Int32
}

struct ProcessCommandRunner: CommandRunner {
    func run(executable: String, arguments: [String]) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }
}

/// Sink that replaces the system hosts in a fixed transaction (#18):
/// roll over the previous version → write the full content to a temp file
/// → 644 root:wheel + mergeID → re-verify the live file → atomic rename → flush DNS.
/// The write target, ownership, and flush commands are all fixed in the production
/// initializer and beyond the XPC caller's reach (ADR 0002's minimal-interface
/// constraint); the parameterized initializer is for isolated tests only (internal + @testable).
public final class SystemHostsWriter: MergedHostsSink, @unchecked Sendable {
    // @unchecked: all stored properties are immutable; the transaction itself is serialized by lock
    private let hostsURL: URL
    /// Single rolling backup, in the same directory as the target; unrelated to the
    /// workspace's first-import backup (hosts.orig). Reflects the live file at the
    /// start of this transaction — failed transactions roll over too; it is not a
    /// history of successful writes.
    private let backupURL: URL
    private let tempURL: URL
    private let owner: Int
    private let group: Int
    private let runner: any CommandRunner
    /// Test seam: injects a concurrent external write right before the final live-file re-verification.
    private let beforeReplacement: @Sendable () throws -> Void
    /// Serializes the whole transaction: concurrent XPC requests must not interleave their backups and replacements.
    private let lock = NSLock()

    private static let flushCommands: [(executable: String, arguments: [String])] = [
        ("/usr/bin/dscacheutil", ["-flushcache"]),
        ("/usr/bin/killall", ["-HUP", "mDNSResponder"]),
    ]
    private enum MergeReceiptState: String {
        case pendingDNSRefresh = "pending"
        case completed
    }

    private struct MergeReceipt {
        let mergeID: UUID
        let state: MergeReceiptState
    }

    private static let mergeReceiptAttribute = "com.heronapp.hostflip.merge-receipt"

    /// Production initializer: targets /etc/hosts, owned by root:wheel, and actually runs the flush commands.
    public convenience init() {
        self.init(
            hostsURL: URL(fileURLWithPath: "/etc/hosts"),
            owner: 0,
            group: 0,
            runner: ProcessCommandRunner(),
            beforeReplacement: {}
        )
    }

    init(
        hostsURL: URL,
        owner: Int,
        group: Int,
        runner: any CommandRunner,
        beforeReplacement: @escaping @Sendable () throws -> Void = {}
    ) {
        self.hostsURL = hostsURL
        let directory = hostsURL.deletingLastPathComponent()
        self.backupURL = directory.appendingPathComponent("hosts.prev")
        self.tempURL = directory.appendingPathComponent("hosts.hostflip.tmp")
        self.owner = owner
        self.group = group
        self.runner = runner
        self.beforeReplacement = beforeReplacement
    }

    public func accept(
        _ merged: MergedHosts,
        expectedCurrentHash: String,
        mergeID: UUID = UUID(),
        isInterruptedRetry: Bool = false
    ) throws(HostsWriteError) -> HostsWriteOutcome {
        lock.lock()
        defer { lock.unlock() }

        let currentData = try step(.backup) {
            try Data(contentsOf: hostsURL)
        }
        let actual = MergedHosts.hash(of: currentData)
        guard actual == expectedCurrentHash else {
            // An interrupted retry must still check the mergeID that was atomically
            // replaced along with the target file; equal content alone does not prove
            // the first request landed, and trusting it could adopt a concurrent
            // external modification.
            if isInterruptedRetry,
               currentData == Data(merged.content.utf8),
               let receipt = storedMergeReceipt(at: hostsURL),
               receipt.mergeID == mergeID {
                if receipt.state == .pendingDNSRefresh {
                    try refreshDNSAfterWriting(hash: merged.hash, mergeID: mergeID)
                }
                return .accepted
            }
            return .drift(expected: expectedCurrentHash, actual: actual)
        }

        // Skip rewriting when the content is unchanged; but if the DNS flush after
        // the previous replacement has not finished, it must be completed first to
        // preserve the protocol meaning of accepted = written to disk and flushed.
        if currentData == Data(merged.content.utf8) {
            if let receipt = storedMergeReceipt(at: hostsURL),
               receipt.state == .pendingDNSRefresh {
                try refreshDNSAfterWriting(hash: merged.hash, mergeID: receipt.mergeID)
            }
            return .accepted
        }

        try step(.backup) {
            try currentData.write(to: backupURL, options: .atomic)
        }
        do throws(HostsWriteError) {
            try step(.writeTemp) {
                try Data(merged.content.utf8).write(to: tempURL)
                // fsync before rename: a power loss or crash must not leave the replaced system hosts truncated
                let handle = try FileHandle(forWritingTo: tempURL)
                try handle.synchronize()
                try handle.close()
            }
            try step(.setAttributes) {
                try FileManager.default.setAttributes([
                    .posixPermissions: 0o644,
                    .ownerAccountID: owner,
                    .groupOwnerAccountID: group,
                ], ofItemAtPath: tempURL.path)
                try setMergeReceipt(
                    MergeReceipt(mergeID: mergeID, state: .pendingDNSRefresh),
                    at: tempURL
                )
            }
            let dataBeforeReplacement = try step(.replace) {
                try beforeReplacement()
                return try Data(contentsOf: hostsURL)
            }
            guard dataBeforeReplacement == currentData else {
                try? FileManager.default.removeItem(at: tempURL)
                return .drift(
                    expected: expectedCurrentHash,
                    actual: MergedHosts.hash(of: dataBeforeReplacement)
                )
            }
            try step(.replace) {
                guard rename(tempURL.path, hostsURL.path) == 0 else {
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
            }
        } catch {
            try? FileManager.default.removeItem(at: tempURL)
            throw error
        }
        try refreshDNSAfterWriting(hash: merged.hash, mergeID: mergeID)
        return .accepted
    }

    private func refreshDNSAfterWriting(hash: String, mergeID: UUID) throws(HostsWriteError) {
        do throws(HostsWriteError) {
            try flushDNS()
        } catch {
            throw HostsWriteError(
                stage: error.stage,
                message: error.message,
                writtenHash: hash
            )
        }
        // The flush already succeeded; the completed marker only avoids a duplicate
        // flush after a lost reply. If updating the marker fails, the lingering
        // pending state safely triggers one extra flush next time.
        try? setMergeReceipt(
            MergeReceipt(mergeID: mergeID, state: .completed),
            at: hostsURL
        )
    }

    private func setMergeReceipt(_ receipt: MergeReceipt, at url: URL) throws {
        let value = Data("\(receipt.state.rawValue):\(receipt.mergeID.uuidString)".utf8)
        let result = value.withUnsafeBytes { buffer in
            setxattr(
                url.path,
                Self.mergeReceiptAttribute,
                buffer.baseAddress,
                buffer.count,
                0,
                0
            )
        }
        guard result == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    private func storedMergeReceipt(at url: URL) -> MergeReceipt? {
        let length = getxattr(url.path, Self.mergeReceiptAttribute, nil, 0, 0, 0)
        guard length > 0 else { return nil }
        var value = Data(count: length)
        let readLength = value.withUnsafeMutableBytes { buffer in
            getxattr(
                url.path,
                Self.mergeReceiptAttribute,
                buffer.baseAddress,
                buffer.count,
                0,
                0
            )
        }
        guard readLength == length else { return nil }
        let components = String(decoding: value, as: UTF8.self).split(
            separator: ":",
            maxSplits: 1,
            omittingEmptySubsequences: false
        )
        guard components.count == 2,
              let state = MergeReceiptState(rawValue: String(components[0])),
              let mergeID = UUID(uuidString: String(components[1])) else {
            return nil
        }
        return MergeReceipt(mergeID: mergeID, state: state)
    }

    private func step<T>(
        _ stage: HostsWriteStage,
        _ body: () throws -> T
    ) throws(HostsWriteError) -> T {
        do {
            return try body()
        } catch {
            throw HostsWriteError(stage: stage, message: error.localizedDescription)
        }
    }

    private func flushDNS() throws(HostsWriteError) {
        for command in Self.flushCommands {
            let status: Int32
            do {
                status = try runner.run(executable: command.executable, arguments: command.arguments)
            } catch {
                throw HostsWriteError(stage: .flushDNS, message: error.localizedDescription)
            }
            guard status == 0 else {
                throw HostsWriteError(stage: .flushDNS, message: "\(command.executable) exited with code \(status)")
            }
        }
    }
}
