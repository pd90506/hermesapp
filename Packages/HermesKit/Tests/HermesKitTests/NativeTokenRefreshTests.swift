import Foundation
import HermesProtocol
import Synchronization
import Testing

@testable import HermesKit

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// `HTTPClient` that answers each request from a handler (so concurrent
/// requests get the right reply regardless of arrival order) and records them.
final class RoutedHTTP: HTTPClient, Sendable {
    typealias Handler = @Sendable (_ path: String, _ bearer: String?) async -> (status: Int, body: String)

    private let handler: Handler
    private let log = Mutex<[URLRequest]>([])

    init(_ handler: @escaping Handler) {
        self.handler = handler
    }

    var requests: [URLRequest] { log.withLock { $0 } }

    func paths() -> [String] {
        requests.map { request in
            let bearer = request.value(forHTTPHeaderField: "Authorization").map { " \($0)" } ?? ""
            return "\(request.url?.path ?? "")\(bearer)"
        }
    }

    func count(_ path: String) -> Int { requests.filter { $0.url?.path == path }.count }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        log.withLock { $0.append(request) }
        let bearer = request.value(forHTTPHeaderField: "Authorization")?.replacingOccurrences(of: "Bearer ", with: "")
        let reply = await handler(request.url?.path ?? "", bearer)
        let response = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "application/json"])!
        return (Data(reply.body.utf8), response)
    }
}

/// Lets a fake server hold a reply until N other requests have arrived.
actor Rendezvous {
    private var arrived = 0
    private var waiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    func arrive() {
        arrived += 1
        let ready = waiters.filter { $0.count <= arrived }
        waiters.removeAll { $0.count <= arrived }
        for waiter in ready { waiter.continuation.resume() }
    }

    func wait(until count: Int) async {
        if arrived >= count { return }
        await withCheckedContinuation { waiters.append((count, $0)) }
    }
}

/// Records the pairs handed to `onRotate`.
final class RotationLog: Sendable {
    private let pairs = Mutex<[NativeTokens]>([])

    func append(_ tokens: NativeTokens) { pairs.withLock { $0.append(tokens) } }

    var all: [NativeTokens] { pairs.withLock { $0 } }
}

