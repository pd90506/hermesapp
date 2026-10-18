import HermesKit
import HermesProtocol
import SwiftUI

/// Profile rail + session list + chat (`split`). Used by both apps.
struct RootView: View {
    @Environment(AppModel.self) private var model
    @State private var selection: SidebarItem?
    /// The column shown when the split view is collapsed (iPhone). Starts on the
    /// session list, one Back away from the profiles. A new side chat has no row to
    /// select until the list catches up, so it is shown through this.
    @State private var compactColumn = NavigationSplitViewColumn.content
    @State private var columns = NavigationSplitViewVisibility.all
    #if os(macOS)
    @Environment(\.openSettings) private var openSettings
    #endif

    var body: some View {
        split
        #if os(macOS)
        // The sidebar, always: dragging its edge (or the sidebar shortcut) could collapse
        // it, with nothing to bring the profiles back.
        .onChange(of: columns) { _, visibility in
            if visibility != .all { columns = .all }
        }
        #endif
        #if os(macOS)
        // The app must connect (`SettingsPresentation`): the Settings window, as the gear
        // opens it (`ProfileRailView`). The window stays until the user closes it.
        .onChange(of: model.settingsPresentation.isShown, initial: true) { _, isShown in
            guard isShown else { return }
            openSettings()
            model.settingsPresentation.close()
        }
        #else
        // The settings sheet, from the gear or because the app must connect
        // (`SettingsPresentation`).
        .sheet(isPresented: Binding(
            get: { model.settingsPresentation.isShown },
            set: { if !$0 { model.settingsPresentation.close() } })) {
            NavigationStack {
                ConnectionSettingsView()
            }
        }
        #endif
        // The chat on screen can change without a click: dropped on reconnect,
        // cleared on a server switch, or a new side chat. Follow it, so the
        // highlighted row is always the one on screen and clicking a row always opens it.
        .onChange(of: model.activeServer?.connection.activeSession?.id) { _, _ in followActiveChat() }
        // A click on another server's row moves `activeServerID` before its chat opens,
        // so only a server that stopped showing anything (disconnected, removed) clears it.
        .onChange(of: model.activeServerID) { _, id in if id == nil { followActiveChat() } }
        // Whichever way a chat came on screen (a click, a new side chat, a fork), its
        // profile shows it next time. A new chat's stored id can come after it opens.
        .onChange(of: activeChatKey) { _, _ in
            if let server = model.activeServer, let session = server.connection.activeSession {
                model.rememberChat(session, on: server)
            }
        }
        // Picking another profile in the rail shows the chat it showed last: its Bot
        // Chat, or a session once its list confirms the session is still there.
        .onChange(of: model.pendingProfileChat) { _, _ in restoreProfileChat() }
        .onChange(of: shownProfile) { _, _ in restoreProfileChat() }
        .task {
            // Auto-connect on launch when settings exist.
            if model.servers.contains(where: \.hasURL) {
                await model.connectAll()
                if !model.isAnyConnected { model.settingsPresentation.requireConnection() }
            }
        }
    }

    /// On macOS, as in Mail: one sidebar, the profile rail beside the session list on the
    /// same glass panel (the window buttons sit on it), and the chat. On iOS three
    /// columns; on iPhone they collapse into a navigation stack (profiles → sessions → chat).
    @ViewBuilder private var split: some View {
        #if os(macOS)
        NavigationSplitView(columnVisibility: $columns) {
            HStack(spacing: 0) {
                ProfileRailView()
                Divider()
                sessionList
            }
            // Always shown (`body` also undoes a collapse): the rail is the only way to
            // switch profiles. The rail keeps its width; the session list takes the rest.
            .toolbar(removing: .sidebarToggle)
            .navigationSplitViewColumnWidth(min: ProfileRailItem.width + 1 + 260,
                                            ideal: ProfileRailItem.width + 1 + 320,
                                            max: ProfileRailItem.width + 1 + 480)
        } detail: {
            chat
        }
        #else
        NavigationSplitView(columnVisibility: $columns, preferredCompactColumn: $compactColumn) {
            ProfileRailView(showSessions: { compactColumn = .content })
        } content: {
            sessionList
        } detail: {
            chat
        }
        #endif
    }

    private var sessionList: some View {
        SessionListView(
            selection: Binding(
                get: { selection },
                set: { item in
                    selection = item
                    if let item {
                        model.pendingProfileChat = nil
                        Task { await open(item) }
                    }
                }),
            showChat: { compactColumn = .detail })
    }

