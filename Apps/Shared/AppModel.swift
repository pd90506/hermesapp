import Foundation
import HermesKit
import HermesProtocol
import Observation

/// A profile on one server (profile names are only unique per server).
struct ProfileRef: Hashable {
    var server: UUID
    var profile: String
}

/// A profile just picked, and how many lists its server had read then: only a list
/// read after that can show that its last chat is gone.
struct PendingProfileChat: Equatable {
    var profile: ProfileRef
    var listReads: Int
}

/// The sign-in methods as the settings show them. Map 1:1 onto `GatewayCredential`.
extension AuthMode {
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

/// One Hermes dashboard: its settings, its secret and its own connection.
@MainActor
@Observable
final class ServerConnection: Identifiable {
    /// `config.id`, which never changes.
    let id: UUID
    var config: ServerConfig
    /// The password or token, kept in the Keychain under `config.secretAccount`.
    var secret: String
    var lastError: String?
    var probeResult: String?
    fileprivate(set) var isConnecting = false
    fileprivate var connectedEndpoint: GatewayEndpoint?

    /// Its chats show streamed text a batch at a time, as Desktop does (`StreamedTextQueue`).
    let connection = GatewayConnection(coalescesStreamedText: true)
    #if os(macOS)
    /// The Hermes backend this server is, when the app runs it on this Mac ("This Mac").
    let backend: LocalBackendProcess?
    #endif
    /// Thumbnails of the images in this server's transcripts and composers
    /// (`TranscriptImages.swift`). Per server: image paths are only unique within one.
    let thumbnails = ThumbnailStore()
    /// Files from this server's transcripts downloaded to preview or save (`TranscriptFiles.swift`).
    let downloads: FileDownloads

    init(config: ServerConfig, secret: String) {
        self.id = config.id
        self.config = config
        self.secret = secret
        self.downloads = FileDownloads(serverID: config.id)
        #if os(macOS)
        self.backend = nil
        #endif
    }

    #if os(macOS)
    /// "This Mac": a backend the app starts on a port the OS picks, with a fresh token
    /// each time; its URL and token are filled in when it starts and never saved.
    init(localBackend: LocalBackendProcess) {
        let config = ServerConfig(id: Self.localID, name: "This Mac", authMode: .sessionToken)
        self.id = config.id
        self.config = config
        self.secret = ""
        self.downloads = FileDownloads(serverID: config.id)
        self.backend = localBackend
    }
    #endif

    static let localID = UUID(uuidString: "00000000-0000-0000-0000-00000000AC01")!

    /// The backend the app runs on this Mac (always false on iOS).
    var isLocal: Bool {
        #if os(macOS)
        backend != nil
        #else
        false
        #endif
    }

    var name: String { config.displayName }
    var isConnected: Bool { connection.state == .connected }
    /// Something to connect to: an address, or the local backend (whose address comes later).
    var hasURL: Bool { isLocal || !config.serverURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}

/// Root app state shared by the macOS and iOS apps: the servers, each with its own
/// connection, and which of them the chat on screen and the session list belong to.
@MainActor
@Observable
final class AppModel {
    private(set) var servers: [ServerConnection]
    /// The server edited in the settings.
    var selectedServerID: UUID?
    /// The server whose chat is on screen.
    var activeServerID: UUID?
    /// The server of the profile picked in the profile rail, whose sessions the middle
    /// column lists. Only this server reads its session list, so the others don't read
    /// lists nobody sees.
    var sessionsServerID: UUID? {
        didSet { syncPages() }
    }
    /// Whether the connection settings are shown, and what may close them.
    var settingsPresentation: SettingsPresentation
    /// A failed sidebar action (opening a bot or a History chat), shown in the sidebar.
    var actionError: String?
    /// Sessions pinned to the top of their profile's list, kept across launches.
    private(set) var pins = SessionPins()
    /// The chat each profile showed last, kept across launches: picking the profile
    /// again shows it (`RootView`).
    private(set) var profileChats = ProfileChats()
    /// A profile picked in the rail whose last chat isn't shown yet: shown once it is
    /// known (`RootView.restoreProfileChat`), or dropped when a row is clicked first.
    var pendingProfileChat: PendingProfileChat?
    /// Which session sources the lists hide and which source new sessions carry, kept
    /// across launches and handed to every server's connection.
    var sourceSettings = SessionSourceSettings() {
        didSet {
            applySourceSettings()
            saveSourceSettings()
        }
    }
    /// Light or dark and the text sizes (Settings ▸ Appearance), kept across launches.
    var appearance = AppearanceSettings() {
        didSet { saveAppearance() }
    }
    /// The colours of Markdown in messages (Settings ▸ Markdown), and the app's theme they
    /// start from (Settings ▸ Appearance), kept across launches.
    var markdownColors = MarkdownColors() {
        didSet { saveMarkdownColors() }
    }

