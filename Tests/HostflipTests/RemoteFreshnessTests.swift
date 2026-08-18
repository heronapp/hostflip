import XCTest
import HostflipCore
@testable import Hostflip

/// The editor header's persistent Freshness surface (#77/#78): one value derived from the
/// profile's refresh state plus whether a refresh is in flight right now.
final class RemoteFreshnessTests: XCTestCase {
    private let success = Date(timeIntervalSince1970: 1_755_500_000)

    func testAnInFlightRefreshWinsOverEveryStoredState() {
        XCTAssertEqual(
            RemoteFreshness.evaluate(
                state: RemoteRefreshState(lastSuccessAt: success, lastAttemptFailed: true),
                isRefreshing: true
            ),
            .refreshing
        )
        XCTAssertEqual(RemoteFreshness.evaluate(state: nil, isRefreshing: true), .refreshing)
    }

    func testAFailedLatestAttemptReportsTheFailureWithTheLastSuccessTime() {
        XCTAssertEqual(
            RemoteFreshness.evaluate(
                state: RemoteRefreshState(lastSuccessAt: success, lastAttemptFailed: true),
                isRefreshing: false
            ),
            .failed(lastSuccessAt: success)
        )
    }

    func testAFailureBeforeAnySuccessCarriesNoSuccessTime() {
        XCTAssertEqual(
            RemoteFreshness.evaluate(
                state: RemoteRefreshState(lastAttemptFailed: true),
                isRefreshing: false
            ),
            .failed(lastSuccessAt: nil)
        )
    }

    func testASuccessfulStateReportsWhenTheContentWasRefreshed() {
        XCTAssertEqual(
            RemoteFreshness.evaluate(
                state: RemoteRefreshState(lastSuccessAt: success),
                isRefreshing: false
            ),
            .refreshed(success)
        )
    }

    func testNoRecordedStateMeansNeverRefreshed() {
        XCTAssertEqual(RemoteFreshness.evaluate(state: nil, isRefreshing: false), .neverRefreshed)
        XCTAssertEqual(
            RemoteFreshness.evaluate(state: RemoteRefreshState(), isRefreshing: false),
            .neverRefreshed,
            "a state with neither success nor failure is still never refreshed"
        )
    }
}
