import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The user-entered dashboard address, normalised.
///
/// Mirrors the desktop app's handling (`apps/desktop/.../connection-config.ts`):
/// a bare `host:port` gets `http://`, query and fragment are dropped, a path
/// prefix (reverse proxy) is kept, and the trailing slash is removed.
public struct GatewayEndpoint: Sendable, Hashable, Codable {
    /// `http(s)://host[:port][/prefix]` without trailing slash.
    public let baseURL: URL

    public enum Error: Swift.Error, Equatable {
        case invalidURL(String)
        case unsupportedScheme(String)
    }

    public init(_ string: String) throws {
        var text = string.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.contains("://") { text = "http://" + text }
        guard var components = URLComponents(string: text), let host = components.host, !host.isEmpty else {
            throw Error.invalidURL(string)
        }
        let scheme = components.scheme?.lowercased() ?? "http"
        switch scheme {
        case "http", "https": components.scheme = scheme
        case "ws": components.scheme = "http"
        case "wss": components.scheme = "https"
        default: throw Error.unsupportedScheme(scheme)
        }
        components.query = nil
        components.fragment = nil
        components.user = nil
        components.password = nil
        while components.path.hasSuffix("/") { components.path.removeLast() }
        guard let url = components.url else { throw Error.invalidURL(string) }
        self.baseURL = url
    }

    public var isSecure: Bool { baseURL.scheme == "https" }

    /// An HTTP(S) URL for a dashboard path such as `/api/status`.
    public func url(path: String, query: [URLQueryItem] = []) -> URL {
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
        components.path += path.hasPrefix("/") ? path : "/" + path
        if !query.isEmpty { components.queryItems = query }
        return components.url!
    }

    /// `ws(s)://host[/prefix]/api/ws?<query>`.
    public func webSocketURL(query: [URLQueryItem]) -> URL {
        var components = URLComponents(url: url(path: "/api/ws", query: query), resolvingAgainstBaseURL: false)!
        components.scheme = isSecure ? "wss" : "ws"
        // `+` is legal in query values but some servers decode it as space.
        components.percentEncodedQuery = components.percentEncodedQuery?
            .replacingOccurrences(of: "+", with: "%2B")
        return components.url!
    }
}
