import Foundation
import HermesProtocol

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Public subset of `GET /api/status` (`hermes_cli/web_routers/status.py`).
public struct DashboardStatus: Sendable, Hashable, Codable {
    public var version: String?
    public var releaseDate: String?
    /// True when the dashboard is gated by a session provider.
    public var authRequired: Bool?
    public var authProviders: [String]?
    /// `cookie` and/or `native_pkce`.
    public var authFlows: [String]?
    public var gatewayRunning: Bool?
    public var gatewayState: String?

    enum CodingKeys: String, CodingKey {
        case version
        case releaseDate = "release_date"
        case authRequired = "auth_required"
        case authProviders = "auth_providers"
        case authFlows = "auth_flows"
        case gatewayRunning = "gateway_running"
        case gatewayState = "gateway_state"
    }
}

/// A single-use WebSocket ticket from `POST /api/auth/ws-ticket` (30 s TTL).
public struct WebSocketTicket: Sendable, Hashable, Codable {
    public var ticket: String
    public var ttlSeconds: Int?

    enum CodingKeys: String, CodingKey {
        case ticket
        case ttlSeconds = "ttl_seconds"
    }
}

/// Tokens from `/auth/native/token` and `/auth/native/refresh`.
public struct NativeTokens: Sendable, Hashable, Codable {
    public var accessToken: String
    public var refreshToken: String
    public var tokenType: String?
    /// Unix seconds.
    public var expiresAt: Double?
    public var provider: String?
    public var userID: String?

    public init(accessToken: String, refreshToken: String, expiresAt: Double? = nil, provider: String? = nil) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.provider = provider
    }

    enum CodingKeys: String, CodingKey {
        case provider
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case tokenType = "token_type"
        case expiresAt = "expires_at"
        case userID = "user_id"
    }
}

public enum DashboardError: Error, Sendable, Equatable {
    /// 401: missing/expired credentials. `reason` from the JSON body when present.
    case unauthenticated(reason: String?)
    /// 401 from `/auth/password-login`: wrong username/password (`routes.py:430-432`).
    case invalidCredentials
    /// 401 from `/auth/native/refresh`: the refresh token expired or was
    /// revoked (`routes.py:544-547`). Retrying cannot help; sign in again.
    case refreshRejected
    /// 429 from the login rate limiter.
    case rateLimited
    case http(status: Int, body: String?)
    case invalidResponse(String)
}

/// HTTP calls against the Hermes dashboard (`hermes_cli/dashboard_auth/routes.py`).
public struct DashboardClient: Sendable {
    public let endpoint: GatewayEndpoint
    private let http: any HTTPClient

    public init(endpoint: GatewayEndpoint, http: any HTTPClient = URLSessionHTTPClient.ephemeral()) {
        self.endpoint = endpoint
        self.http = http
    }

    /// `GET /api/status` — public, used to discover whether auth is required.
    public func status() async throws -> DashboardStatus {
        try await send(request(path: "/api/status", method: "GET"))
    }

    /// `POST /auth/password-login` for password providers such as `basic`.
    /// The session arrives as `Set-Cookie` only; it lives in the HTTP
    /// client's cookie storage and authenticates later calls.
    public func passwordLogin(provider: String, username: String, password: String) async throws {
        let body: JSONValue = ["provider": .string(provider), "username": .string(username),
                               "password": .string(password), "next": ""]
        do {
            let _: JSONValue = try await send(request(path: "/auth/password-login", method: "POST", json: body))
        } catch DashboardError.unauthenticated {
            throw DashboardError.invalidCredentials
        }
    }

