import Foundation
import XCTest
@testable import HostflipCore

/// The fetch engine's HTTPS discipline and the three validation gates (ADR-0012): everything
/// the gates refuse must surface as a typed error, so creation and refresh fail with nothing
/// stored and the old content preserved.
final class RemoteFetcherTests: XCTestCase {
    private let url = URL(string: "https://example.com/hosts.txt")!

    /// Collects the URLRequests the transport receives; @unchecked because access is locked.
    private final class RequestRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var recorded: [URLRequest] = []

        func record(_ request: URLRequest) {
            lock.withLock { recorded.append(request) }
        }

        var requests: [URLRequest] {
            lock.withLock { recorded }
        }
    }

    private func fetcher(
        data: Data = Data("127.0.0.1 localhost\n".utf8),
        statusCode: Int = 200,
        finalURL: URL? = nil,
        headers: [String: String] = [:],
        recorder: RequestRecorder? = nil
    ) -> RemoteFetcher {
        RemoteFetcher(transport: { request in
            recorder?.record(request)
            let response = HTTPURLResponse(
                url: finalURL ?? request.url!,
                statusCode: statusCode,
                httpVersion: "HTTP/1.1",
                headerFields: headers
            )!
            return (data, response)
        })
    }

    private func assertFetch(
        _ fetcher: RemoteFetcher,
        throws expected: RemoteFetchError,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await fetcher.fetch(from: url)
            XCTFail("expected \(expected), but the fetch succeeded", file: file, line: line)
        } catch let error as RemoteFetchError {
            XCTAssertEqual(error, expected, file: file, line: line)
        } catch {
            XCTFail("expected \(expected), got \(error)", file: file, line: line)
        }
    }

    // MARK: - Success

    func testFetchingReturnsTheDecodedContentVerbatim() async throws {
        let content = "# GitHub520\n140.82.112.4 github.com\n"

        let fetched = try await fetcher(data: Data(content.utf8)).fetch(from: url)

        XCTAssertEqual(fetched, content)
    }

    func testHostsContentMentioningHTMLIsNotRefused() async throws {
        let content = "# mirror of <html> block lists\n127.0.0.1 html.example.com\n"

        let fetched = try await fetcher(data: Data(content.utf8)).fetch(from: url)

        XCTAssertEqual(fetched, content)
    }

    // MARK: - HTTPS discipline

    func testANonHTTPSURLIsRefusedWithoutANetworkCall() async {
        let recorder = RequestRecorder()
        let fetcher = fetcher(recorder: recorder)

        do {
            _ = try await fetcher.fetch(from: URL(string: "http://example.com/hosts.txt")!)
            XCTFail("an http URL must be refused")
        } catch {
            XCTAssertEqual(error as? RemoteFetchError, .notHTTPS)
        }
        XCTAssertEqual(recorder.requests, [], "the request must be refused before any transport call")
    }

    func testARedirectLandingOnHTTPIsRefused() async {
        let fetcher = fetcher(finalURL: URL(string: "http://insecure.example.com/hosts.txt")!)

        await assertFetch(fetcher, throws: .insecureRedirect)
    }

    func testARedirectLandingOnAnotherHTTPSURLIsAccepted() async throws {
        let fetcher = fetcher(finalURL: URL(string: "https://cdn.example.net/hosts.txt")!)

        _ = try await fetcher.fetch(from: url)
    }

    func testARefusedRedirectStatusIsReportedAsInsecure() async {
        // The production transport's RedirectPolicy follows every secure hop, so a redirect
        // status surviving to the response means an insecure hop was refused mid-chain.
        await assertFetch(fetcher(statusCode: 302), throws: .insecureRedirect)
    }

    // MARK: - Transport failures

    func testANonSuccessStatusIsRefused() async {
        await assertFetch(fetcher(statusCode: 404), throws: .httpStatus(404))
    }

    func testATransportErrorSurfacesAsRequestFailed() async {
        let fetcher = RemoteFetcher(transport: { _ in throw URLError(.timedOut) })

        do {
            _ = try await fetcher.fetch(from: url)
            XCTFail("a transport error must surface")
        } catch let error as RemoteFetchError {
            guard case .requestFailed = error else {
                return XCTFail("expected requestFailed, got \(error)")
            }
        } catch {
            XCTFail("expected requestFailed, got \(error)")
        }
    }

    func testATypedTransportRefusalPassesThroughUnblurred() async {
        // The production transport enforces the size cap mid-stream; its typed refusal must
        // reach the caller as tooLarge, not be wrapped into requestFailed.
        let fetcher = RemoteFetcher(transport: { _ in
            throw RemoteFetchError.tooLarge(byteCount: 987)
        })

        await assertFetch(fetcher, throws: .tooLarge(byteCount: 987))
    }

    func testANonHTTPResponseIsRefused() async {
        let fetcher = RemoteFetcher(transport: { request in
            (Data(), URLResponse(url: request.url!, mimeType: nil, expectedContentLength: 0, textEncodingName: nil))
        })

        do {
            _ = try await fetcher.fetch(from: url)
            XCTFail("a non-HTTP response must be refused")
        } catch let error as RemoteFetchError {
            guard case .requestFailed = error else {
                return XCTFail("expected requestFailed, got \(error)")
            }
        } catch {
            XCTFail("expected requestFailed, got \(error)")
        }
    }

    func testTheRequestUsesTheThirtySecondTimeout() async throws {
        let recorder = RequestRecorder()

        _ = try await fetcher(recorder: recorder).fetch(from: url)

        XCTAssertEqual(recorder.requests.map(\.timeoutInterval), [30])
    }

    // MARK: - Gate: size

    func testContentAtTheSizeLimitPasses() async throws {
        let data = Data(repeating: UInt8(ascii: "a"), count: RemoteFetcher.maximumByteCount)

        _ = try await fetcher(data: data).fetch(from: url)
    }

    func testContentOneByteOverTheSizeLimitIsRefused() async {
        let count = RemoteFetcher.maximumByteCount + 1
        let data = Data(repeating: UInt8(ascii: "a"), count: count)

        await assertFetch(fetcher(data: data), throws: .tooLarge(byteCount: count))
    }

    // MARK: - Gate: UTF-8

    func testUndecodableContentIsRefused() async {
        await assertFetch(fetcher(data: Data([0xFF, 0xFE, 0x00])), throws: .notUTF8)
    }

    func testControlCharacterContentIsRefused() async {
        // Valid UTF-8, but not hosts text: NUL padding and stray control characters must not
        // reach /etc/hosts.
        await assertFetch(fetcher(data: Data([0x00, 0x00, 0x00])), throws: .notUTF8)
        await assertFetch(
            fetcher(data: Data("1.2.3.4 a\u{07}.example.com\n".utf8)),
            throws: .notUTF8
        )
    }

    func testTabAndCRLFWhitespaceIsAccepted() async throws {
        let content = "1.2.3.4\ta.example.com\r\n# comment\n"

        let fetched = try await fetcher(data: Data(content.utf8)).fetch(from: url)

        XCTAssertEqual(fetched, content)
    }

    // MARK: - Gate: HTML sniff

    func testAnHTMLDocumentIsRefused() async {
        for body in [
            "<!DOCTYPE html><html><body>404 Not Found</body></html>",
            "<html lang=\"en\"><head><title>Error</title></head></html>",
            "\n\t <html><body>login required</body></html>",
            "\u{FEFF}<!doctype html><html></html>",
            "<head><meta charset=\"utf-8\"></head>",
            "<body>blocked</body>",
            "<script>window.location = \"/login\"</script>",
            "<title>404 Not Found</title>",
            "<!-- maintenance page -->",
            "<?xml version=\"1.0\"?><error/>",
        ] {
            await assertFetch(fetcher(data: Data(body.utf8)), throws: .looksLikeHTML)
        }
    }

    func testAnHTMLContentTypeIsRefusedEvenWithoutMarkup() async {
        let fetcher = fetcher(
            data: Data("127.0.0.1 localhost\n".utf8),
            headers: ["Content-Type": "text/html; charset=utf-8"]
        )

        await assertFetch(fetcher, throws: .looksLikeHTML)
    }

    // MARK: - Conditional requests (#71)

    func testStoredValidatorsAreSentAsConditionalHeaders() async throws {
        let recorder = RequestRecorder()
        let fetcher = fetcher(recorder: recorder)

        _ = try await fetcher.fetch(
            from: url,
            validators: RemoteContentValidators(
                etag: "\"abc123\"",
                lastModified: "Mon, 17 Aug 2026 00:00:00 GMT"
            )
        )

        let request = try XCTUnwrap(recorder.requests.first)
        XCTAssertEqual(request.value(forHTTPHeaderField: "If-None-Match"), "\"abc123\"")
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "If-Modified-Since"),
            "Mon, 17 Aug 2026 00:00:00 GMT"
        )
    }

    func testAFetchWithoutValidatorsSendsNoConditionalHeaders() async throws {
        let recorder = RequestRecorder()

        _ = try await fetcher(recorder: recorder).fetch(from: url)

        let request = try XCTUnwrap(recorder.requests.first)
        XCTAssertNil(request.value(forHTTPHeaderField: "If-None-Match"))
        XCTAssertNil(request.value(forHTTPHeaderField: "If-Modified-Since"))
    }

    func testA304AnswerToAConditionalFetchReportsNotModified() async throws {
        let fetcher = fetcher(data: Data(), statusCode: 304)

        let outcome = try await fetcher.fetch(
            from: url,
            validators: RemoteContentValidators(etag: "\"abc123\"")
        )

        XCTAssertEqual(outcome, .notModified(validators: nil))
    }

    func testA304CarryingRefreshedValidatorsPassesThemAlong() async throws {
        // RFC 7232 lets a 304 resend (or update) the validators; they must reach the caller
        // so the stored ones can be replaced.
        let fetcher = fetcher(
            data: Data(),
            statusCode: 304,
            headers: ["ETag": "\"abc124\""]
        )

        let outcome = try await fetcher.fetch(
            from: url,
            validators: RemoteContentValidators(etag: "\"abc123\"")
        )

        XCTAssertEqual(
            outcome,
            .notModified(validators: RemoteContentValidators(etag: "\"abc124\""))
        )
    }

    func testA304WithoutSentValidatorsIsAnHTTPFailure() async {
        // Nothing conditional was asked for, so a 304 is the server misbehaving, not
        // a "content unchanged" answer; empty validators send no conditional headers.
        await assertFetch(fetcher(statusCode: 304), throws: .httpStatus(304))
        do {
            _ = try await fetcher(statusCode: 304)
                .fetch(from: url, validators: RemoteContentValidators())
            XCTFail("a 304 without conditional headers must be refused")
        } catch {
            XCTAssertEqual(error as? RemoteFetchError, .httpStatus(304))
        }
    }

    func testA304LandingOnHTTPIsStillRefusedAsInsecure() async {
        // The HTTPS discipline outranks the conditional shortcut: an insecure landing is
        // reported as the security refusal even when the status says "not modified".
        let fetcher = fetcher(
            statusCode: 304,
            finalURL: URL(string: "http://insecure.example.com/hosts.txt")!
        )

        do {
            _ = try await fetcher.fetch(
                from: url,
                validators: RemoteContentValidators(etag: "\"abc123\"")
            )
            XCTFail("an insecure landing must be refused")
        } catch {
            XCTAssertEqual(error as? RemoteFetchError, .insecureRedirect)
        }
    }

    func testResponseValidatorsAreCapturedWithTheContent() async throws {
        let content = "127.0.0.1 localhost\n"
        let fetcher = fetcher(
            data: Data(content.utf8),
            headers: [
                "ETag": "W/\"abc123\"",
                "Last-Modified": "Mon, 17 Aug 2026 00:00:00 GMT",
            ]
        )

        let outcome = try await fetcher.fetch(from: url, validators: nil)

        XCTAssertEqual(
            outcome,
            .content(
                content,
                validators: RemoteContentValidators(
                    etag: "W/\"abc123\"",
                    lastModified: "Mon, 17 Aug 2026 00:00:00 GMT"
                )
            )
        )
    }

    func testAResponseWithoutValidatorsYieldsNilValidators() async throws {
        let content = "127.0.0.1 localhost\n"

        let outcome = try await fetcher(data: Data(content.utf8)).fetch(from: url, validators: nil)

        XCTAssertEqual(outcome, .content(content, validators: nil))
    }

    // MARK: - Validator merging after a 304 (#71)

    func testMergingKeepsStoredFieldsA304DidNotResend() {
        // RFC 7232 lets a 304 resend any subset of the validators: fields it carried
        // replace the stored ones, fields it omitted keep their stored values.
        let stored = RemoteContentValidators(
            etag: "\"abc123\"",
            lastModified: "Mon, 17 Aug 2026 00:00:00 GMT"
        )

        XCTAssertEqual(
            RemoteContentValidators.merged(
                stored: stored,
                refreshed: RemoteContentValidators(etag: "\"abc124\"")
            ),
            RemoteContentValidators(
                etag: "\"abc124\"",
                lastModified: "Mon, 17 Aug 2026 00:00:00 GMT"
            )
        )
    }

    func testMergingWithoutARefreshedAnswerKeepsTheStoredValidators() {
        let stored = RemoteContentValidators(etag: "\"abc123\"")

        XCTAssertEqual(RemoteContentValidators.merged(stored: stored, refreshed: nil), stored)
    }

    func testMergingNothingYieldsNil() {
        XCTAssertNil(RemoteContentValidators.merged(stored: nil, refreshed: nil))
        XCTAssertNil(
            RemoteContentValidators.merged(stored: RemoteContentValidators(), refreshed: nil)
        )
    }

    // MARK: - Real-network end-to-end (opt-in)

    /// The end-to-end path with a real Source URL: fetch → assemble → activate → the merge
    /// output carries the header provenance line. Opt-in because CI and `swift test` must not
    /// depend on the network: HOSTFLIP_NETWORK_TESTS=1 swift test --filter RemoteFetcherTests
    func testFetchingARealURLEndToEndProducesAMergeWithProvenance() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["HOSTFLIP_NETWORK_TESTS"] == "1",
            "network tests are opt-in via HOSTFLIP_NETWORK_TESTS=1"
        )
        let textURL = try XCTUnwrap(URL(
            string: "https://raw.githubusercontent.com/StevenBlack/hosts/master/license.txt"
        ))

        let fetched = try await RemoteFetcher().fetch(from: textURL)
        XCTAssertFalse(fetched.isEmpty)

        let header = try XCTUnwrap(RemoteHeader(sourceURL: textURL, interval: .manual))
        var model = try ActivationModel(
            baseHosts: BaseHosts(content: "127.0.0.1 localhost\n"),
            standaloneProfiles: [],
            groups: []
        )
        let profileID = Profile.ID("remote-e2e")
        try model.addProfile(id: profileID, name: "Remote E2E", content: header.storedContent(forFetched: fetched))
        try model.toggleProfile(profileID)

        XCTAssertTrue(model.mergedHosts.content.contains(header.line))
    }
}
