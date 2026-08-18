import Foundation
import XCTest
@testable import HostflipCore

/// Remote Header parsing, serialization, and escaping (ADR-0012): the content's first line is
/// the sole carrier of remote identity, and anything malformed reads as a local profile.
final class RemoteHeaderTests: XCTestCase {
    private let url = URL(string: "https://example.com/hosts.txt")!

    // MARK: - Parsing

    func testParsesAFullHeaderLine() {
        let header = RemoteHeader.parse(
            fromContent: "#!hostflip-remote https://example.com/hosts.txt interval=6h\n1.2.3.4 a.example.com\n"
        )

        XCTAssertEqual(header, RemoteHeader(sourceURL: url, interval: .sixHours))
    }

    func testAnOmittedIntervalDefaultsTo24Hours() {
        let header = RemoteHeader.parse(fromContent: "#!hostflip-remote https://example.com/hosts.txt\n")

        XCTAssertEqual(header, RemoteHeader(sourceURL: url, interval: .twentyFourHours))
    }

    func testParsesEveryIntervalPreset() {
        for interval in RemoteHeader.RefreshInterval.allCases {
            let header = RemoteHeader.parse(
                fromContent: "#!hostflip-remote https://example.com/hosts.txt interval=\(interval.rawValue)\n"
            )
            XCTAssertEqual(header?.interval, interval, "interval=\(interval.rawValue) must parse")
        }
    }

    func testHeaderOnlyContentWithoutATrailingNewlineParses() {
        let header = RemoteHeader.parse(fromContent: "#!hostflip-remote https://example.com/hosts.txt")

        XCTAssertEqual(header?.sourceURL, url)
    }

    func testACRLFTerminatedHeaderLineParses() {
        let header = RemoteHeader.parse(
            fromContent: "#!hostflip-remote https://example.com/hosts.txt interval=1h\r\n1.2.3.4 a.example.com\r\n"
        )

        XCTAssertEqual(header, RemoteHeader(sourceURL: url, interval: .oneHour))
    }

    func testExtraSpacesAndTabsBetweenFieldsParse() {
        let header = RemoteHeader.parse(fromContent: "#!hostflip-remote\thttps://example.com/hosts.txt  interval=1h\n")

        XCTAssertEqual(header, RemoteHeader(sourceURL: url, interval: .oneHour))
    }

    // MARK: - Malformed lines are not remote

    func testAWrongTokenIsNotRemote() {
        XCTAssertNil(RemoteHeader.parse(fromContent: "#!hostflip-remotely https://example.com/hosts.txt\n"))
        XCTAssertNil(RemoteHeader.parse(fromContent: "#!MANAGED-CONFIG https://example.com/hosts.txt\n"))
        XCTAssertNil(RemoteHeader.parse(fromContent: "# !hostflip-remote https://example.com/hosts.txt\n"))
    }

    func testLeadingWhitespaceIsNotRemote() {
        XCTAssertNil(RemoteHeader.parse(fromContent: " #!hostflip-remote https://example.com/hosts.txt\n"))
    }

    func testAMissingURLIsNotRemote() {
        XCTAssertNil(RemoteHeader.parse(fromContent: "#!hostflip-remote\n1.2.3.4 a.example.com\n"))
        XCTAssertNil(RemoteHeader.parse(fromContent: "#!hostflip-remote interval=6h\n"))
    }

    func testANonHTTPSURLIsNotRemote() {
        XCTAssertNil(RemoteHeader.parse(fromContent: "#!hostflip-remote http://example.com/hosts.txt\n"))
        XCTAssertNil(RemoteHeader.parse(fromContent: "#!hostflip-remote ftp://example.com/hosts.txt\n"))
        XCTAssertNil(RemoteHeader.parse(fromContent: "#!hostflip-remote file:///etc/hosts\n"))
    }

    func testAnHTTPSURLWithoutAHostIsNotRemote() {
        XCTAssertNil(RemoteHeader.parse(fromContent: "#!hostflip-remote https://\n"))
        XCTAssertNil(RemoteHeader.parse(fromContent: "#!hostflip-remote https:///hosts.txt\n"))
    }

