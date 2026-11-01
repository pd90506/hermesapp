import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// One browser sign-in to a dashboard (RFC 8252: the system browser, a loopback redirect
/// and PKCE), as Hermes Desktop signs in to a remote gateway. The app listens on
/// `127.0.0.1:<port>` (an Apple-only helper), opens `authorizeURL`, and hands the URL the
/// browser came back to to `tokens(from:)`, which checks it and trades its code for a
/// token pair (`hermes_cli/dashboard_auth/routes.py:269-314,499-516`). The pair then
/// renews itself through `NativeTokenSession`.
public struct NativeSignIn: Sendable {
    public let pkce: PKCE
    public let state: String
    /// `http://127.0.0.1:<port>/callback`: the server takes only a loopback IP literal
    /// over plain HTTP (`_validate_loopback_redirect_uri`, `routes.py:241-274`).
    public let redirectURI: String
    let dashboard: DashboardClient

    public init(endpoint: GatewayEndpoint, port: UInt16, http: any HTTPClient = URLSessionHTTPClient.ephemeral(),
                pkce: PKCE = PKCE(), state: String = PKCE.randomState()) {
        self.pkce = pkce
        self.state = state
        self.redirectURI = "http://127.0.0.1:\(port)\(Self.callbackPath)"
        self.dashboard = DashboardClient(endpoint: endpoint, http: http)
    }

    /// The path the browser comes back to.
    public static let callbackPath = "/callback"

    /// The page to open. No provider: the server picks its only one, or shows a chooser
    /// (`_select_native_provider`, `routes.py:277-285`).
    public var authorizeURL: URL {
        dashboard.nativeAuthorizeURL(pkce: pkce, redirectURI: redirectURI, state: state)
    }

    /// Whether `url` (a request the loopback listener got) is the redirect, not a favicon.
    public static func isCallback(_ url: URL) -> Bool {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?.path == callbackPath
    }

    /// The code in the redirect, once its `state` is this sign-in's.
    public func code(from callback: URL) throws -> String {
        let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        if let error = value("error") {
            throw NativeSignInError.refused(value("error_description") ?? error)
        }
        guard value("state") == state else { throw NativeSignInError.stateMismatch }
        guard let code = value("code"), !code.isEmpty else { throw NativeSignInError.noCode }
        return code
    }

    /// The token pair for the redirect. The code is spent even when this fails.
    public func tokens(from callback: URL) async throws -> NativeTokens {
        try await dashboard.exchangeNativeCode(code(from: callback), verifier: pkce.verifier)
    }
}

public enum NativeSignInError: Error, Sendable, Equatable {
    /// The redirect's `state` isn't this sign-in's: another page called back.
    case stateMismatch
    case noCode
    /// The server or the user refused (`error` in the redirect).
    case refused(String)
}

extension NativeTokens {
    /// The pair as the app keeps it, as one Keychain secret.
    public var secret: String {
        (try? JSONEncoder().encode(self)).map { String(decoding: $0, as: UTF8.self) } ?? ""
    }

    /// A pair kept as `secret`.
    public init?(secret: String) {
        guard let tokens = try? JSONDecoder().decode(NativeTokens.self, from: Data(secret.utf8)),
              !tokens.accessToken.isEmpty else { return nil }
        self = tokens
    }
}