    init() {
        AppSignposts.install()
        #if DEBUG
        if let launch = UITestLaunch.current {
            // UI tests: never read or write the user's saved settings or Keychain.
            // `serverCount` servers, all the same dashboard under different names.
            let servers = (0..<launch.serverCount).map { index in
                ServerConnection(
                    config: ServerConfig(name: launch.serverCount > 1 ? "Test \(index + 1)" : "",
                                         serverURL: launch.serverURL, authMode: .sessionToken),
                    secret: launch.token)
            }
            if let delay = launch.reconnectNoticeDelay {
                for server in servers { server.connection.tryingNoticeDelay = .milliseconds(Int(delay * 1000)) }
            }
            self.servers = servers
            self.selectedServerID = servers.first?.id
            self.sessionsServerID = servers.first?.id
            self.settingsPresentation = SettingsPresentation(hasServer: true)
            if let sources = launch.sourceSettings { self.sourceSettings = sources }
            applySourceSettings()
            return
        }
        #endif
        let defaults = UserDefaults.standard
        let loaded = ServerList.load(current: defaults.data(forKey: ServerList.defaultsKey),
                                     legacy: defaults.data(forKey: ServerList.legacyDefaultsKey))
        var servers: [ServerConnection] = []
        for config in loaded.servers {
            var secret = KeychainStore.read(account: config.secretAccount) ?? ""
            if config.id == loaded.migrated?.id {
                // The single server of earlier versions: its secret moves to its own account.
                secret = KeychainStore.read(account: ServerList.legacySecretAccount) ?? ""
            }
            servers.append(ServerConnection(config: config, secret: secret))
        }
        #if os(macOS)
        if Self.runsLocalBackend { servers.insert(ServerConnection(localBackend: .hermes()), at: 0) }
        #endif
        self.servers = servers
        self.selectedServerID = servers.first?.id
        self.sessionsServerID = servers.first?.id
        self.settingsPresentation = SettingsPresentation(hasServer: servers.contains { $0.hasURL })
        if let data = defaults.data(forKey: Self.pinsKey), let saved = try? JSONDecoder().decode(SessionPins.self, from: data) {
            self.pins = saved
        }
        if let data = defaults.data(forKey: Self.profileChatsKey),
            let saved = try? JSONDecoder().decode(ProfileChats.self, from: data) {
            self.profileChats = saved
        }
        if let data = defaults.data(forKey: Self.sourceSettingsKey),
            let saved = try? JSONDecoder().decode(SessionSourceSettings.self, from: data) {
            self.sourceSettings = saved
        }
        applySourceSettings()
        if let data = defaults.data(forKey: Self.appearanceKey),
            let saved = try? JSONDecoder().decode(AppearanceSettings.self, from: data) {
            self.appearance = saved
        }
        if let data = defaults.data(forKey: Self.markdownColorsKey),
            let saved = try? JSONDecoder().decode(MarkdownColors.self, from: data) {
            self.markdownColors = saved
        }
        if let migrated = loaded.migrated, let server = servers.first(where: { $0.id == migrated.id }) {
            saveServers()
            if (try? KeychainStore.write(server.secret, account: migrated.secretAccount)) != nil {
                try? KeychainStore.write("", account: ServerList.legacySecretAccount)
            }
        }
    }

    func server(_ id: UUID?) -> ServerConnection? {
        guard let id else { return nil }
        return servers.first { $0.id == id }
    }

    var selectedServer: ServerConnection? { server(selectedServerID) }
    var activeServer: ServerConnection? { server(activeServerID) }
    var sessionsServer: ServerConnection? {
        server(sessionsServerID).flatMap { $0.hasURL ? $0 : nil } ?? sidebarServers.first
    }

