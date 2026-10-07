import Foundation
import HermesProtocol
import Synchronization
import Testing

@testable import HermesKit

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Scripted `HTTPClient`: answers requests in order and records them.
final class FakeHTTP: HTTPClient, @unchecked Sendable {
    struct Reply {
        var status: Int
        var body: String
    }

    private let state: Mutex<(replies: [Reply], requests: [URLRequest])>

    init(_ replies: [Reply]) {
        state = Mutex((replies, []))
    }

    var requests: [URLRequest] { state.withLock { $0.requests } }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let reply = state.withLock { state -> Reply in
            state.requests.append(request)
            return state.replies.isEmpty ? Reply(status: 500, body: "unscripted") : state.replies.removeFirst()
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "application/json"])!
        return (Data(reply.body.utf8), response)
    }
}

@Suite(.timeLimit(.minutes(1))) struct AuthTests {
    @Test(arguments: [
        ("hermes.example.ts.net:9119", "http://hermes.example.ts.net:9119"),
        ("https://hermes.example.ts.net/", "https://hermes.example.ts.net"),
        ("https://proxy.example.com/hermes/?x=1#frag", "https://proxy.example.com/hermes"),
        ("  http://127.0.0.1:9119  ", "http://127.0.0.1:9119"),
        ("wss://host.example/", "https://host.example"),
    ])
    func endpointNormalisation(input: String, expected: String) throws {
        #expect(try GatewayEndpoint(input).baseURL.absoluteString == expected)
    }

    @Test func endpointRejectsGarbage() {
        #expect(throws: GatewayEndpoint.Error.self) { try GatewayEndpoint("ftp://host") }
        #expect(throws: GatewayEndpoint.Error.self) { try GatewayEndpoint("") }
    }

    @Test func webSocketURLKeepsPrefixAndSwitchesScheme() throws {
        let secure = try GatewayEndpoint("https://proxy.example.com/hermes")
        #expect(secure.webSocketURL(query: [URLQueryItem(name: "ticket", value: "a+b")]).absoluteString
            == "wss://proxy.example.com/hermes/api/ws?ticket=a%2Bb")
        let plain = try GatewayEndpoint("127.0.0.1:9119")
        #expect(plain.webSocketURL(query: [URLQueryItem(name: "token", value: "t")]).absoluteString
            == "ws://127.0.0.1:9119/api/ws?token=t")
    }

    @Test func sha256KnownVectors() {
        let hex = { (bytes: [UInt8]) in bytes.map { String(format: "%02x", $0) }.joined() }
        #expect(hex(SHA256.hash(Array("abc".utf8)))
            == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        #expect(hex(SHA256.hash([]))
            == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        // Two-block message (56 bytes forces padding into a second block).
        #expect(hex(SHA256.hash(Array("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq".utf8)))
            == "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1")
    }

    @Test func pkceMatchesRFC7636AppendixB() {
        let pkce = PKCE(verifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
        #expect(pkce.challenge == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
        let fresh = PKCE()
        #expect(fresh.verifier.count == 43)
        #expect(!fresh.verifier.contains("="))
    }

    @Test func nativeAuthorizeURL() throws {
        let client = DashboardClient(endpoint: try GatewayEndpoint("https://h.example"), http: FakeHTTP([]))
        let url = client.nativeAuthorizeURL(pkce: PKCE(verifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"),
                                            redirectURI: "http://127.0.0.1:53682/callback", state: "s1",
                                            provider: "basic")
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(url.path == "/auth/native/authorize")
        #expect(items.first { $0.name == "code_challenge_method" }?.value == "S256")
        #expect(items.first { $0.name == "redirect_uri" }?.value == "http://127.0.0.1:53682/callback")
        #expect(items.first { $0.name == "provider" }?.value == "basic")
    }

    @Test func statusDecodesLiveShape() async throws {
        let http = FakeHTTP([.init(status: 200, body: #"""
            {"version":"0.21.5","release_date":"2026.9.24","gateway_running":true,"gateway_state":"running",
             "auth_required":true,"auth_providers":["basic"],"auth_flows":["cookie","native_pkce"],
             "components":{"gateway":{"status":"ok"}}}
            """#)])
        let status = try await DashboardClient(endpoint: try GatewayEndpoint("http://h:9119"), http: http).status()
        #expect(status.authRequired == true)
        #expect(status.authFlows == ["cookie", "native_pkce"])
        #expect(http.requests.first?.url?.absoluteString == "http://h:9119/api/status")
    }

    @Test func passwordCredentialLogsInWhenCookieSessionIsMissing() async throws {
        let http = FakeHTTP([
            .init(status: 401, body: #"{"error":"unauthenticated","detail":"Unauthorized","reason":"no_session"}"#),
            .init(status: 200, body: #"{"ok":true,"next":"/"}"#),
            .init(status: 200, body: #"{"ticket":"tkt-123","ttl_seconds":30}"#),
        ])
        let connector = DashboardConnector(
            endpoint: try GatewayEndpoint("https://hermes.example.ts.net"),
            credential: .password(provider: "basic", username: "user", password: "pw"), http: http)
        let request = try await connector.webSocketRequest()

        #expect(request.url?.absoluteString == "wss://hermes.example.ts.net/api/ws?ticket=tkt-123")
        let paths = http.requests.map { "\($0.httpMethod ?? "") \($0.url?.path ?? "")" }
        #expect(paths == ["POST /api/auth/ws-ticket", "POST /auth/password-login", "POST /api/auth/ws-ticket"])
        let login = try JSONDecoder().decode(JSONValue.self, from: http.requests[1].httpBody ?? Data())
        #expect(login == ["provider": "basic", "username": "user", "password": "pw", "next": ""])
    }

    @Test func bearerCredentialMintsTicketWithAuthorizationHeader() async throws {
        let http = FakeHTTP([.init(status: 200, body: #"{"ticket":"t2","ttl_seconds":30}"#)])
        let connector = DashboardConnector(endpoint: try GatewayEndpoint("http://h:9119"),
                                           credential: .bearer(accessToken: "at-1"), http: http)
        let request = try await connector.webSocketRequest()
        #expect(request.url?.query == "ticket=t2")
        #expect(http.requests.first?.value(forHTTPHeaderField: "Authorization") == "Bearer at-1")
    }

    @Test func badPasswordSurfacesUnauthenticated() async throws {
        let http = FakeHTTP([
            .init(status: 401, body: #"{"error":"unauthenticated"}"#),
            .init(status: 401, body: #"{"detail":"Invalid credentials"}"#),
        ])
        let connector = DashboardConnector(endpoint: try GatewayEndpoint("http://h"),
                                           credential: .password(provider: "basic", username: "u", password: "x"),
                                           http: http)
        await #expect(throws: DashboardError.invalidCredentials) { try await connector.webSocketRequest() }
    }

    @Test func sessionTokenGoesInQueryWithoutHTTP() async throws {
        let http = FakeHTTP([])
        let connector = DashboardConnector(endpoint: try GatewayEndpoint("127.0.0.1:9119"),
                                           credential: .sessionToken("legacy"), http: http)
        #expect(try await connector.webSocketRequest().url?.absoluteString == "ws://127.0.0.1:9119/api/ws?token=legacy")
        #expect(http.requests.isEmpty)
    }
}
