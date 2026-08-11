import Foundation

struct GitHubReleaseClient: Sendable {
    typealias Loader = @Sendable (URLRequest) async throws -> (Data, Int)

    private static let latestReleaseURL = URL(
        string: "https://api.github.com/repos/heronapp/hostflip/releases/latest"
    )!

    private let load: Loader

    init() {
        load = { request in
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let response = response as? HTTPURLResponse else {
                throw GitHubReleaseClientError.invalidResponse
            }
            return (data, response.statusCode)
        }
    }

    init(_ load: @escaping Loader) {
        self.load = load
    }

    func latestRelease() async throws -> GitHubRelease {
        var request = URLRequest(url: Self.latestReleaseURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("hostflip-update-check", forHTTPHeaderField: "User-Agent")

        let (data, statusCode) = try await load(request)
        guard statusCode == 200 else {
            throw GitHubReleaseClientError.httpStatus(statusCode)
        }
        let response = try JSONDecoder().decode(LatestReleaseResponse.self, from: data)
        return GitHubRelease(version: response.tagName, pageURL: response.pageURL)
    }
}

private struct LatestReleaseResponse: Decodable {
    let tagName: String
    let pageURL: URL

    private enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case pageURL = "html_url"
    }
}

private enum GitHubReleaseClientError: LocalizedError {
    case invalidResponse
    case httpStatus(Int)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            "GitHub returned an invalid response."
        case .httpStatus(let statusCode):
            "GitHub returned HTTP \(statusCode)."
        }
    }
}