    /// The servers the sidebar shows: those with an address (a server just added in
    /// the settings has none yet).
    var sidebarServers: [ServerConnection] { servers.filter(\.hasURL) }
    var isAnyConnected: Bool { servers.contains { $0.isConnected } }
    /// Whether the sidebar names each server (more than one).
    var showsServerNames: Bool { sidebarServers.count > 1 }

    // MARK: Server list

    /// A blank server, selected for editing (the one already there, if any).
    @discardableResult
    func addServer() -> ServerConnection {
        if let blank = servers.first(where: { !$0.hasURL }) {
            selectedServerID = blank.id
            return blank
        }
        let server = ServerConnection(config: ServerConfig(), secret: "")
        server.connection.sourceSettings = sourceSettings
        servers.append(server)
        selectedServerID = server.id
        if sessionsServerID == nil { sessionsServerID = server.id }
        return server
    }

    /// Disconnects and forgets a server, its secret included.
    func removeServer(_ server: ServerConnection) async {
        guard !server.isLocal else { return }
        servers.removeAll { $0 === server }
        if selectedServerID == server.id { selectedServerID = servers.first?.id }
        if activeServerID == server.id { activeServerID = nil }
        if sessionsServerID == server.id { sessionsServerID = servers.first?.id }
        pins.forgetServer(server.id)
        profileChats.forgetServer(server.id)
        if !Self.isUITest {
            saveServers()
            savePins()
            saveProfileChats()
            try? KeychainStore.write("", account: server.config.secretAccount)
        }
        await server.connection.disconnect()
    }

    private func saveServers() {
        // A server without an address isn't one yet.
        guard !Self.isUITest,
            let data = ServerList.encode(sidebarServers.filter { !$0.isLocal }.map(\.config))
        else { return }
        UserDefaults.standard.set(data, forKey: ServerList.defaultsKey)
    }

    /// Picks a profile in the rail: the middle column lists its sessions.
    func selectProfile(_ profile: String, on server: ServerConnection) {
        let picked = ProfileRef(server: server.id, profile: profile)
        if selectedProfile.map({ ProfileRef(server: $0.server.id, profile: $0.profile) }) != picked {
            pendingProfileChat = PendingProfileChat(profile: picked, listReads: server.connection.sessionListReads)
        }
        sessionsServerID = server.id
        server.connection.selectListProfile(profile)
    }

    /// The profile the rail shows as selected, as (server, profile name).
    var selectedProfile: (server: ServerConnection, profile: String)? {
        guard let server = sessionsServer, let profile = server.connection.listProfile else { return nil }
        return (server, profile)
    }

    /// Remembers the chat on screen as the one its profile shows last.
    func rememberChat(_ session: ChatSession, on server: ServerConnection) {
        guard let profile = session.profile else { return }
        let chat: ProfileChats.Chat
        switch session.kind {
        case .botChat: chat = .botChat
        case .sideChat:
            guard let id = session.storedSessionID else { return }
            chat = .session(id)
        case .session: return
        }
        guard profileChats.chat(of: profile, on: server.id) != chat else { return }
        profileChats.record(chat, of: profile, on: server.id)
        saveProfileChats()
    }

    private static let profileChatsKey = "profileChats"

    private func saveProfileChats() {
        guard !Self.isUITest, let data = try? JSONEncoder().encode(profileChats) else { return }
        UserDefaults.standard.set(data, forKey: Self.profileChatsKey)
    }

    private func syncPages() {
        let listing = sessionsServer?.id
        for server in servers {
            let page: GatewayConnection.NavigationPage = server.id == listing ? .sessions : .bots
            if server.connection.navigationPage != page { server.connection.navigationPage = page }
        }
    }

    // MARK: Connections