    private var chat: some View {
        Group {
            if let server = model.activeServer, let opening = server.connection.opening {
                // A first open: the chat's frame at once, not the previous chat.
                OpeningChatView(title: title(of: opening, on: server))
            } else if let server = model.activeServer, let session = server.connection.activeSession {
                ChatView(session: session, title: title(of: session, on: server))
                    .id(session.id)  // a fresh composer per chat
                    .environment(server)
            } else {
                ContentUnavailableView(
                    "No Chat Selected", systemImage: "bubble.left.and.bubble.right",
                    description: Text(model.isAnyConnected ? "Pick a profile, then a session to chat with." : "Connect to your Hermes gateway."))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func followActiveChat() {
        let shown = model.activeServer.flatMap { item(for: $0.connection.activeSession, on: $0) }
        if selection != shown { selection = shown }
    }

    private var activeChatKey: String? {
        guard let session = model.activeServer?.connection.activeSession else { return nil }
        return "\(session.id)/\(session.storedSessionID ?? "")"
    }

    /// The profile the session list shows, and how far its list is read.
    private var shownProfile: ShownProfile? {
        guard let selected = model.selectedProfile else { return nil }
        let connection = selected.server.connection
        return ShownProfile(server: selected.server.id, profile: selected.profile,
                            listRead: connection.historyProfile == selected.profile,
                            listReads: connection.sessionListReads,
                            listFailed: connection.sessionListError != nil)
    }

    private func restoreProfileChat() {
        guard let pending = model.pendingProfileChat, let shown = shownProfile, shown.ref == pending.profile,
            let server = model.server(shown.server)
        else { return }
        let history = shown.listRead ? server.connection.history : nil
        let item: SidebarItem
        switch model.profileChats.restore(shown.profile, on: server.id, history: history,
                                          isCurrent: shown.listReads > pending.listReads) {
        case .botChat: item = .bot(server: server.id, profile: shown.profile)
        case .session(let entry): item = .history(server: server.id, id: entry.id)
        case .waitForList:
            // A list that can't be read can't confirm the session: the Bot Chat meanwhile.
            guard shown.listFailed else { return }
            item = .bot(server: server.id, profile: shown.profile)
        }
        model.pendingProfileChat = nil
        guard selection != item else { return }
        selection = item
        Task { await open(item) }
    }

    /// The sidebar row for a chat, if it has one.
    private func item(for session: ChatSession?, on server: ServerConnection) -> SidebarItem? {
        guard let session, let profile = session.profile else { return nil }
        switch session.kind {
        case .botChat: return .bot(server: server.id, profile: profile)
        case .sideChat:
            return server.connection.history
                .first { $0.profile == profile && $0.summary.id == session.storedSessionID }
                .map { .history(server: server.id, id: $0.id) }
        case .session: return nil
        }
    }

    private func open(_ item: SidebarItem) async {
        guard let server = model.server(item.server) else { return }
        // The chat area follows the row's server at once, so it shows the chat opening.
        model.activeServerID = server.id
        do {
            switch item {
            case .bot(_, let profile):
                // Resolved by name on every click; HermesKit never creates a second Bot Chat.
                try await server.connection.openBotChat(profile: profile)
            case .history(_, let id):
                guard let entry = server.connection.history.first(where: { $0.id == id }) else { return }
                try await server.connection.open(entry)
            }
            model.actionError = nil
        } catch is CancellationError {
            // Opened on a socket that was since replaced: let a click on the same row retry.
            if selection == item { selection = nil }
        } catch {
            model.actionError = model.describe(error, on: server)
            // Clear the selection so clicking the same row again retries.
            if selection == item { selection = nil }
        }
    }

    private func title(of opening: PendingChat, on server: ServerConnection) -> String {
        let botName = server.connection.bots.first { $0.name == opening.profile }?.displayName ?? opening.profile
        switch opening.kind {
        case .botChat: return botName ?? "Hermes"
        case .sideChat:
            let title = opening.title?.isEmpty == false ? opening.title! : "Side chat"
            return botName.map { "\(title) · \($0)" } ?? title
        case .session: return opening.title?.isEmpty == false ? opening.title! : "Chat"
        }
    }

    private func title(of session: ChatSession, on server: ServerConnection) -> String? {
        let botName = server.connection.bots.first { $0.name == session.profile }?.displayName ?? session.profile
        switch session.kind {
        case .botChat: return botName
        case .sideChat:
            let title = session.title?.isEmpty == false ? session.title! : "Side chat"
            return botName.map { "\(title) · \($0)" } ?? title
        case .session: return nil
        }
    }
}

/// A profile in the session list, by server and name.
private struct ShownProfile: Equatable {
    var server: UUID
    var profile: String
    /// Whether its session list has been read, and how many lists its server has read.
    var listRead: Bool
    var listReads: Int
    var listFailed: Bool

    var ref: ProfileRef { ProfileRef(server: server, profile: profile) }
}

/// The frame of a chat being opened: its title and a spinner where the transcript goes.
private struct OpeningChatView: View {
    let title: String

    var body: some View {
        ProgressView()
            .controlSize(.small)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle(title)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .accessibilityLabel("Opening \(title)")
    }
}
