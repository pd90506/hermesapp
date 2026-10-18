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

/// The profile picked in the profile rail: its Bot Chat pinned at the top, where it
/// never scrolls away (`PinnedBotChat`), then its sessions. On macOS it shares the
/// sidebar with the rail (`RootView`); on iOS it is the middle column.
///
/// - On macOS the profile's name (and server) is the column's title, in the title bar
///   level with the window buttons, with New chat (`NewChatButton`, a compose icon) at
///   the column's trailing edge, level with the name. On iOS both are in the pinned
///   `SessionListHeader`; rows scroll under it.
/// - Each session has Pin, Rename, Fork, Archive and Delete, in its context menu and its
///   "…" button; pinned sessions list first.
/// - Settings is at the bottom of the profile rail (on iPhone, a toolbar button here).
/// - At the bottom, the error and "waiting" banners; on iOS also a fixed-height footer
///   with the connection status (on macOS the rail beside it shows that).
/// Rows and controls are in `SidebarControls.swift`; pointer feedback in `Hover.swift`.
struct SessionListView: View {
    @Environment(AppModel.self) private var model
    @Binding var selection: SidebarItem?
    /// Shows the chat a side chat was started for (on iPhone, pushes it).
    var showChat: () -> Void = {}
    /// One side chat at a time: repeated clicks while one is being created do nothing.
    @State private var isStartingChat = false
    #if os(macOS)
    /// In window coordinates: the column, and where its title starts in the title bar.
    /// They size the title so New chat after it ends at the column's trailing edge
    /// (`titleWidth`).
    @State private var columnFrame: CGRect?
    @State private var titleMinX: CGFloat?
    #endif
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
        // The Bot Chat above the list, not in a bar over it: always in reach, and the
        // rows scroll under nothing. As a bar the list's rows scrolled under, the system
        // drew a line across the column at its bottom, only under the pointer (or with
        // rows under it), beside the Bot Chat's own divider, which is always there.
        VStack(spacing: 0) {
            pinnedBotChat
            List(selection: $selection) {
                if let server = model.sessionsServer {
                    pinnedSection(server)
                    sessionsSection(server)
                }
            }
            #if os(macOS)
            .listStyle(.sidebar)
            #endif
        }
        .navigationTitle(profileName ?? "Sessions")
        #if os(macOS)
        .toolbar {
            // The column's title, in the title bar right after the window buttons. Its
            // width is what puts New chat, which follows it, at the sidebar's trailing
            // edge, level with the name (`titleWidth`). (Otherwise New chat landed right
            // after the name, or after a flexible spacer at the window's trailing edge;
            // inside this item, its tooltip covered the whole title.) Both are primary
            // actions: those stay over the sidebar, where `.navigation` went over the chat.
            ToolbarItem(placement: .primaryAction) {
                ColumnTitle(title: profileName ?? "No profile", subtitle: subtitle)
                    .frame(width: titleWidth, alignment: .leading)
                    .background(WindowFrameReader { followTitleStart($0.minX) })
            }
            .sharedBackgroundVisibility(.hidden)
            if let newChatButton {
                ToolbarItem(placement: .primaryAction) {
                    newChatButton
                }
            }
        }
        .toolbar(removing: .title)
        .background(WindowFrameReader { columnFrame = $0.integral })
        #else
        // The header shows the name; the navigation title stays for the back button.
        .toolbar(removing: .title)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .refreshable { await model.refreshLists() }
        #if os(iOS)
        // Pinned above the Bot Chat and the list: it never scrolls away.
        .safeAreaBar(edge: .top) {
            SessionListHeader(title: profileName ?? "No profile",
                              subtitle: subtitle,
                              newChat: newChatButton)
        }
        #endif
        // A bar like the header's: rows fade out under it instead of showing through the
        // status text, and it keeps the sidebar's material (an opaque .bar did not).
        .safeAreaBar(edge: .bottom) {
            VStack(spacing: 0) {
                banners
                #if os(iOS)
                SidebarFooter(status: statusText, color: statusColor) { EmptyView() }
                #endif
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
    }

    /// The profile's one ongoing chat, above its other sessions.
    @ViewBuilder private var pinnedBotChat: some View {
        if let server = model.sessionsServer, let bot = server.connection.listProfileBot {
            let item = SidebarItem.bot(server: server.id, profile: bot.name)
            PinnedBotChat(bot: bot, activity: server.connection.activity(for: bot), isSelected: selection == item) {
                selection = item
                showChat()
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
            } else if connection.visibleHistory.isEmpty && !connection.sessionListLoading
                        && connection.sessionListError == nil {
                Text("No sessions yet")
                    .uiFont(.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach(model.pins.split(connection.visibleHistory, on: server.id).others) { entry in
                sessionRow(entry, on: server)
            }
        } header: {
            SidebarSectionTitle("Sessions")
        }
    }

    /// Pinned sessions, above the rest, while there are any.
    @ViewBuilder private func pinnedSection(_ server: ServerConnection) -> some View {
        let pinned = model.pins.split(server.connection.visibleHistory, on: server.id).pinned
        if !pinned.isEmpty {
            Section {
                ForEach(pinned) { entry in
                    sessionRow(entry, on: server)
                }
            } header: {
                SidebarSectionTitle("Pinned")
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
                    .uiFont(.callout)
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
                .uiFont(.callout)
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

    #if os(macOS)
    /// New chat after the title: 10 pt after it, 36 pt wide, ending 7.5 pt short of the
    /// column's trailing edge so its centre lines up with the rows' "…" (measured on
    /// macOS 26).
    private static let newChatSlot: CGFloat = 10 + 36 + 7.5

    /// From where the title starts to New chat's place at the column's trailing edge.
    /// Takes a new start for the title only when it moved by more than a nudge, as when
    /// the window buttons leave in full screen (about 70 pt). Following every small shift
    /// fed back into the title's width and made New chat jitter.
    private func followTitleStart(_ x: CGFloat) {
        if let titleMinX, abs(x - titleMinX) <= 12 { return }
        titleMinX = x.rounded()
    }

    /// The title starts after the window buttons, over the profile rail, so that start is
    /// measured (`followTitleStart`). Until it is, the title is a modest width that fits:
    /// the title bar drops an item that doesn't fit, or has no width, without a trace,
    /// and a dropped title is never measured.
    private var titleWidth: CGFloat {
        guard let columnFrame, let titleMinX else { return Self.unmeasuredTitleWidth }
        return max(Self.unmeasuredTitleWidth, columnFrame.maxX - titleMinX - Self.newChatSlot)
    }

    private static let unmeasuredTitleWidth: CGFloat = 100
    #endif

    private var newChatButton: NewChatButton? {
        guard let server = model.sessionsServer else { return nil }
        let connection = server.connection
        return NewChatButton(isEnabled: connection.canStartListChat && !isStartingChat,
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

    #if os(iOS)
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
    #endif

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