    /// `POST /api/auth/ws-ticket`. Authenticated by `bearer` when given,
    /// otherwise by the session cookie from `passwordLogin`.
    public func mintWebSocketTicket(bearer: String? = nil) async throws -> WebSocketTicket {
        var request = request(path: "/api/auth/ws-ticket", method: "POST")
        if let bearer { request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization") }
        return try await send(request)
    }

    // MARK: Native PKCE (RFC 8252)

    /// The browser URL that starts a native login. `redirectURI` must be a
    /// loopback `http://127.0.0.1:<port>/…` or `http://[::1]:<port>/…`
    /// address; the server rejects custom schemes.
    public func nativeAuthorizeURL(pkce: PKCE, redirectURI: String, state: String, provider: String? = nil) -> URL {
        var query = [
            URLQueryItem(name: "code_challenge", value: pkce.challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "state", value: state),
        ]
        if let provider { query.append(URLQueryItem(name: "provider", value: provider)) }
        return endpoint.url(path: "/auth/native/authorize", query: query)
    }

    /// `POST /auth/native/token`. The code is consumed even on failure.
    public func exchangeNativeCode(_ code: String, verifier: String) async throws -> NativeTokens {
        try await send(request(path: "/auth/native/token", method: "POST",
                               json: ["code": .string(code), "code_verifier": .string(verifier)]))
    }

    /// `POST /auth/native/refresh`. Returns a new pair; the old refresh
    /// token must not be used again. A rejected refresh token throws
    /// `DashboardError.refreshRejected`; an unreachable provider is a 503
    /// (`routes.py:519-547`). Prefer `NativeTokenSession`, which also
    /// prevents parallel refreshes.
    public func refreshNativeTokens(refreshToken: String, provider: String) async throws -> NativeTokens {
        do {
            return try await send(request(path: "/auth/native/refresh", method: "POST",
                                          json: ["refresh_token": .string(refreshToken), "provider": .string(provider)]))
        } catch DashboardError.unauthenticated {
            throw DashboardError.refreshRejected
        }
    }

    // MARK: Sessions

    /// `GET /api/sessions/{id}/messages`: one bounded page of a stored transcript
    /// (`hermes_cli/web_routers/sessions.py:685-729`). Authenticated by `bearer`
    /// when given, otherwise by the session cookie from `passwordLogin`.
    /// `include_compacted=true` keeps the turns in-place compaction archived;
    /// `inline_images=false` sends `[image]` instead of data URIs, which the
    /// apps do not show (`:636-646`).
    public func sessionMessages(_ query: SessionMessagesQuery, bearer: String? = nil) async throws -> SessionMessagesPage {
        var items = [
            URLQueryItem(name: "order", value: query.order.rawValue),
            URLQueryItem(name: "limit", value: String(query.limit)),
            URLQueryItem(name: "offset", value: String(query.offset)),
            URLQueryItem(name: "include_compacted", value: "true"),
            URLQueryItem(name: "inline_images", value: "false"),
        ]
        if let profile = query.profile { items.insert(URLQueryItem(name: "profile", value: profile), at: 0) }
        var request = request(path: "/api/sessions/\(query.sessionID)/messages", method: "GET", query: items)
        if let bearer { request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization") }
        return try await send(request)
    }

    // MARK: Media

    /// `GET /api/media?path=` answers `{data_url}` (`hermes_cli/web_routers/files.py:329-354`).
    public func mediaDataURL(path: String, bearer: String? = nil) async throws -> String {
        var request = request(path: "/api/media", method: "GET", query: [URLQueryItem(name: "path", value: path)])
        if let bearer { request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization") }
        let answer: MediaAnswer = try await send(request)
        guard let url = answer.dataURL ?? answer.dataUrl else { throw DashboardError.invalidResponse("no data_url") }
        return url
    }

    /// `GET /api/fs/read-data-url?path=&profile=` answers `{dataUrl}` (`files.py:901-922`).
    public func fileDataURL(path: String, profile: String?, bearer: String? = nil) async throws -> String {
        var query = [URLQueryItem(name: "path", value: path)]
        if let profile { query.append(URLQueryItem(name: "profile", value: profile)) }
        var request = request(path: "/api/fs/read-data-url", method: "GET", query: query)
        if let bearer { request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization") }
        let answer: MediaAnswer = try await send(request)
        guard let url = answer.dataUrl ?? answer.dataURL else { throw DashboardError.invalidResponse("no dataUrl") }
        return url
    }

    /// `GET /api/fs/download?path=&profile=&session_id=`: the file itself, streamed to a
    /// temporary file (`hermes_cli/web_routers/files.py:931-960`), as Desktop downloads a
    /// delivered file (`apps/desktop/electron/gateway-file-download.ts:100-112`). No size
    /// cap. `sessionID` is a stored session key: a relative `path` resolves against that
    /// session's folder (`_fs_download_path`, `files.py:891-901`).
    public func downloadFile(path: String, profile: String?, sessionID: String?, bearer: String? = nil) async throws -> URL {
        var query = [URLQueryItem(name: "path", value: path)]
        if let profile { query.append(URLQueryItem(name: "profile", value: profile)) }
        if let sessionID { query.append(URLQueryItem(name: "session_id", value: sessionID)) }
        var request = request(path: "/api/fs/download", method: "GET", query: query)
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 300
        if let bearer { request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization") }
        let (url, response) = try await http.download(for: request)
        switch response.statusCode {
        case 200..<300:
            return url
        default:
            let body = try? Data(contentsOf: url)
            try? FileManager.default.removeItem(at: url)
            switch response.statusCode {
            case 401:
                let json = body.flatMap { try? JSONDecoder().decode(JSONValue.self, from: $0) }
                throw DashboardError.unauthenticated(reason: json?["reason"]?.stringValue ?? json?["error"]?.stringValue)
            case 429: throw DashboardError.rateLimited
            default: throw DashboardError.http(status: response.statusCode, body: body.flatMap { String(data: $0, encoding: .utf8) })
            }
        }
    }

    private struct MediaAnswer: Decodable {
        var dataURL: String?
        var dataUrl: String?

        enum CodingKeys: String, CodingKey {
            case dataURL = "data_url"
            case dataUrl
        }
    }

    // MARK: Plumbing

    private func request(path: String, method: String, json: JSONValue? = nil,
                         query: [URLQueryItem] = []) -> URLRequest {
        var request = URLRequest(url: endpoint.url(path: path, query: query))
        request.httpMethod = method
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let json {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try? JSONEncoder().encode(json)
        }
        return request
    }

    private func send<T: Decodable>(_ request: URLRequest) async throws -> T {
        let (data, response) = try await http.data(for: request)
        switch response.statusCode {
        case 200..<300:
            do {
                return try JSONDecoder().decode(T.self, from: data)
            } catch {
                throw DashboardError.invalidResponse(String(describing: error))
            }
        case 401:
            let body = try? JSONDecoder().decode(JSONValue.self, from: data)
            throw DashboardError.unauthenticated(reason: body?["reason"]?.stringValue ?? body?["error"]?.stringValue)
        case 429:
            throw DashboardError.rateLimited
        default:
            throw DashboardError.http(status: response.statusCode, body: String(data: data, encoding: .utf8))
        }
    }
}
