import XCTest
@testable import HostflipCore
@testable import HostflipXPC

final class DaemonChannelErrorTests: XCTestCase {
    // MARK: - XPC error classification

    func testMapsConnectionInterruptedToInterrupted() {
        let error = NSError(domain: NSCocoaErrorDomain, code: NSXPCConnectionInterrupted)
        XCTAssertEqual(DaemonChannelError(xpcError: error), .interrupted)
    }

    func testMapsConnectionInvalidToUnavailable() {
        let error = NSError(domain: NSCocoaErrorDomain, code: NSXPCConnectionInvalid)
        XCTAssertEqual(DaemonChannelError(xpcError: error), .unavailable)
    }

    func testMapsCodeSigningRequirementFailureToPeerRejected() {
        let error = NSError(domain: NSCocoaErrorDomain, code: NSXPCConnectionCodeSigningRequirementFailure)
        XCTAssertEqual(DaemonChannelError(xpcError: error), .peerRejected)
    }

    func testMapsUnknownErrorToTransport() {
        let error = NSError(domain: "SomeDomain", code: 42)
        XCTAssertEqual(DaemonChannelError(xpcError: error), .transport(domain: "SomeDomain", code: 42))
    }

    func testOnlyInterruptedIsRetryable() {
        XCTAssertTrue(DaemonChannelError.interrupted.isRetryable)
        XCTAssertFalse(DaemonChannelError.unavailable.isRetryable)
        XCTAssertFalse(DaemonChannelError.peerRejected.isRetryable)
        XCTAssertFalse(DaemonChannelError.selfSigningUnavailable.isRetryable)
        XCTAssertFalse(DaemonChannelError.protocolViolation(.undecodablePayload).isRetryable)
        XCTAssertFalse(DaemonChannelError.mergeRejected(.undecodableRequest).isRetryable)
        XCTAssertFalse(DaemonChannelError.transport(domain: "d", code: 1).isRetryable)
    }

    // MARK: - Client-side reply decoding

    func testDecodeHandshakeAcceptsMatchingProtocolVersion() throws {
        let reply = HandshakeReply(protocolVersion: XPCChannel.protocolVersion, daemonVersion: "0.1.0")

        XCTAssertEqual(try DaemonClient.decodeHandshake(XPCPayload.encode(reply)), reply)
    }

    func testDecodeHandshakeRejectsProtocolVersionMismatch() {
        let reply = HandshakeReply(protocolVersion: XPCChannel.protocolVersion + 1, daemonVersion: "9.9.9")

        XCTAssertThrowsError(try DaemonClient.decodeHandshake(XPCPayload.encode(reply))) { error in
            XCTAssertEqual(
                error as? DaemonChannelError,
                .protocolViolation(.versionMismatch(
                    daemon: XPCChannel.protocolVersion + 1,
                    app: XPCChannel.protocolVersion
                ))
            )
        }
    }

    func testDecodeHandshakeRejectsMalformedReply() {
        XCTAssertThrowsError(try DaemonClient.decodeHandshake(Data("garbage".utf8))) { error in
            XCTAssertEqual(error as? DaemonChannelError, .protocolViolation(.undecodablePayload))
        }
    }

    func testDecodeMergeOutcomeReturnsAcceptedHash() throws {
        let data = XPCPayload.encode(MergeReply.accepted(hash: "abc123"))

        XCTAssertEqual(try DaemonClient.decodeMergeOutcome(data), "abc123")
    }

    func testDecodeMergeOutcomeSurfacesRejectionAsError() {
        let data = XPCPayload.encode(MergeReply.rejected(reason: .undecodableRequest))

        XCTAssertThrowsError(try DaemonClient.decodeMergeOutcome(data)) { error in
            XCTAssertEqual(error as? DaemonChannelError, .mergeRejected(.undecodableRequest))
        }
    }

    func testDecodeMergeOutcomeSurfacesWriteFailureWithStage() {
        let failure = HostsWriteError(stage: .replace, message: "重命名失败")
        let data = XPCPayload.encode(MergeReply.writeFailed(failure))

        XCTAssertThrowsError(try DaemonClient.decodeMergeOutcome(data)) { error in
            XCTAssertEqual(error as? DaemonChannelError, .mergeWriteFailed(failure))
        }
    }

    func testDecodeMergeOutcomeRejectsMalformedReply() {
        XCTAssertThrowsError(try DaemonClient.decodeMergeOutcome(Data("garbage".utf8))) { error in
            XCTAssertEqual(error as? DaemonChannelError, .protocolViolation(.undecodablePayload))
        }
    }
}
