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
/// - On macOS the profile's name (and server) is the column's title, in the title bar
///   level with the window buttons. Pinned at the top, New chat (`SessionListHeader`,
///   which also shows the name on iOS); rows scroll under it.
/// - Each session has Pin, Rename, Fork, Archive and Delete, in its context menu and its
///   "…" button; pinned sessions list first.
/// - Settings is at the bottom of the profile rail (on iPhone, a toolbar button here).
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
    /// The row being renamed, and the title typed so far.
    @State private var renaming: HistoryEntry?
    @State private var newTitle = ""
    /// The row waiting for the user to confirm its deletion.
    @State private var deleting: HistoryEntry?
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    #endif

    var body: some View {
        #if os(iOS)
        @Bindable var model = model
        #endif
        List(selection: $selection) {
            if let server = model.sessionsServer {
                botChatSection(server)
                pinnedSection(server)
                sessionsSection(server)
            }
        }
        #if os(macOS)
        .listStyle(.sidebar)
        #endif
        .navigationTitle(profileName ?? "Sessions")
        #if os(macOS)
        .toolbar {
            // The column's own title, at its leading edge in the title bar, level with
            // the window buttons in the rail.
            ToolbarItem(placement: .navigation) {
                ColumnTitle(title: profileName ?? "No profile", subtitle: subtitle)
            }
            .sharedBackgroundVisibility(.hidden)
        }
        .toolbar(removing: .title)
        // The hard edge style: the title bar's glass shows over the header all the
        // time, down to its bottom edge, not only while the pointer is over the title
        // bar or once rows scroll under it. (Not `toolbarBackgroundVisibility`: the
        // window has one toolbar background, and the chat hides it.)
        .scrollEdgeEffectStyle(.hard, for: .top)
        #else
        // The header shows the name; the navigation title stays for the back button.
        .toolbar(removing: .title)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .refreshable { await model.refreshLists() }
        // Pinned above the list: it never scrolls away; rows scroll under it.
        .safeAreaBar(edge: .top) {
            #if os(macOS)
            SessionListHeader(newChat: newChatRow)
            #else
            SessionListHeader(title: profileName ?? "No profile",
                              subtitle: subtitle,
                              newChat: newChatRow)
            #endif
        }
        // A bar like the header's: rows fade out under it instead of showing through the
        // status text, and it keeps the sidebar's material (an opaque .bar did not).
        .safeAreaBar(edge: .bottom) {
            VStack(spacing: 0) {
                banners
                SidebarFooter(status: statusText, color: statusColor) { EmptyView() }
            }
        }
        #if os(iOS)
        // On iPhone the rail is a screen away; on iPad its bottom has the gear.
        .toolbar {
            if sizeClass == .compact {
                SettingsToolbarItem(presentation: $model.settingsPresentation)
            }
        }
        #endif
        .alert("Rename Chat", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Title", text: $newTitle)
            Button("Cancel", role: .cancel) { renaming = nil }
            Button("Rename") { commitRename() }
                .keyboardShortcut(.defaultAction)
        }
        .confirmationDialog(deleteQuestion, isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            titleVisibility: .visible) {
            Button("Delete", role: .destructive) { commitDelete() }
            Button("Cancel", role: .cancel) { deleting = nil }
        } message: {
            Text("Its messages are deleted from Hermes for good.")
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
            ForEach(model.pins.split(connection.history, on: server.id).others) { entry in
                sessionRow(entry, on: server)
            }
        } header: {
            Text("Sessions")
        }
    }

    /// Pinned sessions, above the rest, while there are any.
    @ViewBuilder private func pinnedSection(_ server: ServerConnection) -> some View {
        let pinned = model.pins.split(server.connection.history, on: server.id).pinned
        if !pinned.isEmpty {
            Section {
                ForEach(pinned) { entry in
                    sessionRow(entry, on: server)
                }
            } header: {
                Text("Pinned")
            }
        }
    }

    private func sessionRow(_ entry: HistoryEntry, on server: ServerConnection) -> some View {
        let item = SidebarItem.history(server: server.id, id: entry.id)
        return HistoryRow(entry: entry) {
            sessionActions(entry, on: server)
        }
        .sidebarRowHover(isSelected: selection == item)
        .tag(item)
    }

    private func sessionActions(_ entry: HistoryEntry, on server: ServerConnection) -> SessionActions {
        let isPinned = model.isPinned(entry, on: server)
        return SessionActions(
            isPinned: isPinned,
            canChange: server.isConnected,
            pin: { model.setPinned(!isPinned, entry, on: server) },
            rename: {
                newTitle = entry.summary.title ?? ""
                renaming = entry
            },
            fork: {
                selection = nil
                Task {
                    await model.fork(entry, on: server)
                    showChat()
                }
            },
            archive: { Task { await model.archive(entry, on: server) } },
            delete: { deleting = entry })
    }

    private func commitRename() {
        guard let entry = renaming, let server = model.sessionsServer else { return }
        let title = newTitle
        renaming = nil
        Task { await model.rename(entry, to: title, on: server) }
    }

    private func commitDelete() {
        guard let entry = deleting, let server = model.sessionsServer else { return }
        deleting = nil
        Task { await model.delete(entry, on: server) }
    }

    private var deleteQuestion: String {
        let title = deleting?.summary.title.flatMap { $0.isEmpty ? nil : $0 } ?? "this chat"
        return "Delete “\(title)”?"
    }

    private var profileName: String? {
        model.sessionsServer?.connection.listProfileBot?.displayName
    }

    /// The profile's server, with several, and its status unless connected (the rail
    /// shows the same as a dot).
    private var subtitle: String? {
        guard let server = model.sessionsServer else { return nil }
        let state = server.connection.state
        // Not connected because of something the user can fix (no password): say what.
        let status = state == .connected ? nil : server.lastError ?? state.statusText
        let parts = [model.showsServerNames ? server.name : nil, status].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
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
