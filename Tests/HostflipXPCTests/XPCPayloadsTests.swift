import XCTest
@testable import HostflipCore
@testable import HostflipXPC

final class XPCPayloadsTests: XCTestCase {
    func testMergeRequestCarriesVersionContentTargetHashAndExpectedCurrentHash() {
        let merged = MergedHosts(content: "127.0.0.1 localhost\n")
        let request = MergeRequest(merged: merged, expectedCurrentHash: "prior-hash")

        XCTAssertEqual(request.protocolVersion, XPCChannel.protocolVersion)
        XCTAssertEqual(request.content, merged.content)
        XCTAssertEqual(request.targetHash, merged.hash)
        XCTAssertEqual(request.expectedCurrentHash, "prior-hash")
        XCTAssertFalse(request.isInterruptedRetry)
    }

    func testMergeRequestRoundTripPreservesAllFields() throws {
        let request = MergeRequest(
            merged: MergedHosts(content: "10.0.0.1 api.example.com # 测试\n"),
            expectedCurrentHash: "prior-hash",
            mergeID: UUID(),
            isInterruptedRetry: true
        )

        let decoded = try XCTUnwrap(
            try? XPCPayload.decode(MergeRequest.self, from: XPCPayload.encode(request))
        )
        XCTAssertEqual(decoded, request)
    }

    func testHandshakeReplyRoundTrip() throws {
        let reply = HandshakeReply(protocolVersion: 1, daemonVersion: "0.1.0")

        let decoded = try XCTUnwrap(
            try? XPCPayload.decode(HandshakeReply.self, from: XPCPayload.encode(reply))
        )
        XCTAssertEqual(decoded, reply)
    }

    func testMergeReplyRoundTripBothCases() throws {
        let accepted = MergeReply.accepted(hash: "abc123")
        let rejected = MergeReply.rejected(
            reason: .hashMismatch(declared: "aaa", computed: "bbb")
        )

        XCTAssertEqual(
            try XPCPayload.decode(MergeReply.self, from: XPCPayload.encode(accepted)),
            accepted
        )
        XCTAssertEqual(
            try XPCPayload.decode(MergeReply.self, from: XPCPayload.encode(rejected)),
            rejected
        )
    }

    func testMergeReplyWriteFailedRoundTripCarriesStageMessageAndWrittenHash() throws {
        let failed = MergeReply.writeFailed(HostsWriteError(
            stage: .flushDNS,
            message: "dscacheutil exited with status 1",
            writtenHash: "written-hash"
        ))

        XCTAssertEqual(
            try XPCPayload.decode(MergeReply.self, from: XPCPayload.encode(failed)),
            failed
        )
    }

    func testDecodeRejectsGarbageData() {
        XCTAssertThrowsError(
            try XPCPayload.decode(MergeReply.self, from: Data("not json".utf8))
        )
    }
}
