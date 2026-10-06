import Foundation
import HermesProtocol
import Testing

@testable import HermesKit

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// Fixture shapes, as Hermes sends them:
/// A page of `GET /api/sessions/{id}/messages` (`hermes_cli/web_routers/sessions.py:720-729`)
/// with rows as `_row_to_message_dict` returns them (`hermes_state_messages.py:1311-1333`).
private let pageOK = (200, #"""
    {"session_id":"coder-chat-tip","profile":"coder",
     "messages":[{"id":41,"session_id":"coder-chat-tip","role":"user","content":"hi","tool_call_id":null,
                  "tool_calls":null,"tool_name":null,"effect_disposition":null,"timestamp":1700000041.5,
                  "token_count":null,"finish_reason":null,"reasoning":null,"reasoning_content":null,
                  "reasoning_details":null,"codex_reasoning_items":null,"codex_message_items":null,
                  "platform_message_id":null,"observed":0,"active":1,"compacted":0,"api_content":null,
                  "display_kind":null,"display_metadata":null,"message_uid":"u-41"},
                 {"id":42,"session_id":"coder-chat-tip","role":"assistant","content":"hello","timestamp":1700000042.0,
                  "finish_reason":"stop","reasoning":"greet back","active":1,"compacted":0,"display_kind":null}],
     "pagination":{"limit":120,"offset":0,"order":"latest","returned":2}}
    """#)
/// Expired/invalid bearer on an `/api/` route (`dashboard_auth/middleware.py:65-79,163-175`).
private let bearerExpired = (401, #"""
    {"error":"session_expired","detail":"Unauthorized","reason":"invalid_or_expired_session","login_url":"/login"}
    """#)
/// `_bearer_payload` (`dashboard_auth/routes.py:110-115,543`).
private let refreshOK = (200, #"""
    {"access_token":"at-new","refresh_token":"rt-new","token_type":"Bearer","expires_at":1790043200,
     "provider":"basic","user_id":"admin"}
    """#)
/// Unknown session (`web_routers/sessions.py:714-715`).
private let notFound = (404, #"{"detail":"Session not found"}"#)

private let latestQuery = SessionMessagesQuery(sessionID: "coder-chat-tip", profile: "coder", limit: 120)

private func connector(_ credential: GatewayCredential, _ http: some HTTPClient) throws -> DashboardConnector {
    DashboardConnector(endpoint: try GatewayEndpoint("https://hermes.example.ts.net/hermes"), credential: credential,
                       http: http, makeSocket: { _ in FakeTransport() })
}

@Suite(.timeLimit(.minutes(1)))
struct SessionMessagesRESTTests {
    @Test func readsTheNewestPageScopedToTheProfile() async throws {
        let http = FakeHTTP([.init(status: pageOK.0, body: pageOK.1)])
        let page = try await connector(.bearer(accessToken: "at-1"), http).messagesPage(latestQuery)

        let request = try #require(http.requests.first)
        #expect(request.httpMethod == "GET")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer at-1")
        let url = try #require(request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) })
        #expect(url.path == "/hermes/api/sessions/coder-chat-tip/messages")
        #expect(url.queryItems == [
            URLQueryItem(name: "profile", value: "coder"), URLQueryItem(name: "order", value: "latest"),
            URLQueryItem(name: "limit", value: "120"), URLQueryItem(name: "offset", value: "0"),
            URLQueryItem(name: "include_compacted", value: "true"), URLQueryItem(name: "inline_images", value: "false"),
        ])
        #expect(page.messages.map(\.id) == [41, 42])
        #expect(page.messages.last?.reasoning == "greet back")
        #expect(page.pagination == SessionMessagesPagination(limit: 120, offset: 0, order: "latest", returned: 2))
    }

    @Test func aTokenInTheURLModeIsSentAsBearer() async throws {
        let http = FakeHTTP([.init(status: pageOK.0, body: pageOK.1)])
        var query = latestQuery
        query.profile = nil
        query.offset = 240
        _ = try await connector(.sessionToken("loopback-token"), http).messagesPage(query)
        let request = try #require(http.requests.first)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer loopback-token")
        #expect(request.url?.query?.contains("profile") == false)
        #expect(request.url?.query?.contains("offset=240") == true)
    }

    /// The same single refresh as the ticket mint (`d6cbda5`).
    @Test func aNativeTokenIsRefreshedOnceAfterA401() async throws {
        let rotations = RotationLog()
        let http = RoutedHTTP { path, bearer in
            switch (path, bearer) {
            case ("/hermes/api/sessions/coder-chat-tip/messages", "at-old"): bearerExpired
            case ("/hermes/api/sessions/coder-chat-tip/messages", "at-new"): pageOK
            case ("/hermes/auth/native/refresh", nil): refreshOK
            default: (500, "unscripted")
            }
        }
        let tokens = NativeTokens(accessToken: "at-old", refreshToken: "rt-old", expiresAt: 1_790_000_000, provider: "basic")
        let session = NativeTokenSession(tokens: tokens, now: { Date(timeIntervalSince1970: 1_789_990_000) }) {
            rotations.append($0)
        }

        let page = try await connector(.native(session), http).messagesPage(latestQuery)

        #expect(page.messages.count == 2)
        #expect(http.paths() == ["/hermes/api/sessions/coder-chat-tip/messages Bearer at-old", "/hermes/auth/native/refresh",
                                 "/hermes/api/sessions/coder-chat-tip/messages Bearer at-new"])
        #expect(rotations.all.map(\.refreshToken) == ["rt-new"])
    }

    @Test func aNativeTokenRejectedTwiceFails() async throws {
        let http = RoutedHTTP { path, _ in path.hasSuffix("/refresh") ? refreshOK : bearerExpired }
        let tokens = NativeTokens(accessToken: "at-old", refreshToken: "rt-old", expiresAt: 1_790_000_000, provider: "basic")
        let session = NativeTokenSession(tokens: tokens, now: { Date(timeIntervalSince1970: 1_789_990_000) })
        await #expect(throws: DashboardError.unauthenticated(reason: "invalid_or_expired_session")) {
            try await connector(.native(session), http).messagesPage(latestQuery)
        }
        #expect(http.count("/hermes/auth/native/refresh") == 1)
    }

    /// The cookie session lapsed: log in again, then read with the new cookie.
    @Test func aPasswordSessionLogsInAgainAfterA401() async throws {
        let http = FakeHTTP([.init(status: bearerExpired.0, body: bearerExpired.1),
                             .init(status: 200, body: #"{"ok":true,"next":"/"}"#),
                             .init(status: pageOK.0, body: pageOK.1)])
        let page = try await connector(.password(provider: "basic", username: "admin", password: "pw"), http)
            .messagesPage(latestQuery)
        #expect(page.messages.count == 2)
        #expect(http.requests.map { "\($0.httpMethod ?? "") \($0.url?.path ?? "")" } == [
            "GET /hermes/api/sessions/coder-chat-tip/messages", "POST /hermes/auth/password-login",
            "GET /hermes/api/sessions/coder-chat-tip/messages",
        ])
        #expect(http.requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == nil })
    }

    @Test func anUnknownSessionIsAnHTTPError() async throws {
        let http = FakeHTTP([.init(status: notFound.0, body: notFound.1)])
        await #expect(throws: DashboardError.http(status: 404, body: notFound.1)) {
            try await connector(.bearer(accessToken: "at-1"), http).messagesPage(latestQuery)
        }
    }
}
