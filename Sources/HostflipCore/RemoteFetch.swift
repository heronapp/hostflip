import Foundation

/// Why a Remote Profile fetch was refused: the transport-level failures plus the three
/// validation gates of ADR-0012 — UTF-8 decodable, at most 10 MB, and not an HTML page.
public enum RemoteFetchError: Error, Equatable, Sendable {
    /// The requested URL is not HTTPS with a host; refused before any network activity.
    case notHTTPS
    /// Redirects were followed, but the redirect chain did not land on an HTTPS URL.
    case insecureRedirect
    /// The transport failed (DNS, TLS, timeout…); carries display copy for the failure.
    case requestFailed(String)
    /// The server answered with a non-success HTTP status.
    case httpStatus(Int)
    /// The fetched body exceeds `RemoteFetcher.maximumByteCount`.
    case tooLarge(byteCount: Int)
    /// The fetched body is not decodable as UTF-8 text.
    case notUTF8
    /// The fetched body is an HTML page — a "200 with an error page" response (ADR-0012).
    case looksLikeHTML
}

/// The cache validators of a fetched body, stored with the refresh state so the next fetch can
/// be conditional (#71): the ETag and Last-Modified values are opaque strings echoed back as
/// If-None-Match and If-Modified-Since, letting an unchanged source answer 304 instead of a
/// full download. Deliberately discardable alongside the rest of `RemoteRefreshState` — losing
/// them costs one full download, never the Remote Profile's identity.
public struct RemoteContentValidators: Codable, Equatable, Sendable {
    public var etag: String?
    public var lastModified: String?

    public init(etag: String? = nil, lastModified: String? = nil) {
        self.etag = etag
        self.lastModified = lastModified
    }

    /// The validators to store after a 304: RFC 7232 lets the answer resend any subset, so
    /// fields it carried replace the stored ones while fields it omitted keep their stored
    /// values — a partial answer must not erase the other validator. Nil when no field
    /// survives on either side.
    public static func merged(
        stored: RemoteContentValidators?,
        refreshed: RemoteContentValidators?
    ) -> RemoteContentValidators? {
        let etag = refreshed?.etag ?? stored?.etag
        let lastModified = refreshed?.lastModified ?? stored?.lastModified
        guard etag != nil || lastModified != nil else { return nil }
        return RemoteContentValidators(etag: etag, lastModified: lastModified)
    }
}

/// What a conditional fetch concluded: new validated content (with the validators to store for
/// the next fetch), or the server's 304 answer that the stored content is still current. A 304
/// may itself carry refreshed validators (RFC 7232 encourages resending the ETag); nil means
/// the answer carried none and the stored ones remain right.
public enum RemoteFetchOutcome: Equatable, Sendable {
    case content(String, validators: RemoteContentValidators?)
    case notModified(validators: RemoteContentValidators?)
}

/// The Remote Profile fetch engine (ADR-0012): downloads a Source URL's content and applies the
/// validation gates before anything may be stored. HTTPS-only at both ends — the requested URL
/// and the redirect chain's final URL must satisfy the Source URL predicate — because the fetch
/// result is ultimately written to /etc/hosts as root. No authentication in v1; conditional
/// requests via stored validators (#71). Lives in HostflipCore so the app and the CLI share one
/// engine (ADR-0009).
public struct RemoteFetcher: Sendable {
    public static let maximumByteCount = 10 * 1024 * 1024
    /// Applied as both the idle and the total-transfer ceiling: a trickling server must not
    /// keep a fetch (and the creation dialog showing it) alive past this.
    public static let timeout: TimeInterval = 30

    /// Transport seam: production is a URLSession; tests inject canned responses.
    private let transport: @Sendable (URLRequest) async throws -> (Data, URLResponse)