    /// Saves the servers and (re)connects this one.
    func connect(_ server: ServerConnection) async {
        guard !server.isConnecting else { return }
        server.isConnecting = true
        defer { server.isConnecting = false }
        server.lastError = nil
        if server.secret.isEmpty, !server.isLocal {
            // Never saved, or the Keychain refused to hand it over (an unsigned debug build
            // gets a new identity on every build): say so, rather than send an empty
            // password and report it as rejected.
            server.lastError = "No \(server.config.authMode.secretLabel.lowercased()) for \(server.name). Enter it in Settings."
            return
        }
        do {
            #if os(macOS)
            if let backend = server.backend {
                // (Re)started if it isn't running: a new port and token each time.
                let running = try await backend.start()
                server.config.serverURL = running.url
                server.secret = running.token
            }
            #endif
            let endpoint = try GatewayEndpoint(server.config.serverURL)
            if !Self.isUITest, !server.isLocal {
                saveServers()
                do {
                    try KeychainStore.write(server.secret, account: server.config.secretAccount)
                } catch {
                    // Still connect with the in-memory secret, but say it won't survive a relaunch.
                    server.lastError = error.localizedDescription
                }
            }
            if server.connectedEndpoint != endpoint {
                // Another address: its sessions must not stay on screen or be restored.
                await server.connection.disconnect()
                if activeServerID == server.id { activeServerID = nil }
            }
            #if DEBUG
            let connector = DashboardConnector(
                endpoint: endpoint, credential: server.config.credential(secret: server.secret),
                makeSocket: { UITestSubmitNetwork.wrap(URLSessionWebSocketTransport(request: $0)) })
            #else
            let connector = DashboardConnector(endpoint: endpoint, credential: server.config.credential(secret: server.secret))
            #endif
            try await server.connection.connect(using: connector)
            server.connectedEndpoint = endpoint
            syncPages()
            #if DEBUG
            if let profile = UITestLaunch.current?.profile {
                server.connection.selectListProfile(profile)
            }
            #endif
        } catch is CancellationError {
            // Superseded by a newer connect/disconnect.
        } catch {
            server.lastError = GatewayConnection.describe(error)
        }
    }

    /// The settings' Connect: connects the server and, unless it failed, closes them.
    func connectFromSettings(_ server: ServerConnection) async {
        await connect(server)
        if server.isConnected, server.lastError == nil { settingsPresentation.close() }
    }

    /// Launch, or back from the background (iOS): every server with an address that
    /// isn't connected or on its way there, all at once.
    func connectAll() async {
        let idle = servers.filter { server in
            guard server.hasURL, !server.isConnecting else { return false }
            switch server.connection.state {
            case .disconnected, .failed: return true
            case .connecting, .connected, .reconnecting: return false
            }
        }
        await withTaskGroup(of: Void.self) { group in
            for server in idle {
                group.addTask { await self.connect(server) }
            }
        }
    }

    func disconnect(_ server: ServerConnection) async {
        await server.connection.disconnect()
        #if os(macOS)
        // This Mac's backend runs only while the app uses it.
        await server.backend?.stop()
        #endif
        server.connectedEndpoint = nil
        if activeServerID == server.id { activeServerID = nil }
        actionError = nil
    }

    #if os(macOS)
    // MARK: This Mac

    private static let localBackendKey = "localBackend.enabled"

    /// Whether the app runs a Hermes backend on this Mac (on unless turned off; never
    /// under UI tests).
    static var runsLocalBackend: Bool {
        !isUITest && UserDefaults.standard.object(forKey: localBackendKey) as? Bool ?? true
    }

    var localServer: ServerConnection? { servers.first { $0.isLocal } }

    /// Turns "This Mac" on (started and connected) or off (stopped and removed).
    func setRunsLocalBackend(_ isOn: Bool) async {
        UserDefaults.standard.set(isOn, forKey: Self.localBackendKey)
        if isOn, localServer == nil {
            let server = ServerConnection(localBackend: .hermes())
            server.connection.sourceSettings = sourceSettings
            servers.insert(server, at: 0)
            selectedServerID = server.id
            await connect(server)
        } else if !isOn, let server = localServer {
            servers.removeAll { $0 === server }
            if selectedServerID == server.id { selectedServerID = servers.first?.id }
            if activeServerID == server.id { activeServerID = nil }
            if sessionsServerID == server.id { sessionsServerID = sidebarServers.first?.id }
            await server.connection.disconnect()
            await server.backend?.stop()
        }
    }