    func testAnUnknownIntervalIsNotRemote() {
        XCTAssertNil(RemoteHeader.parse(fromContent: "#!hostflip-remote https://example.com/hosts.txt interval=2h\n"))
        XCTAssertNil(RemoteHeader.parse(fromContent: "#!hostflip-remote https://example.com/hosts.txt interval=24H\n"))
        XCTAssertNil(RemoteHeader.parse(fromContent: "#!hostflip-remote https://example.com/hosts.txt interval=\n"))
    }

    func testAMisnamedIntervalParameterIsNotRemote() {
        XCTAssertNil(RemoteHeader.parse(fromContent: "#!hostflip-remote https://example.com/hosts.txt 6h\n"))
        XCTAssertNil(RemoteHeader.parse(fromContent: "#!hostflip-remote https://example.com/hosts.txt refresh=6h\n"))
    }

    func testExtraTrailingFieldsAreNotRemote() {
        XCTAssertNil(RemoteHeader.parse(
            fromContent: "#!hostflip-remote https://example.com/hosts.txt interval=6h strict\n"
        ))
    }

    func testATokenBelowTheFirstLineIsNotRemote() {
        XCTAssertNil(RemoteHeader.parse(
            fromContent: "# a comment\n#!hostflip-remote https://example.com/hosts.txt\n"
        ))
    }

    func testEmptyAndPlainContentAreNotRemote() {
        XCTAssertNil(RemoteHeader.parse(fromContent: ""))
        XCTAssertNil(RemoteHeader.parse(fromContent: "127.0.0.1 localhost\n"))
    }

    // MARK: - Construction validation

    func testConstructingWithANonHTTPSURLFails() {
        XCTAssertNil(RemoteHeader(sourceURL: URL(string: "http://example.com/hosts.txt")!))
        XCTAssertNil(RemoteHeader(sourceURL: URL(string: "ftp://example.com/hosts.txt")!, interval: .oneHour))
        XCTAssertNil(RemoteHeader(sourceURL: URL(string: "file:///etc/hosts")!))
    }

    func testConstructingWithAHostlessHTTPSURLFails() {
        XCTAssertNil(RemoteHeader(sourceURL: URL(string: "https:///hosts.txt")!))
    }

    func testARelativeSourceURLIsStoredAbsoluteAndRoundTrips() throws {
        let relative = try XCTUnwrap(
            URL(string: "hosts.txt", relativeTo: URL(string: "https://example.com/lists/"))
        )

        let header = try XCTUnwrap(RemoteHeader(sourceURL: relative))

        XCTAssertEqual(header.sourceURL.absoluteString, "https://example.com/lists/hosts.txt")
        XCTAssertNil(header.sourceURL.baseURL, "the stored URL must not keep a base to resolve against")
        XCTAssertEqual(RemoteHeader.parse(fromContent: header.line + "\n"), header)
    }

    // MARK: - Serialization

    func testTheSerializedLineSpellsOutTheDefaultInterval() throws {
        let header = try XCTUnwrap(RemoteHeader(sourceURL: url))

        XCTAssertEqual(header.line, "#!hostflip-remote https://example.com/hosts.txt interval=24h")
    }

    func testSerializeThenParseRoundTripsEveryInterval() throws {
        for interval in RemoteHeader.RefreshInterval.allCases {
            let header = try XCTUnwrap(RemoteHeader(sourceURL: url, interval: interval))
            XCTAssertEqual(RemoteHeader.parse(fromContent: header.line + "\n"), header)
        }
    }

    // MARK: - Stored content assembly

    func testStoredContentPutsTheHeaderLineAboveTheFetchedContent() throws {
        let header = try XCTUnwrap(RemoteHeader(sourceURL: url, interval: .sixHours))

        let stored = header.storedContent(forFetched: "1.2.3.4 a.example.com\n")

        XCTAssertEqual(
            stored,
            "#!hostflip-remote https://example.com/hosts.txt interval=6h\n1.2.3.4 a.example.com\n"
        )
        XCTAssertEqual(RemoteHeader.parse(fromContent: stored), header)
    }

