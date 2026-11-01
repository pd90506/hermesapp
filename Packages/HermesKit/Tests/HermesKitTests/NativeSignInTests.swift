import Foundation
import Testing

@testable import HermesKit

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

@Suite(.timeLimit(.minutes(1))) struct NativeSignInTests {
    private func signIn(_ http: FakeHTTP = FakeHTTP([])) throws -> NativeSignIn {
        NativeSignIn(endpoint: try GatewayEndpoint("https://hermes.example.ts.net"), port: 51234, http: http,
                     pkce: PKCE(verifier: "verifier-123"), state: "state-abc")
    }

    @Test func authorizesWithALoopbackRedirect() throws {
        let url = try signIn().authorizeURL
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(components.path == "/auth/native/authorize")
        let query = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        #expect(query["redirect_uri"] == "http://127.0.0.1:51234/callback")
        #expect(query["state"] == "state-abc")
        #expect(query["code_challenge_method"] == "S256")
        #expect(query["code_challenge"] == PKCE(verifier: "verifier-123").challenge)
        #expect(query["provider"] == nil, "the server picks its only provider, or asks")
    }

    @Test func checksTheRedirect() throws {
        let signIn = try signIn()
        let good = try #require(URL(string: "http://127.0.0.1/callback?code=c0de&state=state-abc"))
        #expect(NativeSignIn.isCallback(good))
        #expect(!NativeSignIn.isCallback(try #require(URL(string: "http://127.0.0.1/favicon.ico"))))
        #expect(try signIn.code(from: good) == "c0de")
        #expect(throws: NativeSignInError.stateMismatch) {
            try signIn.code(from: URL(string: "http://127.0.0.1/callback?code=c0de&state=other")!)
        }
        #expect(throws: NativeSignInError.refused("access denied")) {
            try signIn.code(from: URL(string: "http://127.0.0.1/callback?error=access_denied&error_description=access%20denied")!)
        }
        #expect(throws: NativeSignInError.noCode) {
            try signIn.code(from: URL(string: "http://127.0.0.1/callback?state=state-abc")!)
        }
    }

    @Test func tradesTheCodeForAPairKeptAsTheSecret() async throws {
        // `routes.py:499-516`.
        let http = FakeHTTP([.init(status: 200, body: #"""
            {"access_token":"at","refresh_token":"rt","token_type":"Bearer","expires_at":1761900000,"provider":"basic","user_id":"u1"}
            """#)])
        let tokens = try await signIn(http).tokens(from: URL(string: "http://127.0.0.1/callback?code=c0de&state=state-abc")!)
        let request = try #require(http.requests.first)
        #expect(request.url?.absoluteString == "https://hermes.example.ts.net/auth/native/token")
        let body = try JSONDecoder().decode([String: String].self, from: try #require(request.httpBody))
        #expect(body == ["code": "c0de", "code_verifier": "verifier-123"])
        #expect(tokens.refreshToken == "rt")
        #expect(NativeTokens(secret: tokens.secret) == tokens)
        #expect(NativeTokens(secret: "a password") == nil)

        guard case .native(let session) = AuthMode.browser.credential(provider: "", username: "", secret: tokens.secret) else {
            Issue.record("a browser sign-in renews itself")
            return
        }
        #expect(await session.tokens == tokens)
    }
}
