import XCTest
@testable import HostflipCore
@testable import HostflipXPC

/// Sink that records received content, for asserting whether the daemon handed the merged content downstream;
/// a failure can be injected to simulate a write transaction going wrong.
private final class SpySink: MergedHostsSink, @unchecked Sendable {
    private(set) var accepted: [MergedHosts] = []
    private(set) var expectedCurrentHashes: [String] = []
    private(set) var mergeIDs: [UUID] = []
    private(set) var interruptedRetryValues: [Bool] = []
    var failure: HostsWriteError?
    var outcome = HostsWriteOutcome.accepted

    func accept(
        _ merged: MergedHosts,
        expectedCurrentHash: String,
        mergeID: UUID,
        isInterruptedRetry: Bool
    ) throws(HostsWriteError) -> HostsWriteOutcome {
        if let failure { throw failure }
        accepted.append(merged)
        expectedCurrentHashes.append(expectedCurrentHash)
        mergeIDs.append(mergeID)
        interruptedRetryValues.append(isInterruptedRetry)
        return outcome
    }
}

/// Container that receives the @Sendable reply callback; the service invokes it synchronously, so there is no concurrent access.
private final class ReplyCapture: @unchecked Sendable {
    var data: Data?
}

final class DaemonServiceTests: XCTestCase {
    private func reply(from service: DaemonService, request: Data) -> MergeReply {
        let capture = ReplyCapture()
        service.merge(request) { capture.data = $0 }
        return try! XPCPayload.decode(MergeReply.self, from: capture.data!)
    }

    func testHandshakeRepliesProtocolAndDaemonVersion() throws {
        let service = DaemonService(sink: SpySink(), daemonVersion: "0.1.0")

        let capture = ReplyCapture()
        service.handshake { capture.data = $0 }

        let reply = try XPCPayload.decode(HandshakeReply.self, from: XCTUnwrap(capture.data))
        XCTAssertEqual(reply, HandshakeReply(protocolVersion: XPCChannel.protocolVersion, daemonVersion: "0.1.0"))
    }

    func testMergeAcceptsValidRequestAndForwardsMergedContentToSink() {
        let sink = SpySink()
        let service = DaemonService(sink: sink, daemonVersion: "0.1.0")
        let merged = MergedHosts(content: "127.0.0.1 localhost\n")
        let mergeID = UUID()

        let reply = reply(from: service, request: XPCPayload.encode(MergeRequest(
            merged: merged,
            expectedCurrentHash: "prior-hash",
            mergeID: mergeID,
            isInterruptedRetry: true
        )))

        XCTAssertEqual(reply, .accepted(hash: merged.hash))
        XCTAssertEqual(sink.accepted, [merged])
        XCTAssertEqual(sink.expectedCurrentHashes, ["prior-hash"])
        XCTAssertEqual(sink.mergeIDs, [mergeID])
        XCTAssertEqual(sink.interruptedRetryValues, [true])
    }

    func testMergeReportsWriteFailureStageFromSink() {
        let sink = SpySink()
        let failure = HostsWriteError(stage: .flushDNS, message: "dscacheutil 退出码 1")
        sink.failure = failure
        let service = DaemonService(sink: sink, daemonVersion: "0.1.0")
        let merged = MergedHosts(content: "127.0.0.1 localhost\n")

        let reply = reply(from: service, request: XPCPayload.encode(MergeRequest(
            merged: merged,
            expectedCurrentHash: "prior-hash"
        )))

        XCTAssertEqual(reply, .writeFailed(failure))
        XCTAssertEqual(sink.accepted, [])
    }

    func testMergeRejectsDetectedHostsDrift() {
        let sink = SpySink()
        sink.outcome = .drift(expected: "prior-hash", actual: "external-hash")
        let service = DaemonService(sink: sink, daemonVersion: "0.1.0")
        let merged = MergedHosts(content: "127.0.0.1 localhost\n")

        let reply = reply(from: service, request: XPCPayload.encode(MergeRequest(
            merged: merged,
            expectedCurrentHash: "prior-hash"
        )))

        XCTAssertEqual(
            reply,
            .rejected(reason: .hostsDrift(expected: "prior-hash", actual: "external-hash"))
        )
    }

    func testMergeRejectsProtocolVersionMismatchWithoutTouchingSink() {
        let sink = SpySink()
        let service = DaemonService(sink: sink, daemonVersion: "0.1.0")
        let merged = MergedHosts(content: "127.0.0.1 localhost\n")
        let stale = MergeRequest(
            protocolVersion: XPCChannel.protocolVersion + 1,
            content: merged.content,
            targetHash: merged.hash,
            expectedCurrentHash: "prior-hash"
        )

        let reply = reply(from: service, request: XPCPayload.encode(stale))

        XCTAssertEqual(reply, .rejected(reason: .versionMismatch(
            daemon: XPCChannel.protocolVersion,
            client: XPCChannel.protocolVersion + 1
        )))
        XCTAssertEqual(sink.accepted, [])
    }

    func testMergeRejectsHashMismatchWithoutTouchingSink() {
        let sink = SpySink()
        let service = DaemonService(sink: sink, daemonVersion: "0.1.0")
        let merged = MergedHosts(content: "127.0.0.1 localhost\n")
        let forged = MergeRequest(
            protocolVersion: XPCChannel.protocolVersion,
            content: merged.content,
            targetHash: "deadbeef",
            expectedCurrentHash: "prior-hash"
        )

        let reply = reply(from: service, request: XPCPayload.encode(forged))

        XCTAssertEqual(reply, .rejected(reason: .hashMismatch(declared: "deadbeef", computed: merged.hash)))
        XCTAssertEqual(sink.accepted, [])
    }

    func testMergeRejectsUndecodableRequestWithoutTouchingSink() {
        let sink = SpySink()
        let service = DaemonService(sink: sink, daemonVersion: "0.1.0")

        let reply = reply(from: service, request: Data("not a request".utf8))

        XCTAssertEqual(reply, .rejected(reason: .undecodableRequest))
        XCTAssertEqual(sink.accepted, [])
    }
}