    /// The backend died (crashed, `hermes serve --stop`, an update): start a new one and
    /// connect to it, instead of retrying a port nobody listens on. Runs for the app's life.
    func watchLocalBackend() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(5))
            guard let server = localServer, let backend = server.backend, !server.isConnecting,
                server.connectedEndpoint != nil
            else { continue }
            switch server.connection.state {
            case .reconnecting, .failed:
                if await !backend.isRunning { await connect(server) }
            case .connected, .connecting, .disconnected:
                break
            }
        }
    }

    /// App quit: asks the backend to stop now (its parent watchdog would stop it anyway).
    func terminateLocalBackend() {
        localServer?.backend?.terminateNow()
    }
    #endif

    // MARK: Session sources

    private static let sourceSettingsKey = "sessionSourceSettings"

    /// Every source a connected server's list has shown, hidden ones included, so a
    /// hidden source can be shown again.
    var knownSources: [String] {
        var sources = sourceSettings.hiddenSources
        for server in servers { sources.formUnion(server.connection.historySources) }
        return sources.sorted { SessionSourceSettings.label(for: $0) < SessionSourceSettings.label(for: $1) }
    }

    private func applySourceSettings() {
        for server in servers { server.connection.sourceSettings = sourceSettings }
    }

    private func saveSourceSettings() {
        guard !Self.isUITest, let data = try? JSONEncoder().encode(sourceSettings) else { return }
        UserDefaults.standard.set(data, forKey: Self.sourceSettingsKey)
    }

    // MARK: Session actions

    private static let pinsKey = "sessionPins"

    func isPinned(_ entry: HistoryEntry, on server: ServerConnection) -> Bool {
        pins.isPinned(entry, on: server.id)
    }

    func setPinned(_ pinned: Bool, _ entry: HistoryEntry, on server: ServerConnection) {
        pins.setPinned(pinned, entry, on: server.id)
        savePins()
    }

    private static let appearanceKey = "appearance"
    private static let markdownColorsKey = "markdownColors"

    private func saveAppearance() {
        #if os(macOS)
        AppearanceTheme.apply(appearance.theme)
        #endif
        guard !Self.isUITest, let data = try? JSONEncoder().encode(appearance) else { return }
        UserDefaults.standard.set(data, forKey: Self.appearanceKey)
    }

    private func saveMarkdownColors() {
        guard !Self.isUITest, let data = try? JSONEncoder().encode(markdownColors) else { return }
        UserDefaults.standard.set(data, forKey: Self.markdownColorsKey)
    }

    private func savePins() {
        guard !Self.isUITest, let data = try? JSONEncoder().encode(pins) else { return }
        UserDefaults.standard.set(data, forKey: Self.pinsKey)
    }

    /// Renames a row. `session.title` needs the chat open, so a row that isn't is opened
    /// first, as a click would: the user sees the chat they renamed.
    func rename(_ entry: HistoryEntry, to title: String, on server: ServerConnection) async {
        let connection = server.connection
        do {
            do {
                try await connection.rename(entry, to: title)
            } catch SessionActionError.notOpen {
                activeServerID = server.id
                try await connection.open(entry)
                try await connection.rename(entry, to: title)
            }
        } catch {
            actionError = describe(error, on: server)
        }
    }

    func archive(_ entry: HistoryEntry, on server: ServerConnection) async {
        await perform(on: server) {
            try await server.connection.archive(entry)
            setPinned(false, entry, on: server)
        }
    }

    func delete(_ entry: HistoryEntry, on server: ServerConnection) async {
        await perform(on: server) {
            try await server.connection.delete(entry)
            setPinned(false, entry, on: server)
        }
    }

    /// Copies the row into a new session and shows the copy.
    func fork(_ entry: HistoryEntry, on server: ServerConnection) async {
        activeServerID = server.id
        await perform(on: server) { _ = try await server.connection.fork(entry) }
    }

    /// A new chat holding `session`'s conversation up to `item`, shown (Branch in New Chat).
    func branch(_ session: ChatSession, at item: TranscriptItem, on server: ServerConnection) async {
        activeServerID = server.id
        await perform(on: server) { _ = try await server.connection.branch(session, at: item) }
    }

    private func perform(on server: ServerConnection, _ action: () async throws -> Void) async {
        do {
            try await action()
        } catch {
            actionError = describe(error, on: server)
        }
    }

    /// Pull-to-refresh: every roster, and the visible profile’s sessions.
    func refreshLists() async {
        for server in servers where server.isConnected {
            do {
                try await server.connection.refreshBots()
                await server.connection.refreshSessionListIfVisible()
            } catch {
                actionError = describe(error, on: server)
            }
        }
    }

    /// Calls the public `/api/status` to check the URL before signing in.
    func probe(_ server: ServerConnection) async {
        server.probeResult = nil
        do {
            let endpoint = try GatewayEndpoint(server.config.serverURL)
            let status = try await DashboardClient(endpoint: endpoint).status()
            var parts = ["Hermes \(status.version ?? "?")"]
            if status.authRequired == true {
                parts.append("sign-in required (\((status.authFlows ?? []).joined(separator: ", ")))")
            } else {
                parts.append("no sign-in required")
            }
            server.probeResult = parts.joined(separator: " · ")
        } catch {
            server.probeResult = "Unreachable: \(GatewayConnection.describe(error))"
        }
    }

    /// An error message, naming the server when there are several.
    func describe(_ error: any Error, on server: ServerConnection) -> String {
        let message = GatewayConnection.describe(error)
        return showsServerNames ? "\(server.name): \(message)" : message
    }
}

