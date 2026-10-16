import HermesKit
import HermesProtocol
import SwiftUI

/// Profile rail + session list + chat. Used by both apps; on iPhone the split view
/// collapses into a navigation stack automatically (profiles → sessions → chat).
struct RootView: View {
    @Environment(AppModel.self) private var model
    @State private var selection: SidebarItem?
    /// The column shown when the split view is collapsed (iPhone). Starts on the
    /// session list, one Back away from the profiles. A new side chat has no row to
    /// select until the list catches up, so it is shown through this.
    @State private var compactColumn = NavigationSplitViewColumn.content
    @State private var columns = NavigationSplitViewVisibility.all

    var body: some View {
        NavigationSplitView(columnVisibility: $columns, preferredCompactColumn: $compactColumn) {
            ProfileRailView(showSessions: { compactColumn = .content })
        } content: {
            SessionListView(
                selection: Binding(
                    get: { selection },
                    set: { item in
                        selection = item
                        if let item { Task { await open(item) } }
                    }),
                showChat: { compactColumn = .detail })
        } detail: {
            if let server = model.activeServer, let opening = server.connection.opening {
                // A first open: the chat's frame at once, not the previous chat.
                OpeningChatView(title: title(of: opening, on: server))
                    .titleBarBand()
            } else if let server = model.activeServer, let session = server.connection.activeSession {
                ChatView(session: session, title: title(of: session, on: server))
                    .id(session.id)  // a fresh composer per chat
                    .environment(server)
            } else {
                ContentUnavailableView(
                    "No Chat Selected", systemImage: "bubble.left.and.bubble.right",
                    description: Text(model.isAnyConnected ? "Pick a profile, then a session to chat with." : "Connect to your Hermes gateway."))
                .titleBarBand()
            }
        }
        // The settings sheet, from the gear or because the app must connect
        // (`SettingsPresentation`).
        .sheet(isPresented: Binding(
            get: { model.settingsPresentation.isShown },
            set: { if !$0 { model.settingsPresentation.close() } })) {
            NavigationStack {
                ConnectionSettingsView(isSheet: true)
            }
            #if os(macOS)
            // Opened from the gear, a click elsewhere in the window closes it as Done
            // would; the must-connect sheet ignores such clicks.
            .onParentWindowClick(isEnabled: model.settingsPresentation.isTransient) {
                model.settingsPresentation.clickedOutside()
            }
            .frame(minWidth: 460, minHeight: 420)
            #endif
        }
        // The chat on screen can change without a click: dropped on reconnect,
        // cleared on a server switch, or a new side chat. Follow it, so the
        // highlighted row is always the one on screen and clicking a row always opens it.
        .onChange(of: model.activeServer?.connection.activeSession?.id) { _, _ in followActiveChat() }
        // A click on another server's row moves `activeServerID` before its chat opens,
        // so only a server that stopped showing anything (disconnected, removed) clears it.
        .onChange(of: model.activeServerID) { _, id in if id == nil { followActiveChat() } }
        .task {
            // Auto-connect on launch when settings exist.
            if model.servers.contains(where: \.hasURL) {
                await model.connectAll()
                if !model.isAnyConnected { model.settingsPresentation.requireConnection() }
            }
        }
    }

    private func followActiveChat() {
        let shown = model.activeServer.flatMap { item(for: $0.connection.activeSession, on: $0) }
        if selection != shown { selection = shown }
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

extension View {
    /// On macOS, the title bar's glass over a detail view that has no scroll view of its
    /// own (no chat, a chat opening), as over the session list and the chat (their hard
    /// scroll edge), so the title bars across the window always read as one band.
    @ViewBuilder func titleBarBand() -> some View {
        #if os(macOS)
        ScrollView {
            self.containerRelativeFrame([.horizontal, .vertical])
        }
        .scrollDisabled(true)
        .scrollEdgeEffectStyle(.hard, for: .top)
        #else
        self
        #endif
    }
}
