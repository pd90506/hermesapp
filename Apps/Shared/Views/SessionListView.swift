import HermesKit
import HermesProtocol
import SwiftUI

/// What the sidebar can select. Every row belongs to one server.
enum SidebarItem: Hashable {
    /// A bot, by profile name. Selecting it opens its one Bot Chat.
    case bot(server: UUID, profile: String)
    /// A Sessions row, by `HistoryEntry.id`.
    case history(server: UUID, id: String)

    var server: UUID {
        switch self {
        case .bot(let server, _), .history(let server, _): server
        }
    }
}

/// The middle column: the profile picked in the profile rail, its Bot Chat pinned
/// first, then its sessions.
///
/// - Pinned at the top, the profile's name (and server, with several) and New chat
///   (`SessionListHeader`); rows scroll under it.
/// - One toolbar button (Settings).
/// - At the bottom, the error and "waiting" banners and a fixed-height footer with the
///   connection status.
/// Rows and controls are in `SidebarControls.swift`; pointer feedback in `Hover.swift`.
struct SessionListView: View {
    @Environment(AppModel.self) private var model
    @Binding var selection: SidebarItem?
    /// Shows the chat a side chat was started for (on iPhone, pushes it).
    var showChat: () -> Void = {}
    /// One side chat at a time: repeated clicks while one is being created do nothing.
    @State private var isStartingChat = false

