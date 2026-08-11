@testable import Hostflip
import XCTest

final class GitHubReleaseClientTests: XCTestCase {
    func testLatestReleaseRequestsGitHubLatestReleaseAndDecodesResponse() async throws {
        let recorder = RequestRecorder()
        let response = Data(#"{"tag_name":"v1.2.3","html_url":"https://github.com/heronapp/hostflip/releases/tag/v1.2.3"}"#.utf8)
        let client = GitHubReleaseClient { request in
            await recorder.record(request)
            return (response, 200)
        }

        let release = try await client.latestRelease()

        let request = await recorder.lastRequest()
        XCTAssertEqual(
            request?.url?.absoluteString,
            "https://api.github.com/repos/heronapp/hostflip/releases/latest"
        )
        XCTAssertEqual(request?.value(forHTTPHeaderField: "Accept"), "application/vnd.github+json")
        XCTAssertEqual(release.version, "v1.2.3")
        XCTAssertEqual(
            release.pageURL.absoluteString,
            "https://github.com/heronapp/hostflip/releases/tag/v1.2.3"
        )
    }
}

private actor RequestRecorder {
    private var request: URLRequest?

    func record(_ request: URLRequest) {
        self.request = request
    }

    func lastRequest() -> URLRequest? {
        request
    }
}