// Fixture shapes, as Hermes sends them:
/// Ticket mint (`hermes_cli/dashboard_auth/routes.py:494`).
private let ticketOK = (200, #"{"ticket":"tkt-1","ttl_seconds":30}"#)
/// Expired/invalid bearer on an `/api/` route (`middleware.py:65-79,163-175`).
private let bearerExpired = (401, #"""
    {"error":"session_expired","detail":"Unauthorized","reason":"invalid_or_expired_session","login_url":"/login"}
    """#)
/// Successful refresh: `_bearer_payload` (`routes.py:110-115,543`); `basic` uses the username as user_id.
private let refreshOK = (200, #"""
    {"access_token":"at-new","refresh_token":"rt-new","token_type":"Bearer","expires_at":1790043200,
     "provider":"basic","user_id":"admin"}
    """#)
/// Every provider rejected the refresh token (`routes.py:544-547`).
private let refreshRejected = (401, #"""
    {"error":"session_expired","detail":"Refresh token expired or invalid; start a new sign-in."}
    """#)

private let oldTokens = NativeTokens(accessToken: "at-old", refreshToken: "rt-old", expiresAt: 1_790_000_000,
                                     provider: "basic")
/// Before `oldTokens` expires.
private let beforeExpiry: @Sendable () -> Date = { Date(timeIntervalSince1970: 1_789_990_000) }

private func connector(_ session: NativeTokenSession, _ http: RoutedHTTP,
                       makeSocket: @escaping @Sendable (URLRequest) -> any MessageTransport = { _ in FakeTransport() })
    throws -> DashboardConnector
{
    DashboardConnector(endpoint: try GatewayEndpoint("https://hermes.example.ts.net"),
                       credential: .native(session), http: http, makeSocket: makeSocket)
}

@Suite(.timeLimit(.minutes(1)))
struct NativeTokenRefreshTests {
    @Test func rejectedAccessTokenIsRefreshedAndTheConnectRetried() async throws {
        let rotations = RotationLog()
        let http = RoutedHTTP { path, bearer in
            switch (path, bearer) {
            case ("/api/auth/ws-ticket", "at-old"): bearerExpired
            case ("/api/auth/ws-ticket", "at-new"): ticketOK
            case ("/auth/native/refresh", nil): refreshOK
            default: (500, "unscripted")
            }
        }
        let session = NativeTokenSession(tokens: oldTokens, now: beforeExpiry) { rotations.append($0) }

        let request = try await connector(session, http).webSocketRequest()

        #expect(request.url?.absoluteString == "wss://hermes.example.ts.net/api/ws?ticket=tkt-1")
        #expect(http.paths() == ["/api/auth/ws-ticket Bearer at-old", "/auth/native/refresh",
                                 "/api/auth/ws-ticket Bearer at-new"])
        let body = try JSONDecoder().decode(JSONValue.self, from: http.requests[1].httpBody ?? Data())
        #expect(body == ["refresh_token": "rt-old", "provider": "basic"])
    }

    @Test func rotatedTokensReachTheAppBeforeTheyAreUsed() async throws {
        let rotations = RotationLog()
        let http = RoutedHTTP { path, bearer in
            if path == "/api/auth/ws-ticket", bearer == "at-new" {
                // The new pair must already be saved when a request uses it.
                return rotations.all.isEmpty ? (500, "not persisted yet") : ticketOK
            }
            return path == "/auth/native/refresh" ? refreshOK : bearerExpired
        }
        let session = NativeTokenSession(tokens: oldTokens, now: beforeExpiry) { rotations.append($0) }

        _ = try await connector(session, http).webSocketRequest()

        #expect(rotations.all.count == 1)
        #expect(rotations.all.first?.accessToken == "at-new")
        #expect(rotations.all.first?.refreshToken == "rt-new")
        #expect(rotations.all.first?.expiresAt == 1_790_043_200)
        #expect(rotations.all.first?.provider == "basic")
        #expect(await session.tokens == rotations.all.first)
    }

    @Test func knownExpiredTokenIsRefreshedBeforeMinting() async throws {
        let http = RoutedHTTP { path, bearer in
            switch (path, bearer) {
            case ("/api/auth/ws-ticket", "at-new"): ticketOK
            case ("/auth/native/refresh", nil): refreshOK
            default: bearerExpired
            }
        }
        let session = NativeTokenSession(tokens: oldTokens, now: { Date(timeIntervalSince1970: 1_790_000_001) })

        _ = try await connector(session, http).webSocketRequest()

        #expect(http.paths() == ["/auth/native/refresh", "/api/auth/ws-ticket Bearer at-new"])
    }

    @Test func refreshedTokenRejectedAgainIsFinal() async throws {
        // The refreshed token is rejected as well: no second refresh, no loop.
        let http = RoutedHTTP { path, _ in path == "/auth/native/refresh" ? refreshOK : bearerExpired }
        let session = NativeTokenSession(tokens: oldTokens, now: beforeExpiry)

        await #expect(throws: DashboardError.unauthenticated(reason: "invalid_or_expired_session")) {
            try await connector(session, http).webSocketRequest()
        }
        #expect(http.count("/auth/native/refresh") == 1)
        #expect(http.count("/api/auth/ws-ticket") == 2)
    }

    @Test func rejectedRefreshTokenSurfacesRefreshRejected() async throws {
        let rotations = RotationLog()
        let http = RoutedHTTP { path, _ in path == "/auth/native/refresh" ? refreshRejected : bearerExpired }
        let session = NativeTokenSession(tokens: oldTokens, now: beforeExpiry) { rotations.append($0) }

        await #expect(throws: DashboardError.refreshRejected) { try await connector(session, http).webSocketRequest() }

        #expect(http.paths() == ["/api/auth/ws-ticket Bearer at-old", "/auth/native/refresh"])
        #expect(rotations.all.isEmpty)
        #expect(await session.tokens == oldTokens)
        #expect(GatewayConnection.describe(DashboardError.refreshRejected).contains("Sign in again"))
    }

    @Test func missingRefreshTokenFailsWithoutCallingTheServer() async throws {
        let http = RoutedHTTP { _, _ in bearerExpired }
        let session = NativeTokenSession(tokens: NativeTokens(accessToken: "at-old", refreshToken: ""),
                                         now: beforeExpiry)

        await #expect(throws: DashboardError.refreshRejected) { try await connector(session, http).webSocketRequest() }
        #expect(http.count("/auth/native/refresh") == 0)
    }

    @Test func concurrentConnectsShareOneRefresh() async throws {
        // Both connects must have been rejected with the old token before the
        // refresh answers, so they really overlap.
        let rejected = Rendezvous()
        let rotations = RotationLog()
        let http = RoutedHTTP { path, bearer in
            switch (path, bearer) {
            case ("/api/auth/ws-ticket", "at-old"):
                await rejected.arrive()
                return bearerExpired
            case ("/api/auth/ws-ticket", "at-new"):
                return ticketOK
            case ("/auth/native/refresh", nil):
                await rejected.wait(until: 2)
                return refreshOK
            default:
                return (500, "unscripted")
            }
        }
        let session = NativeTokenSession(tokens: oldTokens, now: beforeExpiry) { rotations.append($0) }
        // Separate connectors sharing the session, like a reconnect racing a foreground connect.
        let a = try connector(session, http)
        let b = try connector(session, http)

        async let first = a.webSocketRequest()
        async let second = b.webSocketRequest()
        let urls = try await [first, second].map { $0.url?.query }

        #expect(urls == ["ticket=tkt-1", "ticket=tkt-1"])
        #expect(http.count("/auth/native/refresh") == 1)
        #expect(http.paths().filter { $0.hasSuffix("at-old") }.count == 2)
        #expect(http.paths().filter { $0.hasSuffix("at-new") }.count == 2)
        #expect(rotations.all.count == 1)
    }

    @Test func laterConnectsUseTheRotatedTokens() async throws {
        let http = RoutedHTTP { path, bearer in
            switch (path, bearer) {
            case ("/api/auth/ws-ticket", "at-new"): ticketOK
            case ("/auth/native/refresh", nil): refreshOK
            default: bearerExpired
            }
        }
        let session = NativeTokenSession(tokens: oldTokens, now: beforeExpiry)

        _ = try await connector(session, http).webSocketRequest()
        _ = try await connector(session, http).webSocketRequest()

        #expect(http.count("/auth/native/refresh") == 1)
        #expect(http.paths().last == "/api/auth/ws-ticket Bearer at-new")
    }

    @MainActor
    @Test func reconnectStopsWhenTheRefreshTokenIsRejected() async throws {
        // First connect works; after the drop the access token is rejected and
        // so is the refresh token. Retrying forever must not happen.
        let mints = Mutex(0)
        let http = RoutedHTTP { [mints] path, _ in
            if path == "/auth/native/refresh" { return refreshRejected }
            let mint = mints.withLock { count -> Int in
                count += 1
                return count
            }
            return mint == 1 ? ticketOK : bearerExpired
        }
        let first = FakeTransport()
        first.serve(log: FrameLog()) { method, _ in method == "session.list" ? ["sessions": []] : nil }
        let session = NativeTokenSession(tokens: oldTokens, now: beforeExpiry)
        var configuration = GatewayClient.Configuration()
        configuration.heartbeatInterval = nil
        let connection = GatewayConnection(configuration: configuration, backoff: { _ in .milliseconds(1) })
        connection.maxReconnectAttempts = nil

        try await connection.connect(using: try connector(session, http) { _ in first })
        first.serverDrops()

        #expect(await eventually { connection.state == .failed(GatewayConnection.describe(DashboardError.refreshRejected)) })
        try await Task.sleep(for: .milliseconds(50))
        #expect(http.count("/auth/native/refresh") == 1)
    }
}