    func testStoredContentEscapesAFetchedEmbeddedHeader() throws {
        let header = try XCTUnwrap(RemoteHeader(sourceURL: url, interval: .oneHour))
        let fetched = "#!hostflip-remote https://other.example.com/hosts.txt\n1.2.3.4 a.example.com\n"

        let stored = header.storedContent(forFetched: fetched)

        XCTAssertEqual(RemoteHeader.parse(fromContent: stored), header)
        XCTAssertTrue(stored.contains("# #!hostflip-remote https://other.example.com/hosts.txt"))
    }

    func testStoredContentOfAnEmptyFetchIsJustTheHeaderLine() throws {
        let header = try XCTUnwrap(RemoteHeader(sourceURL: url))

        XCTAssertEqual(header.storedContent(forFetched: ""), header.line + "\n")
    }

    // MARK: - Escaping

    func testEscapingCommentsOutALeadingHeaderLine() {
        let fetched = "#!hostflip-remote https://other.example.com/hosts.txt interval=1h\n1.2.3.4 a.example.com\n"

        let escaped = RemoteHeader.escapingEmbeddedHeader(in: fetched)

        XCTAssertEqual(
            escaped,
            "# #!hostflip-remote https://other.example.com/hosts.txt interval=1h\n1.2.3.4 a.example.com\n"
        )
        XCTAssertNil(RemoteHeader.parse(fromContent: escaped), "escaped content must no longer read as remote")
    }

    func testEscapingLeavesOrdinaryContentUntouched() {
        XCTAssertEqual(RemoteHeader.escapingEmbeddedHeader(in: "127.0.0.1 localhost\n"), "127.0.0.1 localhost\n")
        XCTAssertEqual(RemoteHeader.escapingEmbeddedHeader(in: ""), "")
    }

    func testEscapingLeavesAMalformedTokenLineUntouched() {
        // A malformed token line cannot flip the profile back to remote, so it stays verbatim.
        let malformed = "#!hostflip-remote http://example.com/hosts.txt\n"

        XCTAssertEqual(RemoteHeader.escapingEmbeddedHeader(in: malformed), malformed)
    }

    // MARK: - Profile identity

    func testAProfileWhoseContentStartsWithAHeaderIsRemote() {
        let profile = Profile(
            id: .init("remote"),
            name: "Remote",
            content: "#!hostflip-remote https://example.com/hosts.txt interval=6h\n1.2.3.4 a.example.com\n"
        )

        XCTAssertTrue(profile.isRemote)
        XCTAssertEqual(profile.remoteHeader, RemoteHeader(sourceURL: url, interval: .sixHours))
    }

    func testAnOrdinaryProfileIsNotRemote() {
        let profile = Profile(id: .init("local"), name: "Local", content: "127.0.0.1 localhost\n")

        XCTAssertFalse(profile.isRemote)
        XCTAssertNil(profile.remoteHeader)
    }

    // MARK: - Stored body

    func testStoredBodyReturnsTheContentBelowTheHeaderLine() {
        let stored = RemoteHeader(sourceURL: url, interval: .sixHours)!
            .storedContent(forFetched: "1.2.3.4 a.example.com\n")

        XCTAssertEqual(RemoteHeader.storedBody(of: stored), "1.2.3.4 a.example.com\n")
    }

    func testStoredBodyIsNilWithoutARemoteHeader() {
        XCTAssertNil(RemoteHeader.storedBody(of: "127.0.0.1 localhost\n"))
    }

    func testStoredBodyOfAHeaderOnlyContentIsEmpty() {
        XCTAssertEqual(RemoteHeader.storedBody(of: RemoteHeader(sourceURL: url)!.line), "")
    }

    func testStoredBodyRoundTripsTheEscapedFetch() {
        // Refresh compares the stored body against the escaped incoming fetch, so the two
        // forms must agree even when the fetch itself needed embedded-header escaping.
        let fetched = RemoteHeader(sourceURL: url)!.line + "\nbody\n"
        let stored = RemoteHeader(sourceURL: url)!.storedContent(forFetched: fetched)

        XCTAssertEqual(
            RemoteHeader.storedBody(of: stored),
            RemoteHeader.escapingEmbeddedHeader(in: fetched)
        )
    }
}
