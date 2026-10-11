import Foundation
import HermesKit
import HermesProtocol
import Observation

/// How the app signs in to the dashboard. Maps 1:1 onto `GatewayCredential`.
enum AuthMode: String, CaseIterable, Identifiable, Codable {
    case password
    case accessToken
    case sessionToken

    var id: Self { self }

    var label: String {
        switch self {
        case .password: "Username & password"
        case .accessToken: "Access token (ticket)"
        case .sessionToken: "Token in URL (?token=)"
        }
    }

    var secretLabel: String {
        switch self {
        case .password: "Password"
        case .accessToken: "Access token"
        case .sessionToken: "Token"
        }
    }

    /// Shown under the picker; the `?token=` mode is easy to misread.
    var help: String? {
        switch self {
        case .password: nil
        case .accessToken: "A dashboard access token. The app exchanges it for a single-use ticket on every connect."
        case .sessionToken:
            "Sent directly in the WebSocket URL. Works with an access token, or with the session token of a loopback-only dashboard (reachable from another device only through a tunnel). Prefer the other modes."
        }
    }
}

/// Non-secret connection settings, persisted in UserDefaults.
/// The password/token lives in the Keychain (`KeychainStore`).
struct ConnectionSettings: Codable, Equatable {
    var serverURL = ""
    var authMode: AuthMode = .password
    var provider = "basic"
    var username = ""

    private static let defaultsKey = "connectionSettings.v1"

    static func load() -> ConnectionSettings {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
            let settings = try? JSONDecoder().decode(ConnectionSettings.self, from: data)
        else { return ConnectionSettings() }
        return settings
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: Self.defaultsKey)
        }
    }
}

/// Root app state shared by the macOS and iOS apps.
@MainActor
@Observable
final class AppModel {
    var settings: ConnectionSettings
    var secret: String
    /// Whether the connection settings are shown, and what may close them.
    var settingsPresentation: SettingsPresentation
    var lastError: String?
    /// A failed sidebar action (opening a bot or a History chat), shown in the sidebar.
    var actionError: String?
    var probeResult: String?
    private(set) var isConnecting = false
    private var connectedEndpoint: GatewayEndpoint?

    let connection = GatewayConnection()
    /// Thumbnails of the images in transcripts and the composer (`TranscriptImages.swift`).
    let thumbnails = ThumbnailStore()

    private static let secretAccount = "gateway-secret"

    init() {
        #if DEBUG
        if let launch = UITestLaunch.current {
            // UI tests: never read or write the user's saved settings or Keychain.
            self.settings = ConnectionSettings(serverURL: launch.serverURL, authMode: .sessionToken)
            self.secret = launch.token
            self.settingsPresentation = SettingsPresentation(hasServer: true)
            return
        }
        #endif
        let settings = ConnectionSettings.load()
        self.settings = settings
        self.secret = KeychainStore.read(account: Self.secretAccount) ?? ""
        self.settingsPresentation = SettingsPresentation(hasServer: !settings.serverURL.isEmpty)
    }

    var isConnected: Bool { connection.state == .connected }

    /// Saves settings and (re)connects.
    func connect() async {
        guard !isConnecting else { return }
        isConnecting = true
        defer { isConnecting = false }
        lastError = nil
        do {
            let endpoint = try GatewayEndpoint(settings.serverURL)
            if !Self.isUITest {
                settings.save()
                do {
                    try KeychainStore.write(secret, account: Self.secretAccount)
                } catch {
                    // Still connect with the in-memory secret, but say it won't survive a relaunch.
                    lastError = error.localizedDescription
                }
            }
            if connectedEndpoint != endpoint {
                // Another server: its sessions must not stay on screen or be restored.
                await connection.disconnect()
            }
            try await connection.connect(using: DashboardConnector(endpoint: endpoint, credential: credential))
            connectedEndpoint = endpoint
            if lastError == nil { settingsPresentation.close() }
            #if DEBUG
            if let profile = UITestLaunch.current?.profile {
                connection.navigationPage = .sessions
                connection.selectListProfile(profile)
            }
            #endif
        } catch is CancellationError {
            // Superseded by a newer connect/disconnect.
        } catch {
            lastError = GatewayConnection.describe(error)
        }
    }

    func disconnect() async {
        await connection.disconnect()
        connectedEndpoint = nil
        actionError = nil
    }

    /// Pull-to-refresh: the roster and the visible profile’s sessions.
    func refreshLists() async {
        do {
            try await connection.refreshBots()
            await connection.refreshSessionListIfVisible()
        } catch {
            actionError = GatewayConnection.describe(error)
        }
    }

    /// Calls the public `/api/status` to check the URL before signing in.
    func probe() async {
        probeResult = nil
        do {
            let endpoint = try GatewayEndpoint(settings.serverURL)
            let status = try await DashboardClient(endpoint: endpoint).status()
            var parts = ["Hermes \(status.version ?? "?")"]
            if status.authRequired == true {
                parts.append("sign-in required (\((status.authFlows ?? []).joined(separator: ", ")))")
            } else {
                parts.append("no sign-in required")
            }
            probeResult = parts.joined(separator: " · ")
        } catch {
            probeResult = "Unreachable: \(GatewayConnection.describe(error))"
        }
    }

    private var credential: GatewayCredential {
        switch settings.authMode {
        case .password: .password(provider: settings.provider, username: settings.username, password: secret)
        case .accessToken: .bearer(accessToken: secret)
        case .sessionToken: .sessionToken(secret)
        }
    }
}

#if DEBUG
/// Set by the UI tests (`Apps/UITests`) in the launch environment: connect to this
/// dashboard with a `?token=` and open the Sessions page on this profile.
struct UITestLaunch {
    var serverURL: String
    var token: String
    var profile: String?

    static let current: UITestLaunch? = {
        let env = ProcessInfo.processInfo.environment
        guard let url = env["HERMES_UITEST_URL"], let token = env["HERMES_UITEST_TOKEN"],
            !url.isEmpty, !token.isEmpty
        else { return nil }
        return UITestLaunch(serverURL: url, token: token, profile: env["HERMES_UITEST_PROFILE"])
    }()
}
#endif

extension AppModel {
    static var isUITest: Bool {
        #if DEBUG
        UITestLaunch.current != nil
        #else
        false
        #endif
    }
}
