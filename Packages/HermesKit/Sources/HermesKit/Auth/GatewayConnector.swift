import Foundation
import HermesProtocol

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Produces a fresh, authenticated transport for each connection attempt.
public protocol GatewayConnector: Sendable {
    func makeTransport() async throws -> any MessageTransport
    /// Reads stored transcripts page by page over the dashboard's REST API, with
    /// the same credential. `nil`: this connector has no REST access, so opened
    /// chats show only what streams live and report their history unavailable.
    var messagesSource: (any SessionMessagesSource)? { get }
    /// Reads images stored on the gateway (`@image:` paths), with the same credential.
    var mediaSource: (any GatewayMediaSource)? { get }
    /// Lists and manages the profiles' scheduled jobs, with the same credential.
    var cronSource: (any CronSource)? { get }
}

extension GatewayConnector {
    public var messagesSource: (any SessionMessagesSource)? { nil }
    public var mediaSource: (any GatewayMediaSource)? { nil }
    public var cronSource: (any CronSource)? { nil }
}

/// Images and files on the gateway's disk, for a client that cannot read that disk.
public protocol GatewayMediaSource: Sendable {
    /// The bytes of the image at `path` (an `@image:` path), read for `profile`.
    func imageData(path: String, profile: String?) async throws -> Data
    /// The file at `path` (a `MEDIA:` path or an attachment), downloaded to a new
    /// temporary file the caller owns. `sessionID`: the stored session a relative
    /// path belongs to.
    func downloadFile(path: String, profile: String?, sessionID: String?) async throws -> URL
}

/// Bounded pages of a stored transcript (`GET /api/sessions/{id}/messages`).
public protocol SessionMessagesSource: Sendable {
    func messagesPage(_ query: SessionMessagesQuery) async throws -> SessionMessagesPage
    /// The user's prompts of a stored session (`GET /api/sessions/{id}/timeline`).
    func timelinePage(_ query: SessionTimelineQuery) async throws -> SessionTimelinePage
}

/// A source that reads no timeline.
public struct SessionTimelineUnsupported: Error, Sendable {}

extension SessionMessagesSource {
    public func timelinePage(_ query: SessionTimelineQuery) async throws -> SessionTimelinePage {
        throw SessionTimelineUnsupported()
    }
}

/// How the app authenticates to the dashboard WebSocket
/// (`hermes_cli/web_server_chat.py::_ws_auth_reason`).
public enum GatewayCredential: Sendable, Hashable {
    /// Gated dashboard with a password provider (e.g. `basic`): log in via
    /// `/auth/password-login` (cookie session), then mint a ticket per connect.
    case password(provider: String, username: String, password: String)
    /// Gated dashboard with an access token alone: mint a ticket with
    /// `Authorization: Bearer` per connect. Never refreshed; once the token
    /// expires (12 h for `basic`) connects fail with `.unauthenticated`.
    case bearer(accessToken: String)
    /// Gated dashboard with a native token pair (from `/auth/native/token`):
    /// like `.bearer`, but an expired or rejected access token is refreshed
    /// once per connect through the shared session, and the connect retried.
    case native(NativeTokenSession)
    /// Token sent directly as `/api/ws?token=`. Accepted as a provider access
    /// token on gated dashboards (`web_server_chat.py:332-365`), or as the
    /// dashboard session token on an un-gated *loopback* bind, which rejects
    /// non-loopback peers, so from a phone only through a tunnel (:139-159,
    /// :369-374). `--insecure` no longer disables the gate (`web_server.py:522-530`).
    /// The token is long-lived and travels in the URL; prefer `.bearer`.
    case sessionToken(String)
}

/// `GatewayConnector` for the Hermes dashboard's `/api/ws`.
public struct DashboardConnector: GatewayConnector {
    public let endpoint: GatewayEndpoint
    public let credential: GatewayCredential
    let dashboard: DashboardClient
    private let makeSocket: @Sendable (URLRequest) -> any MessageTransport

    public init(
        endpoint: GatewayEndpoint,
        credential: GatewayCredential,
        http: any HTTPClient = URLSessionHTTPClient.ephemeral(),
        makeSocket: @escaping @Sendable (URLRequest) -> any MessageTransport = {
            URLSessionWebSocketTransport(request: $0)
        }
    ) {
        self.endpoint = endpoint
        self.credential = credential
        self.dashboard = DashboardClient(endpoint: endpoint, http: http)
        self.makeSocket = makeSocket
    }

    public func makeTransport() async throws -> any MessageTransport {
        makeSocket(try await webSocketRequest())
    }

    /// The upgrade request. Tickets go in `?ticket=` like the desktop app
    /// (single-use, 30 s); the `hermes-gateway-ticket.*` subprotocol is an
    /// equivalent server-side option not used here.
    public func webSocketRequest() async throws -> URLRequest {
        let query: URLQueryItem
        switch credential {
        case .sessionToken(let token):
            query = URLQueryItem(name: "token", value: token)
        case .bearer(let accessToken):
            let ticket = try await dashboard.mintWebSocketTicket(bearer: accessToken)
            query = URLQueryItem(name: "ticket", value: ticket.ticket)
        case .native(let session):
            let ticket = try await mintTicket(with: session)
            query = URLQueryItem(name: "ticket", value: ticket.ticket)
        case .password(let provider, let username, let password):
            let ticket: WebSocketTicket
            do {
                // Reuse the cookie session while it is valid (the server
                // refreshes it from the refresh cookie on its own).
                ticket = try await dashboard.mintWebSocketTicket()
            } catch DashboardError.unauthenticated {
                try await dashboard.passwordLogin(provider: provider, username: username, password: password)
                ticket = try await dashboard.mintWebSocketTicket()
            }
            query = URLQueryItem(name: "ticket", value: ticket.ticket)
        }
        var request = URLRequest(url: endpoint.webSocketURL(query: [query]))
        request.timeoutInterval = 15
        return request
    }

