import XCTest
@testable import HostflipXPC

/// Pure mapping from a channel-level Outcome to a single guidance path. The
/// precedence encoded here used to live, duplicated and subtly divergent, in
/// every consumer of Outcome.
final class SwitchGuidanceTests: XCTestCase {
    private let target = "target-hash"

    func testMergedMapsToMergedWithDaemonConfirmedHash() {
        XCTAssertEqual(
            SwitchCoordinator.Outcome.merged(hash: "confirmed").guidance(targetHash: target),
            .merged(hash: "confirmed")
        )
    }

    func testBlockedUnavailableMapsToUnavailable() {
        XCTAssertEqual(
            SwitchCoordinator.Outcome.blocked(.unavailable).guidance(targetHash: target),
            .unavailable
        )
    }

    func testBlockedNeedsApprovalMapsToNeedsApproval() {
        XCTAssertEqual(
            SwitchCoordinator.Outcome.blocked(.needsApproval).guidance(targetHash: target),
            .needsApproval
        )
    }

    func testHostsDriftRejectionMapsToHostsDrift() {
        let outcome = SwitchCoordinator.Outcome.channelFailed(
            .mergeRejected(.hostsDrift(expected: "a", actual: "b")),
            statusAfterError: .enabled
        )
        XCTAssertEqual(outcome.guidance(targetHash: target), .hostsDrift)
    }

    func testHostsDriftWinsOverRevokedApproval() {
        // Precedence: an explicit drift rejection is more actionable than the
        // post-error status re-check, even when approval was revoked meanwhile.
        let outcome = SwitchCoordinator.Outcome.channelFailed(
            .mergeRejected(.hostsDrift(expected: "a", actual: "b")),
            statusAfterError: .requiresApproval
        )
        XCTAssertEqual(outcome.guidance(targetHash: target), .hostsDrift)
    }

    func testWriteLandedOnTargetButFlushFailedMapsToWrittenButFlushFailed() {
        let failure = HostsWriteError(
            stage: .flushDNS,
            message: "dscacheutil exited 1",
            writtenHash: target
        )
        let outcome = SwitchCoordinator.Outcome.channelFailed(
            .mergeWriteFailed(failure),
            statusAfterError: .enabled
        )
        XCTAssertEqual(
            outcome.guidance(targetHash: target),
            .writtenButFlushFailed(failure)
        )
    }

    func testWriteLandedWinsOverRevokedApproval() {
        // Precedence: the replacement physically completed; that fact outranks
        // the approval re-check. (Consumers used to disagree on this order.)
        let failure = HostsWriteError(
            stage: .flushDNS,
            message: "dscacheutil exited 1",
            writtenHash: target
        )
        let outcome = SwitchCoordinator.Outcome.channelFailed(
            .mergeWriteFailed(failure),
            statusAfterError: .requiresApproval
        )
        XCTAssertEqual(
            outcome.guidance(targetHash: target),
            .writtenButFlushFailed(failure)
        )
    }

    func testWriteFailureForDifferentHashIsAPlainFailure() {
        let failure = HostsWriteError(
            stage: .flushDNS,
            message: "dscacheutil exited 1",
            writtenHash: "someone-elses-hash"
        )
        let outcome = SwitchCoordinator.Outcome.channelFailed(
            .mergeWriteFailed(failure),
            statusAfterError: .enabled
        )
        XCTAssertEqual(
            outcome.guidance(targetHash: target),
            .failed(.mergeWriteFailed(failure))
        )
    }

    func testWriteFailureWithoutWrittenHashIsAPlainFailure() {
        let failure = HostsWriteError(stage: .writeTemp, message: "disk full")
        let outcome = SwitchCoordinator.Outcome.channelFailed(
            .mergeWriteFailed(failure),
            statusAfterError: .enabled
        )
        XCTAssertEqual(
            outcome.guidance(targetHash: target),
            .failed(.mergeWriteFailed(failure))
        )
    }

    func testRevokedApprovalAfterAnyOtherChannelErrorMapsToNeedsApproval() {
        // The rule that used to be copy-pasted across consumers: when the
        // post-error re-check finds approval revoked, guide to re-approve
        // instead of reporting a one-off failure (ADR-0002).
        let outcome = SwitchCoordinator.Outcome.channelFailed(
            .unavailable,
            statusAfterError: .requiresApproval
        )
        XCTAssertEqual(outcome.guidance(targetHash: target), .needsApproval)
    }

    func testOtherChannelErrorsCarryTheErrorThroughFailed() {
        for (error, status) in [
            (DaemonChannelError.interrupted, DaemonRegistrationStatus.enabled),
            (.peerRejected, .enabled),
            (.selfSigningUnavailable, .notFound),
            (.transport(domain: "d", code: 9), .notRegistered),
            (.mergeRejected(.hashMismatch(declared: "x", computed: "y")), .enabled),
        ] {
            let outcome = SwitchCoordinator.Outcome.channelFailed(error, statusAfterError: status)
            XCTAssertEqual(outcome.guidance(targetHash: target), .failed(error))
        }
    }
}
