import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Produces a fresh, authenticated transport for each connection attempt.
public protocol GatewayConnector: Sendable {
    func makeTransport() async throws -> any MessageTransport
}

/// How the app authenticates to the dashboard WebSocket
/// (`hermes_cli/web_server_chat.py::_ws_auth_reason`).
public enum GatewayCredential: Sendable, Hashable {
    /// Gated dashboard with a password provider (e.g. `basic`): log in via
    /// `/auth/password-login` (cookie session), then mint a ticket per connect.
    case password(provider: String, username: String, password: String)
    /// Gated dashboard with an access token (from the native PKCE flow):
    /// mint a ticket with `Authorization: Bearer` per connect.
    case bearer(accessToken: String)
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
    private let dashboard: DashboardClient
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
}