    /// One shared production session: URLSession instances are only released by invalidation,
    /// so a session per fetch would accumulate. Ephemeral configuration plus ignoring local
    /// cache data keeps fetches free of cache and cookie residue — a cached body would mask
    /// the server's current content on a Refresh.
    private static let productionSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        return URLSession(configuration: configuration)
    }()

    /// Refuses any redirect hop that leaves HTTPS before its request is ever issued: checking
    /// only the landing URL would let an https → http → https chain route the fetch through a
    /// tamperable plaintext hop, and would send one plaintext request even for a plain
    /// https → http redirect. A refused hop returns the 3xx response itself, which `fetch`
    /// reports as `insecureRedirect`.
    private final class RedirectPolicy: NSObject, URLSessionTaskDelegate {
        func urlSession(
            _ session: URLSession,
            task: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest,
            completionHandler: @escaping (URLRequest?) -> Void
        ) {
            if let target = request.url, RemoteHeader.isValidSourceURL(target) {
                completionHandler(request)
            } else {
                completionHandler(nil)
            }
        }
    }

    private static let redirectPolicy = RedirectPolicy()

    public init() {
        // Streamed, not data(for:): the size gate must stop an oversized body while it
        // arrives, not buffer gigabytes first and reject afterwards. fetch's own gate stays
        // as the tested contract; this cap is what makes it hold for real transfers.
        self.init(transport: { request in
            let (bytes, response) = try await Self.productionSession.bytes(
                for: request,
                delegate: Self.redirectPolicy
            )
            if response.expectedContentLength > Int64(Self.maximumByteCount) {
                throw RemoteFetchError.tooLarge(byteCount: Int(response.expectedContentLength))
            }
            var body = Data()
            if response.expectedContentLength > 0 {
                body.reserveCapacity(min(Int(response.expectedContentLength), Self.maximumByteCount))
            }
            for try await byte in bytes {
                body.append(byte)
                if body.count > Self.maximumByteCount {
                    throw RemoteFetchError.tooLarge(byteCount: body.count)
                }
            }
            return (body, response)
        })
    }

    init(transport: @escaping @Sendable (URLRequest) async throws -> (Data, URLResponse)) {
        self.transport = transport
    }

    /// Fetches and validates the content behind a Source URL. Every refusal throws a
    /// `RemoteFetchError`; the content is only ever returned once all gates passed, so callers
    /// can treat the return value as safe to store. The unconditional entry point for callers
    /// that must end up with content (the creation and edit dialogs).
    public func fetch(from url: URL) async throws -> String {
        guard case .content(let text, _) = try await fetch(from: url, validators: nil) else {
            // Unreachable: without conditional headers a 304 is refused as its status code.
            throw RemoteFetchError.httpStatus(304)
        }
        return text
    }

    /// The conditional variant (#71): stored validators are echoed back as If-None-Match and
    /// If-Modified-Since, and the server's 304 answer surfaces as `.notModified` — nothing was
    /// downloaded, the stored content is current. New content passes the same gates as an
    /// unconditional fetch and carries the response's validators for the next fetch.
    public func fetch(
        from url: URL,
        validators: RemoteContentValidators?
    ) async throws -> RemoteFetchOutcome {
        guard RemoteHeader.isValidSourceURL(url) else {
            throw RemoteFetchError.notHTTPS
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = Self.timeout
        if let etag = validators?.etag {
            request.setValue(etag, forHTTPHeaderField: "If-None-Match")
        }
        if let lastModified = validators?.lastModified {
            request.setValue(lastModified, forHTTPHeaderField: "If-Modified-Since")
        }
        let sentConditionalHeaders = validators?.etag != nil || validators?.lastModified != nil
        let body: Data
        let response: URLResponse
        do {
            (body, response) = try await transport(request)
        } catch let error as RemoteFetchError {
            // The production transport enforces the size cap mid-stream; its refusal is
            // already typed and must not be blurred into requestFailed.
            throw error
        } catch {
            throw RemoteFetchError.requestFailed(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            // Foundation's own (localized) copy: this string reaches UI error messages.
            throw RemoteFetchError.requestFailed(URLError(.badServerResponse).localizedDescription)
        }

        // Secure redirects are followed by the transport; the landing URL must satisfy the
        // same predicate as the requested one — checked before the status so an insecure
        // landing is reported as the security refusal it is, not as its status code.
        guard let finalURL = http.url, RemoteHeader.isValidSourceURL(finalURL) else {
            throw RemoteFetchError.insecureRedirect
        }
        // Only an answer to a conditional question reads as "not modified": a 304 to a plain
        // fetch is the server misbehaving and falls through to the status refusal below.
        if http.statusCode == 304, sentConditionalHeaders {
            return .notModified(validators: Self.validators(of: http))
        }
        guard (200...299).contains(http.statusCode) else {
            // A redirect status can only surface here when the transport's RedirectPolicy
            // refused to follow it (an insecure hop): every secure redirect was followed.
            // Except 304 — never a redirect, just an answer no unconditional fetch asked for.
            if (300...399).contains(http.statusCode), http.statusCode != 304 {
                throw RemoteFetchError.insecureRedirect
            }
            throw RemoteFetchError.httpStatus(http.statusCode)
        }

        guard body.count <= Self.maximumByteCount else {
            throw RemoteFetchError.tooLarge(byteCount: body.count)
        }
        // Decodable as UTF-8, and free of control characters beyond line and tab whitespace:
        // all-NUL and similar binary payloads decode as UTF-8 yet are not hosts text, and
        // must not reach /etc/hosts.
        guard let text = String(data: body, encoding: .utf8),
              !text.unicodeScalars.contains(where: { scalar in
                  (scalar.value < 0x20 || scalar.value == 0x7F)
                      && scalar != "\t" && scalar != "\n" && scalar != "\r"
              })
        else {
            throw RemoteFetchError.notUTF8
        }
        guard !Self.looksLikeHTML(text, contentType: http.value(forHTTPHeaderField: "Content-Type")) else {
            throw RemoteFetchError.looksLikeHTML
        }
        return .content(text, validators: Self.validators(of: http))
    }

    /// The response's cache validators, nil when it declares none.
    private static func validators(of http: HTTPURLResponse) -> RemoteContentValidators? {
        let etag = http.value(forHTTPHeaderField: "ETag")
        let lastModified = http.value(forHTTPHeaderField: "Last-Modified")
        guard etag != nil || lastModified != nil else { return nil }
        return RemoteContentValidators(etag: etag, lastModified: lastModified)
    }

    /// The HTML gate blocks documents, not mentions: a declared text/html content type, or a
    /// body opening with one of the ways an HTML or XML document starts (WHATWG-style
    /// sniffing, plus comment and XML-declaration openers). Hosts lines begin with an address
    /// or `#`, so nothing legitimate starts with a tag.
    private static let documentOpeners = [
        "<!doctype", "<html", "<head", "<body", "<script", "<title", "<style", "<meta",
        "<!--", "<?xml",
    ]

    private static func looksLikeHTML(_ text: String, contentType: String?) -> Bool {
        if contentType?.lowercased().contains("text/html") == true {
            return true
        }
        let lead = text
            .drop(while: { $0.isWhitespace || $0 == "\u{FEFF}" })
            .prefix(16)
            .lowercased()
        return documentOpeners.contains { lead.hasPrefix($0) }
    }
}
