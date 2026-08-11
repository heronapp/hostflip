import XCTest
@testable import HostflipCore
@testable import HostflipXPC

/// Spy runner that records received commands; the writer calls it synchronously and serially, so there is no concurrent access.
private final class SpyCommandRunner: CommandRunner, @unchecked Sendable {
    private(set) var commands: [[String]] = []
    /// The Nth call returns the Nth exit code; once exhausted, returns 0.
    var exitCodes: [Int32] = []

    func run(executable: String, arguments: [String]) throws -> Int32 {
        commands.append([executable] + arguments)
        return commands.count <= exitCodes.count ? exitCodes[commands.count - 1] : 0
    }
}

/// Verifies the fixed transaction in isolation: the filesystem lives in a temporary directory (ownership injected as the current user, the transaction itself unchanged),
/// and command execution is asserted through the spy runner. The real /etc/hosts and root:wheel appear only in the production initializer.
final class SystemHostsWriterTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("hostflip-writer-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("127.0.0.1 localhost\n".utf8).write(to: hostsURL)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private var hostsURL: URL { directory.appendingPathComponent("hosts") }
    private var backupURL: URL { directory.appendingPathComponent("hosts.prev") }
    private var importedHash: String { MergedHosts(content: "127.0.0.1 localhost\n").hash }

    private func makeWriter(
        runner: SpyCommandRunner,
        beforeReplacement: @escaping @Sendable () throws -> Void = {}
    ) -> SystemHostsWriter {
        SystemHostsWriter(
            hostsURL: hostsURL,
            owner: Int(getuid()),
            group: Int(getgid()),
            runner: runner,
            beforeReplacement: beforeReplacement
        )
    }

    func testAcceptReplacesHostsRollsBackupSetsPermissionsAndFlushesDNSInOrder() throws {
        let runner = SpyCommandRunner()
        let writer = makeWriter(runner: runner)
        let merged = MergedHosts(content: "127.0.0.1 localhost\n10.0.0.1 api.example.com\n")

        _ = try writer.accept(merged, expectedCurrentHash: importedHash)

        XCTAssertEqual(try String(contentsOf: hostsURL, encoding: .utf8), merged.content)
        XCTAssertEqual(try String(contentsOf: backupURL, encoding: .utf8), "127.0.0.1 localhost\n")
        let attributes = try FileManager.default.attributesOfItem(atPath: hostsURL.path)
        XCTAssertEqual(attributes[.posixPermissions] as? Int, 0o644)
        XCTAssertEqual(runner.commands, [
            ["/usr/bin/dscacheutil", "-flushcache"],
            ["/usr/bin/killall", "-HUP", "mDNSResponder"],
        ])
        // The transaction leaves no residue: the directory contains only the target file and the rolled backup
        XCTAssertEqual(
            Set(try FileManager.default.contentsOfDirectory(atPath: directory.path)),
            ["hosts", "hosts.prev"]
        )
    }

    func testConsecutiveAcceptsKeepSingleBackupOfImmediatelyPreviousVersion() throws {
        let writer = makeWriter(runner: SpyCommandRunner())
        let first = MergedHosts(content: "10.0.0.1 first.example.com\n")
        let second = MergedHosts(content: "10.0.0.2 second.example.com\n")

        _ = try writer.accept(first, expectedCurrentHash: importedHash)
        _ = try writer.accept(second, expectedCurrentHash: first.hash)

        XCTAssertEqual(try String(contentsOf: hostsURL, encoding: .utf8), second.content)
        XCTAssertEqual(try String(contentsOf: backupURL, encoding: .utf8), first.content)
    }

    func testInterruptedRetryWithCompletedMergeIDKeepsBackupAndSkipsDuplicateRefresh() throws {
        // A retry after a lost reply sends the same content again: the whole transaction must short-circuit —
        // in particular hosts.prev must keep the true previous version and not get rolled over with the current content
        let runner = SpyCommandRunner()
        let writer = makeWriter(runner: runner)
        let merged = MergedHosts(content: "10.0.0.1 first.example.com\n")
        let mergeID = UUID()

        _ = try writer.accept(merged, expectedCurrentHash: importedHash, mergeID: mergeID)
        let retryOutcome = try writer.accept(
            MergedHosts(content: merged.content),
            // When the first attempt hit disk but the reply was lost, the app has not recorded the new hash yet, so the retry still declares the old baseline
            expectedCurrentHash: importedHash,
            mergeID: mergeID,
            isInterruptedRetry: true
        )

        XCTAssertEqual(retryOutcome, .accepted)
        XCTAssertEqual(try String(contentsOf: hostsURL, encoding: .utf8), merged.content)
        XCTAssertEqual(try String(contentsOf: backupURL, encoding: .utf8), "127.0.0.1 localhost\n")
        // When the first transaction already completed the flush and only the reply was lost, no repeat flush is needed.
        XCTAssertEqual(runner.commands.count, 2)
    }

    func testMatchingContentRetriesPendingDNSRefreshBeforeAccepting() throws {
        let runner = SpyCommandRunner()
        runner.exitCodes = [1]
        let writer = makeWriter(runner: runner)
        let merged = MergedHosts(content: "10.0.0.1 first.example.com\n")

        XCTAssertThrowsError(try writer.accept(merged, expectedCurrentHash: importedHash))

        let outcome = try writer.accept(
            merged,
            // The app learned from the failure reply that the replacement completed, so it uses the written content as the on-disk baseline.
            expectedCurrentHash: merged.hash
        )

        XCTAssertEqual(outcome, .accepted)
        XCTAssertEqual(try String(contentsOf: hostsURL, encoding: .utf8), merged.content)
        XCTAssertEqual(try String(contentsOf: backupURL, encoding: .utf8), "127.0.0.1 localhost\n")
        XCTAssertEqual(runner.commands, [
            ["/usr/bin/dscacheutil", "-flushcache"],
            ["/usr/bin/dscacheutil", "-flushcache"],
            ["/usr/bin/killall", "-HUP", "mDNSResponder"],
        ])
    }

    func testInterruptedRetryDoesNotAdoptMatchingTargetWithoutMatchingMergeID() throws {
        let runner = SpyCommandRunner()
        let writer = makeWriter(runner: runner)
        let target = MergedHosts(content: "10.0.0.1 managed.local\n")
        try Data(target.content.utf8).write(to: hostsURL)

        let outcome = try writer.accept(
            target,
            expectedCurrentHash: importedHash,
            mergeID: UUID(),
            isInterruptedRetry: true
        )

        XCTAssertEqual(outcome, .drift(expected: importedHash, actual: target.hash))
        XCTAssertFalse(FileManager.default.fileExists(atPath: backupURL.path))
        XCTAssertEqual(runner.commands, [])
    }

    func testAcceptRejectsDriftIntroducedImmediatelyBeforeReplacement() throws {
        let runner = SpyCommandRunner()
        let external = "127.0.0.1 localhost\n1.2.3.4 external.local\n"
        let writer = makeWriter(runner: runner) { [hostsURL] in
            try Data(external.utf8).write(to: hostsURL)
        }

        let outcome = try writer.accept(
            MergedHosts(content: "10.0.0.1 managed.local\n"),
            expectedCurrentHash: importedHash
        )

        XCTAssertEqual(
            outcome,
            .drift(expected: importedHash, actual: MergedHosts(content: external).hash)
        )
        XCTAssertEqual(try String(contentsOf: hostsURL, encoding: .utf8), external)
        XCTAssertEqual(runner.commands, [])
    }

    func testAcceptRejectsDriftBeforeTouchingHostsOrBackup() throws {
        let runner = SpyCommandRunner()
        let writer = makeWriter(runner: runner)
        let expected = MergedHosts(content: "127.0.0.1 localhost\n").hash
        try Data("127.0.0.1 localhost\n1.2.3.4 external.local\n".utf8).write(to: hostsURL)

        let outcome = try writer.accept(
            MergedHosts(content: "10.0.0.1 managed.local\n"),
            expectedCurrentHash: expected
        )

        XCTAssertEqual(
            outcome,
            .drift(
                expected: expected,
                actual: MergedHosts(content: "127.0.0.1 localhost\n1.2.3.4 external.local\n").hash
            )
        )
        XCTAssertEqual(
            try String(contentsOf: hostsURL, encoding: .utf8),
            "127.0.0.1 localhost\n1.2.3.4 external.local\n"
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: backupURL.path))
        XCTAssertEqual(runner.commands, [])
    }

    func testAcceptFailsAtBackupWhenCurrentHostsIsUnreadableAndTouchesNothing() throws {
        let runner = SpyCommandRunner()
        let writer = makeWriter(runner: runner)
        try FileManager.default.removeItem(at: hostsURL)

        XCTAssertThrowsError(try writer.accept(
            MergedHosts(content: "1.1.1.1 a\n"),
            expectedCurrentHash: importedHash
        )) { error in
            XCTAssertEqual((error as? HostsWriteError)?.stage, .backup)
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [])
        XCTAssertEqual(runner.commands, [])
    }

    func testAcceptFailsAtSetAttributesWithoutReplacingTargetOrFlushing() throws {
        // A non-root process cannot chown to root:wheel — which conveniently verifies that if ownership cannot be set, the replacement never happens
        let runner = SpyCommandRunner()
        let writer = SystemHostsWriter(hostsURL: hostsURL, owner: 0, group: 0, runner: runner)

        XCTAssertThrowsError(try writer.accept(
            MergedHosts(content: "1.1.1.1 a\n"),
            expectedCurrentHash: importedHash
        )) { error in
            XCTAssertEqual((error as? HostsWriteError)?.stage, .setAttributes)
        }
        XCTAssertEqual(try String(contentsOf: hostsURL, encoding: .utf8), "127.0.0.1 localhost\n")
        // The failed temporary file is cleaned up, leaving only the target and the already-rolled backup
        XCTAssertEqual(
            Set(try FileManager.default.contentsOfDirectory(atPath: directory.path)),
            ["hosts", "hosts.prev"]
        )
        XCTAssertEqual(runner.commands, [])
    }

    func testAcceptReportsFlushDNSFailureAfterReplacementWithoutRunningRemainingCommands() throws {
        let runner = SpyCommandRunner()
        runner.exitCodes = [1]
        let writer = makeWriter(runner: runner)
        let merged = MergedHosts(content: "10.0.0.1 api.example.com\n")

        XCTAssertThrowsError(try writer.accept(merged, expectedCurrentHash: importedHash)) { error in
            let error = error as? HostsWriteError
            XCTAssertEqual(error?.stage, .flushDNS)
            XCTAssertEqual(error?.message, "/usr/bin/dscacheutil exited with code 1")
            XCTAssertEqual(error?.writtenHash, merged.hash)
        }
        // The replacement completed; the failure happens only in the flush stage, and execution stops right after the first command fails
        XCTAssertEqual(try String(contentsOf: hostsURL, encoding: .utf8), merged.content)
        XCTAssertEqual(runner.commands, [["/usr/bin/dscacheutil", "-flushcache"]])
    }
}
