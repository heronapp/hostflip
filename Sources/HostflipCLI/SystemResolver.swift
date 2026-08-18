import Darwin
import Foundation

/// What one system-resolver lookup produced, as an application using getaddrinfo sees it.
enum ResolverReply: Equatable, Sendable {
    /// Numeric addresses in the exact order the resolver returned them. The system applies
    /// RFC 6724 address sorting, so with mixed v4/v6 this order is not the hosts file order
    /// (the #66 measurement) — callers must never treat the first entry as a winner.
    case addresses([String])
    /// The resolver answered that the name has no addresses.
    case noSuchHost
    /// The query itself failed (resolver unreachable, interrupted, …).
    case failed(String)
}

/// The production resolver behind `doctor`'s fourth layer: plain getaddrinfo against the
/// system resolver, the same path every application takes. No service is requested and
/// stream sockets are hinted so each address appears once; no upstream DNS server is ever
/// contacted directly.
enum SystemResolver {
    static func query(_ hostname: String) -> ResolverReply {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        var list: UnsafeMutablePointer<addrinfo>?
        let status = getaddrinfo(hostname, nil, &hints, &list)
        guard status == 0 else {
            if status == EAI_NONAME || status == EAI_NODATA {
                return .noSuchHost
            }
            // EAI_SYSTEM parks the real cause in errno; read it before any other libc call.
            if status == EAI_SYSTEM {
                return .failed(String(cString: gai_strerror(status)) + ": " + String(cString: strerror(errno)))
            }
            return .failed(String(cString: gai_strerror(status)))
        }
        defer { freeaddrinfo(list) }

        var addresses: [String] = []
        var node = list
        while let current = node {
            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let rendered = getnameinfo(
                current.pointee.ai_addr,
                current.pointee.ai_addrlen,
                &buffer,
                socklen_t(buffer.count),
                nil,
                0,
                NI_NUMERICHOST
            )
            // A render failure fails the whole reply: a partial address set would read as a
            // false mismatch downstream, which is worse than an honest query failure.
            guard rendered == 0 else {
                return .failed("getnameinfo: " + String(cString: gai_strerror(rendered)))
            }
            addresses.append(CBuffer.string(buffer))
            node = current.pointee.ai_next
        }
        return addresses.isEmpty ? .noSuchHost : .addresses(addresses)
    }
}

/// Decodes a NUL-terminated C char buffer (inet_ntop, getnameinfo output) into a String.
enum CBuffer {
    static func string(_ buffer: [CChar]) -> String {
        String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}