#if DEBUG
/// Set by the UI tests (`Apps/UITests`) in the launch environment: connect to this
/// dashboard with a `?token=` and list this profile's sessions. With
/// `HERMES_UITEST_SERVERS`, the app lists the dashboard that many times, as servers
/// named "Test 1", "Test 2"….
struct UITestLaunch {
    var serverURL: String
    var token: String
    var profile: String?
    var serverCount = 1
    /// The sockets are gone when the app comes back from the background, as on a real
    /// iPhone (the simulator keeps them).
    var dropsSocketsInBackground = false
    /// Seconds a reconnect stays quiet (`GatewayConnection.tryingNoticeDelay`), if not 5.
    var reconnectNoticeDelay: Double?
    /// Settings ▸ Session Sources, as JSON (`SessionSourceSettings`), if not the defaults.
    var sourceSettings: SessionSourceSettings?

    static let current: UITestLaunch? = {
        let env = ProcessInfo.processInfo.environment
        guard let url = env["HERMES_UITEST_URL"], let token = env["HERMES_UITEST_TOKEN"],
            !url.isEmpty, !token.isEmpty
        else { return nil }
        return UITestLaunch(serverURL: url, token: token, profile: env["HERMES_UITEST_PROFILE"],
                            serverCount: max(1, Int(env["HERMES_UITEST_SERVERS"] ?? "") ?? 1),
                            dropsSocketsInBackground: env["HERMES_UITEST_DROP_IN_BACKGROUND"] == "1",
                            reconnectNoticeDelay: env["HERMES_UITEST_RECONNECT_NOTICE_DELAY"].flatMap(Double.init),
                            sourceSettings: env["HERMES_UITEST_SOURCE_SETTINGS"].flatMap {
                                try? JSONDecoder().decode(SessionSourceSettings.self, from: Data($0.utf8))
                            })
    }()
}

/// UI tests only (`SendStateUITests`): a bad network for one message, picked by its text.
/// With `HERMES_UITEST_SUBMIT_DELAY` (seconds), a `prompt.submit` whose text holds
/// `SLOW-` waits that long before it goes out, as on a stalled uplink; one holding
/// `LOST-` never goes out and the socket drops, as when the network goes mid-send.
/// Everything else, and every send outside UI tests, goes straight through.
final class UITestSubmitNetwork: MessageTransport {
    private let base: any MessageTransport
    private let delay: Duration

    static func wrap(_ base: any MessageTransport) -> any MessageTransport {
        guard UITestLaunch.current != nil,
            let seconds = ProcessInfo.processInfo.environment["HERMES_UITEST_SUBMIT_DELAY"].flatMap(Double.init)
        else { return base }
        return UITestSubmitNetwork(base: base, delay: .milliseconds(Int(seconds * 1000)))
    }

    private init(base: any MessageTransport, delay: Duration) {
        self.base = base
        self.delay = delay
    }

    func connect() async throws { try await base.connect() }
    var inbound: AsyncThrowingStream<String, any Error> { base.inbound }
    func close() async { await base.close() }

    func send(_ text: String) async throws {
        if text.contains("\"prompt.submit\"") {
            if text.contains("LOST-") { throw TransportError.closed(code: nil, reason: "UI test: network lost") }
            if text.contains("SLOW-") { try await Task.sleep(for: delay) }
        }
        try await base.send(text)
    }
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