    var body: some View {
        @Bindable var model = model
        List(selection: $selection) {
            if let server = model.sessionsServer {
                botChatSection(server)
                sessionsSection(server)
            }
        }
        .navigationTitle(profileName ?? "Sessions")
        #if os(iOS)
        // The header shows the name; the navigation title stays for the back button.
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(removing: .title)
        #endif
        .refreshable { await model.refreshLists() }
        // Pinned above the list: it never scrolls away; rows scroll under it.
        .safeAreaBar(edge: .top) {
            SessionListHeader(title: profileName ?? "No profile",
                              subtitle: model.showsServerNames ? model.sessionsServer?.name : nil,
                              newChat: newChatRow)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                banners
                SidebarFooter(status: statusText, color: statusColor) { EmptyView() }
            }
            // The list scrolls under this inset; without a bar behind it, rows
            // showed through the status text.
            .background(.bar)
            .overlay(alignment: .top) { Divider() }
        }
        .toolbar {
            SettingsToolbarItem(presentation: $model.settingsPresentation)
        }
        .task(id: sessionListKey) {
            await model.sessionsServer?.connection.refreshSessionListIfVisible()
        }
        .task(id: model.isAnyConnected) {
            // Keeps previews and activity dots current (Desktop re-reads the roster every 5 s).
            guard model.isAnyConnected else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15))
                for server in model.servers where server.isConnected {
                    server.connection.refreshListsInBackground()
                }
            }
        }
        #if os(macOS)
        .navigationSplitViewColumnWidth(min: 260, ideal: 320, max: 480)
        #endif
    }

    /// The profile's one ongoing chat, above its other sessions.
    @ViewBuilder private func botChatSection(_ server: ServerConnection) -> some View {
        let connection = server.connection
        if let bot = connection.listProfileBot {
            let item = SidebarItem.bot(server: server.id, profile: bot.name)
            Section {
                BotRow(bot: bot, activity: connection.activity(for: bot))
                    .sidebarRowHover(isSelected: selection == item)
                    .tag(item)
                    .contextMenu {
                        Button("New Side Chat", systemImage: "plus.bubble") { startSideChat(with: bot, on: server) }
                            .disabled(!server.isConnected || isStartingChat)
                    }
            } header: {
                Text(Bot.chatTitle)
            }
        }
    }

    @ViewBuilder private func sessionsSection(_ server: ServerConnection) -> some View {
        let connection = server.connection
        Section {
            // Only before the first rows: background refreshes keep the list still.
            if connection.sessionListLoading && connection.history.isEmpty {
                ProgressView("Loading sessions…")
            }
            if let error = connection.sessionListError {
                Text(error).foregroundStyle(.red)
                Button("Retry") { Task { await connection.refreshSessionList() } }
                    .hoverButtonStyle(padding: 4)
                    .foregroundStyle(.tint)
            }
            if connection.bots.isEmpty {
                Text(server.isConnected ? "No profiles available" : "Connect to browse sessions")
                    .foregroundStyle(.secondary)
            } else if connection.history.isEmpty && !connection.sessionListLoading
                        && connection.sessionListError == nil {
                Text("No sessions yet")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach(connection.history) { entry in
                let item = SidebarItem.history(server: server.id, id: entry.id)
                HistoryRow(entry: entry, botName: displayName(of: entry.profile, on: server))
                    .sidebarRowHover(isSelected: selection == item)
                    .tag(item)
            }
        } header: {
            if model.showsServerNames {
                header(server)
            } else {
                Text("Sessions")
            }
        }
    }

    private var profileName: String? {
        model.sessionsServer?.connection.listProfileBot?.displayName
    }

    private func header(_ server: ServerConnection) -> some View {
        let state = server.connection.state
        // Not connected because of something the user can fix (no password): say what.
        let status = state == .connected ? state.statusText : server.lastError ?? state.statusText
        let color = state != .connected && server.lastError != nil ? Color.red : state.statusColor
        return ServerSectionHeader(name: server.name, status: status, color: color,
                                   isConnected: server.isConnected)
    }

    /// Re-reads the session list when its server, profile or connection changes.
    private var sessionListKey: String {
        guard let server = model.sessionsServer else { return "" }
        let connection = server.connection
        return "\(server.id):\(connection.listProfile ?? ""):\(server.isConnected)"
    }

    /// Above the footer, so they never push the rows (or New chat) around.
    @ViewBuilder private var banners: some View {
        if let error = model.actionError {
            HStack(alignment: .top) {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                Spacer()
                Button("Dismiss", systemImage: "xmark") { model.actionError = nil }
                    .labelStyle(.iconOnly)
                    .hoverButtonStyle(.circle)
            }
            .padding(.horizontal)
            .padding(.vertical, 6)
        }
        if waitingCount > 0 {
            Label("\(waitingCount) chat(s) waiting for you", systemImage: "hand.raised.fill")
                .font(.callout)
                .foregroundStyle(.orange)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal)
                .padding(.vertical, 6)
        }
    }

    /// Chats with a question for the user that isn't on screen: every server's
    /// background chats, plus another server's open chat.
    private var waitingCount: Int {
        model.servers.reduce(0) { count, server in
            let connection = server.connection
            let hiddenActive = server.id != model.activeServerID
                && connection.activeSession?.transcript.pendingRequests.isEmpty == false
            return count + connection.otherSessionRequests.count + (hiddenActive ? 1 : 0)
        }
    }

    private var newChatRow: NewChatRow? {
        guard let server = model.sessionsServer else { return nil }
        let connection = server.connection
        return NewChatRow(isEnabled: connection.canStartListChat && !isStartingChat,
                          disabledReason: newChatDisabledReason(server)) {
            if let bot = connection.listProfileBot { startSideChat(with: bot, on: server) }
        }
    }

    private func newChatDisabledReason(_ server: ServerConnection) -> String? {
        if !server.isConnected { return "Connect to your Hermes gateway first." }
        if server.connection.listProfileBot == nil { return "Pick a profile first." }
        if isStartingChat { return "A new chat is being created." }
        return nil
    }

    /// One server: its status as before. Several: how many are connected (each
    /// section header has its own).
    private var statusText: String {
        let servers = model.sidebarServers
        guard servers.count > 1 else { return servers.first?.connection.state.statusText ?? "No server" }
        let connected = servers.filter(\.isConnected).count
        return connected == servers.count
            ? "All \(connected) servers connected" : "\(connected) of \(servers.count) servers connected"
    }

    private var statusColor: Color {
        let servers = model.sidebarServers
        guard servers.count > 1 else { return servers.first?.connection.state.statusColor ?? .gray }
        let connected = servers.filter(\.isConnected).count
        if connected == servers.count { return .green }
        return connected > 0 ? .yellow : .red
    }

    private func displayName(of profile: String, on server: ServerConnection) -> String {
        server.connection.bots.first { $0.name == profile }?.displayName ?? profile
    }

    private func startSideChat(with bot: Bot, on server: ServerConnection) {
        guard !isStartingChat else { return }
        isStartingChat = true
        selection = nil
        // The chat area follows this server at once, so it shows the new chat opening.
        model.activeServerID = server.id
        Task {
            defer { isStartingChat = false }
            do {
                try await server.connection.newSideChat(profile: bot.name)
                showChat()
            } catch {
                model.actionError = model.describe(error, on: server)
            }
        }
    }
}
