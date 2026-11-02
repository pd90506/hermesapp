import Foundation

/// How the app signs in to a dashboard. Maps 1:1 onto `GatewayCredential`.
public enum AuthMode: String, CaseIterable, Identifiable, Codable, Sendable {
    case password
    /// A browser sign-in (`NativeSignIn`): a token pair that renews itself. The secret is
    /// the pair (`NativeTokens.secret`).
    case browser
    case accessToken
    case sessionToken

    public var id: Self { self }

    public func credential(provider: String, username: String, secret: String) -> GatewayCredential {
        switch self {
        case .password: .password(provider: provider, username: username, password: secret)
        // A session of its own: the app keeps one per server instead, which saves each
        // renewed pair (`NativeTokenSession.onRotate`).
        case .browser: .native(NativeTokenSession(tokens: NativeTokens(secret: secret)
                                    ?? NativeTokens(accessToken: "", refreshToken: "")))
        case .accessToken: .bearer(accessToken: secret)
        case .sessionToken: .sessionToken(secret)
        }
    }
}

/// One Hermes dashboard the app connects to. Non-secret, persisted by the app; the
/// password or token lives in the Keychain under `secretAccount`.
public struct ServerConfig: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    /// The user's name for the server; empty means "derive one from the URL".
    public var name: String
    public var serverURL: String
    public var authMode: AuthMode
    public var provider: String
    public var username: String

    public init(id: UUID = UUID(), name: String = "", serverURL: String = "",
                authMode: AuthMode = .password, provider: String = "basic", username: String = "") {
        self.id = id
        self.name = name
        self.serverURL = serverURL
        self.authMode = authMode
        self.provider = provider
        self.username = username
    }

    /// Older lists may lack fields added later; decode what is there.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        serverURL = try c.decodeIfPresent(String.self, forKey: .serverURL) ?? ""
        authMode = (try? c.decodeIfPresent(AuthMode.self, forKey: .authMode)) ?? .password
        provider = try c.decodeIfPresent(String.self, forKey: .provider) ?? "basic"
        username = try c.decodeIfPresent(String.self, forKey: .username) ?? ""
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, serverURL, authMode, provider, username
    }

    public func credential(secret: String) -> GatewayCredential {
        authMode.credential(provider: provider, username: username, secret: secret)
    }

    /// The Keychain account of this server's password or token.
    public var secretAccount: String { "gateway-secret.\(id.uuidString)" }

    /// The name, or one derived from the URL: the first label of a host name
    /// (`hermes` for `hermes.example.ts.net`), the whole host and port for an IP
    /// address or `localhost`.
    public var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        return Self.defaultName(for: serverURL) ?? "New Server"
    }

    static func defaultName(for url: String) -> String? {
        guard let endpoint = try? GatewayEndpoint(url),
            let components = URLComponents(url: endpoint.baseURL, resolvingAgainstBaseURL: false),
            let host = components.host, !host.isEmpty
        else { return nil }
        let isAddress = host == "localhost" || host.contains(":")
            || host.split(separator: ".").allSatisfy { !$0.isEmpty && $0.allSatisfy(\.isNumber) }
        if isAddress {
            // Foundation keeps an IPv6 host's brackets on Apple platforms, not on Linux.
            let shown = host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host
            return components.port.map { "\(shown):\($0)" } ?? shown
        }
        return host.split(separator: ".").first.map(String.init) ?? host
    }
}

/// The saved list of servers, and the move from the single-server setting it replaces.
public enum ServerList {
    /// UserDefaults key of the list (JSON `[ServerConfig]`).
    public static let defaultsKey = "servers.v2"
    /// UserDefaults key of the single-server setting of earlier versions.
    public static let legacyDefaultsKey = "connectionSettings.v1"
    /// Keychain account of the single server's secret in earlier versions.
    public static let legacySecretAccount = "gateway-secret"

    public struct Loaded: Equatable, Sendable {
        public var servers: [ServerConfig]
        /// The server made from the single-server setting, when this load made it:
        /// its secret is still under `legacySecretAccount`, to be moved to its own.
        public var migrated: ServerConfig?
    }

    /// The servers saved as `current`, or else the one in the `legacy` setting.
    /// A saved list wins even when empty: the user removed every server.
    public static func load(current: Data?, legacy: Data?) -> Loaded {
        if let current {
            let servers = (try? JSONDecoder().decode([ServerConfig].self, from: current)) ?? []
            return Loaded(servers: servers, migrated: nil)
        }
        guard let legacy, let old = try? JSONDecoder().decode(LegacySettings.self, from: legacy),
            !(old.serverURL ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return Loaded(servers: [], migrated: nil) }
        let server = ServerConfig(serverURL: old.serverURL ?? "", authMode: old.authMode ?? .password,
                                  provider: old.provider ?? "basic", username: old.username ?? "")
        return Loaded(servers: [server], migrated: server)
    }

    public static func encode(_ servers: [ServerConfig]) -> Data? {
        try? JSONEncoder().encode(servers)
    }

    /// `ConnectionSettings` as the app saved it under `legacyDefaultsKey`.
    private struct LegacySettings: Decodable {
        var serverURL: String?
        var authMode: AuthMode?
        var provider: String?
        var username: String?

        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            serverURL = try c.decodeIfPresent(String.self, forKey: .serverURL)
            authMode = try? c.decodeIfPresent(AuthMode.self, forKey: .authMode)
            provider = try c.decodeIfPresent(String.self, forKey: .provider)
            username = try c.decodeIfPresent(String.self, forKey: .username)
        }

        private enum CodingKeys: String, CodingKey { case serverURL, authMode, provider, username }
    }
}