    public var messagesSource: (any SessionMessagesSource)? { self }
    public var mediaSource: (any GatewayMediaSource)? { self }
    public var cronSource: (any CronSource)? { self }

    /// At most one refresh per connect: proactively when the token is known
    /// to be expired, otherwise after the server rejects it (401
    /// `session_expired`, `middleware.py:65-79,163-175`). A second 401 is final.
    private func mintTicket(with session: NativeTokenSession) async throws -> WebSocketTicket {
        let (accessToken, refreshed) = try await session.accessToken(using: dashboard)
        do {
            return try await dashboard.mintWebSocketTicket(bearer: accessToken)
        } catch DashboardError.unauthenticated where !refreshed {
            let fresh = try await session.refresh(replacing: accessToken, using: dashboard)
            return try await dashboard.mintWebSocketTicket(bearer: fresh)
        }
    }
}

extension DashboardConnector: SessionMessagesSource {
    /// Authenticates like the ticket mint, so REST and the socket share one sign-in:
    /// - a token (`.bearer`, `.sessionToken`) goes in `Authorization: Bearer`. The
    ///   gated dashboard verifies it as an access token (`dashboard_auth/middleware.py:163-175`);
    ///   an un-gated loopback one takes its session token there too
    ///   (`hermes_cli/web_server.py:452-463`);
    /// - `.native` refreshes at most once, before the call when the token is known
    ///   to be expired, otherwise after a 401;
    /// - `.password` uses the cookie session and logs in again after a 401.
    public func messagesPage(_ query: SessionMessagesQuery) async throws -> SessionMessagesPage {
        try await authorized { bearer in try await dashboard.sessionMessages(query, bearer: bearer) }
    }

    public func timelinePage(_ query: SessionTimelineQuery) async throws -> SessionTimelinePage {
        try await authorized { bearer in try await dashboard.sessionTimeline(query, bearer: bearer) }
    }

    /// One authenticated REST call, with the retry rules above. `call` gets the
    /// bearer token, or `nil` when the cookie session authenticates.
    func authorized<T: Sendable>(_ call: @Sendable (String?) async throws -> T) async throws -> T {
        switch credential {
        case .sessionToken(let token), .bearer(let token):
            return try await call(token)
        case .native(let session):
            let (accessToken, refreshed) = try await session.accessToken(using: dashboard)
            do {
                return try await call(accessToken)
            } catch DashboardError.unauthenticated where !refreshed {
                let fresh = try await session.refresh(replacing: accessToken, using: dashboard)
                return try await call(fresh)
            }
        case .password(let provider, let username, let password):
            do {
                return try await call(nil)
            } catch DashboardError.unauthenticated {
                try await dashboard.passwordLogin(provider: provider, username: username, password: password)
                return try await call(nil)
            }
        }
    }
}

extension DashboardConnector: GatewayMediaSource {
    /// `GET /api/media?path=` first: the route meant for media, which serves only
    /// files under the dashboard's own `HERMES_HOME/{images,screenshots,cache}`
    /// (`hermes_cli/web_routers/files.py:307-354`). An upload to a session on
    /// another profile is stored in *that* profile's home
    /// (`tui_gateway/prompt_attachments.py:82-95,133-134`), outside those roots, so
    /// the route answers 403. Those are read like Desktop's remote mode reads them:
    /// `GET /api/fs/read-data-url?path=&profile=` (`apps/desktop/src/lib/media.ts:132-136`,
    /// `files.py:901-922`). Any other failure (404 gone, 413 too large, offline) is thrown.
    public func imageData(path: String, profile: String?) async throws -> Data {
        let url: String
        do {
            url = try await authorized { bearer in try await dashboard.mediaDataURL(path: path, bearer: bearer) }
        } catch DashboardError.http(status: 403, _) where TranscriptImage.isImagePath(path) {
            // Only image files: `@image:/some/large.log` must not pull 16 MB to show a placeholder.
            url = try await authorized { bearer in
                try await dashboard.fileDataURL(path: path, profile: profile, bearer: bearer)
            }
        }
        guard let data = DataURL.decode(url) else { throw DashboardError.invalidResponse("not a base64 data URL") }
        return data
    }

    public func downloadFile(path: String, profile: String?, sessionID: String?) async throws -> URL {
        try await authorized { bearer in
            try await dashboard.downloadFile(path: path, profile: profile, sessionID: sessionID, bearer: bearer)
        }
    }
}

/// `data:<mime>;base64,<payload>`.
enum DataURL {
    static func decode(_ url: String) -> Data? {
        guard url.hasPrefix("data:"), let comma = url.firstIndex(of: ","),
            url[..<comma].hasSuffix(";base64")
        else { return nil }
        return Data(base64Encoded: String(url[url.index(after: comma)...]), options: .ignoreUnknownCharacters)
    }
}
