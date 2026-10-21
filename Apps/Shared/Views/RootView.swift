import HermesKit
import HermesProtocol
import SwiftUI

/// Profile rail + session list + chat (`split`). Used by both apps.
struct RootView: View {
    @Environment(AppModel.self) private var model
    @State private var selection: SidebarItem?
    #if os(macOS)
    @Environment(\.openSettings) private var openSettings
    #else
    @State private var columns = NavigationSplitViewVisibility.all
    @Environment(\.horizontalSizeClass) private var sizeClass
    /// The column shown when the split view is collapsed (iPhone): the session list,
    /// with the profiles' drawer over it (`ProfileDrawer`), or the chat. A new side chat
    /// has no row to select until the list catches up, so it is shown through this.
    @State private var compactColumn = NavigationSplitViewColumn.sidebar
    /// On iPhone, whether the profiles' drawer is open over the session list.
    @State private var isRailOpen = false
    /// On iPhone, the chat page was popped a moment ago: its views go now, while the
    /// list shows, not when the next row is tapped. Torn down then, a long chat's
    /// views held that push back by half a second (VM, 2026-10-18).
    @State private var isChatPageGone = false
    #endif

    var body: some View {
        split
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
            SettingsView()
                // Set again on the sheet: one already up kept the old mode when the
                // user picked Light or Dark in it.
                .preferredColorScheme(AppearanceTheme.colorScheme(model.appearance.theme))
        }
        #endif
        // The chat on screen can change without a click: dropped on reconnect,
        // cleared on a server switch, or a new side chat. Follow it, so the
        // highlighted row is always the one on screen and clicking a row always opens it.
        .onChange(of: model.activeServer?.connection.activeSession?.id) { _, _ in followActiveChat() }
        #if os(iOS)
        .task(id: isOnSessionList) {
            guard isOnSessionList else {
                isChatPageGone = false
                return
            }
            // After the pop's animation, which still shows the chat.
            try? await Task.sleep(for: .milliseconds(600))
            if !Task.isCancelled { isChatPageGone = true }
        }
        #endif
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
        // Chat, or a session once its list confirms the session is still there. Not on
        // iPhone (`restoreProfileChat`).
        .onChange(of: model.pendingProfileChat) { _, _ in restoreProfileChat() }
        .onChange(of: shownProfile) { _, _ in restoreProfileChat() }
        // Instruments: where a chat switch starts (docs/performance-tracing.md).
        .onChange(of: selection) { _, _ in AppSignposts.event("Chat selected") }
        .task {
            // Auto-connect on launch when settings exist.
            if model.servers.contains(where: \.hasURL) {
                await model.connectAll()
                if !model.isAnyConnected { model.settingsPresentation.requireConnection() }
            }
        }
    }

    /// On macOS the profile rail (it collapses) and the session list on the theme's chrome,
    /// beside the flat chat column (`WindowLayout`). On iPad three
    /// columns. On iPhone two, which collapse into a navigation stack (sessions → chat),
    /// with the profiles in a drawer over the session list: as a column of their own, Back
    /// from the list showed them alone, stretched over the screen (2026-10-18).
    @ViewBuilder private var split: some View {
        #if os(macOS)
        WindowLayout {
            ProfileRailView()
        } list: {
            sessionList
        } chat: {
            chat
        }
        #else
        if sizeClass == .compact {
            NavigationSplitView(columnVisibility: $columns, preferredCompactColumn: $compactColumn) {
                ProfileDrawer(isOpen: $isRailOpen) {
                    ProfileRailView(style: .drawer,
                                    showSessions: { withAnimation(Motion.drawer) { isRailOpen = false } })
                } content: {
                    sessionList
                }
            } detail: {
                chat
            }
        } else {
            NavigationSplitView(columnVisibility: $columns) {
                ProfileRailView()
                    .navigationTitle("Profiles")
                    .navigationBarTitleDisplayMode(.inline)
            } content: {
                sessionList
            } detail: {
                chat
            }
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
            showChat: {
                #if os(iOS)
                compactColumn = .detail
                #endif
            })
    }

    /// The chat on screen, over the other warm chats of its server, which stay built
    /// but hidden (`KeptChats`): going back to one shows it as it was left, without
    /// building its transcript again.
    private var chat: some View {
        ZStack {
            if let server = model.activeServer {
                KeptChats(server: server,
                          shown: server.connection.opening == nil && !showsStaleChat && !chatPageGone
                              ? server.connection.activeSession : nil,
                          keepsHidden: keepsHiddenChats)
                    .id(server.id)
                    .environment(server)
            }
            if let server = model.activeServer, let opening = server.connection.opening {
                // A first open: the chat's frame at once, not the previous chat.
                OpeningChatView(title: title(of: opening, on: server))
            } else if showsStaleChat {
                OpeningChatView(title: "chat")
            } else if model.activeServer?.connection.activeSession == nil {
                ContentUnavailableView(
                    "No Chat Selected", systemImage: "bubble.left.and.bubble.right",
                    description: Text(model.isAnyConnected ? "Pick a profile, then a session to chat with." : "Connect to your Hermes gateway."))
            }
        }
        // One title for the column: each kept chat setting its own, the hidden ones' won.
        .navigationTitle(chatTitle)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        // A connection still getting back after a few seconds says so under the title,
        // never over the chat; a quicker one shows nothing (user, 2026-10-19).
        .toolbar {
            if model.activeServer?.connection.isTryingNoticeably == true, !chatTitle.isEmpty {
                ToolbarItem(placement: .principal) { ReconnectingTitle(title: chatTitle) }
            }
        }
        #endif
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        #if os(macOS)
        // The title bar shows no title (`WindowLayout`): the chat's title is over it.
        .safeAreaInset(edge: .top, spacing: 0) {
            ChatHeader(title: chatTitle)
        }
        #endif
    }

    /// On iPhone, whether the chat on screen is still the one shown before the row just
    /// tapped: a tap pushes the chat page at once, before the chat it opens is active.
    /// The page then shows the opening spinner, not the previous chat. Laying out the
    /// previous chat (a long transcript) held the push back by most of a second, and it
    /// left the screen right after (VM, 2026-10-18).
    private var showsStaleChat: Bool {
        #if os(iOS)
        guard sizeClass == .compact, let selection, let server = model.activeServer else { return false }
        return item(for: server.connection.activeSession, on: server) != selection
        #else
        false
        #endif
    }

    /// On iPhone, the session list is on screen: no row's chat is pushed (a row push
    /// selects it), and no chat was pushed without a row (a new chat, `compactColumn`).
    private var isOnSessionList: Bool {
        #if os(iOS)
        sizeClass == .compact && selection == nil && compactColumn == .sidebar
        #else
        false
        #endif
    }

    private var chatPageGone: Bool {
        #if os(iOS)
        isChatPageGone && isOnSessionList
        #else
        false
        #endif
    }

    /// Whether the warm chats stay built while hidden (`KeptChats`). Not on iPhone: one
    /// chat shows at a time there, on a page pushed afresh, and every push laid out the
    /// hidden chats' transcripts too (about 300 ms each in the VM, 2026-10-18).
    private var keepsHiddenChats: Bool {
        #if os(iOS)
        sizeClass != .compact
        #else
        true
        #endif
    }

    private var chatTitle: String {
        guard !showsStaleChat else { return "" }
        guard let server = model.activeServer else { return "" }
        if let opening = server.connection.opening { return title(of: opening, on: server) }
        guard let session = server.connection.activeSession else { return "" }
        return title(of: session, on: server) ?? session.title ?? "New Chat"
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
        #if os(iOS)
        // On iPhone the chat is a page of its own, not always beside the list as on the
        // Mac or iPad: a profile picked in the rail shows its sessions, and its last
        // chat stays a tap away instead of being pushed over them (user, 2026-10-18).
        if sizeClass == .compact {
            model.pendingProfileChat = nil
            return
        }
        #endif
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
            // A run opened from the Cron Jobs tab keeps its row there selected, though
            // the Sessions tab may list the same session.
            if case .cronRun(server.id, profile, session.storedSessionID ?? "") = selection { return selection }
            if let entry = server.connection.history
                .first(where: { $0.profile == profile && $0.summary.id == session.storedSessionID }) {
                return .history(server: server.id, id: entry.id)
            }
            guard let stored = session.storedSessionID, CronRun.isRunSessionID(stored) else { return nil }
            return .cronRun(server: server.id, profile: profile, id: stored)
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
            case .cronRun(_, let profile, let id):
                let run = server.connection.cron.runs.values.lazy.flatMap { $0 }.first { $0.id == id }
                    ?? CronRun(id: id, profile: profile)
                try await server.connection.open(run.historyEntry(profile: profile))
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

#if os(iOS)
/// The chat's title, with a small spinner and "Reconnecting…" under it, while its
/// connection has been trying to get back for a few seconds (`isTryingNoticeably`).
private struct ReconnectingTitle: View {
    let title: String

    var body: some View {
        VStack(spacing: 1) {
            Text(title)
                .font(.headline)
                .lineLimit(1)
            HStack(spacing: 4) {
                ProgressView()
                    .controlSize(.mini)
                Text("Reconnecting…")
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("reconnectingIndicator")
    }
}
#endif

/// The frame of a chat being opened: a spinner where the transcript goes (the column
/// shows its title).
private struct OpeningChatView: View {
    let title: String

    var body: some View {
        ProgressView()
            .controlSize(.small)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityLabel("Opening \(title)")
    }
}

/// The warm chats of a server (`GatewayConnection.warmSessions`), each built once it has
/// been shown and kept built while another is on screen. Switching between them only
/// changes which one shows: a page of rows took most of a second to build again
/// (`ChatSwitchTests`), and the chat comes back where it was scrolled.
///
/// A chat is built only once shown here, so a server switch builds the one chat shown,
/// not all of its warm chats at once. One that leaves the warm chats goes with its view.
private struct KeptChats: View {
    let server: ServerConnection
    let shown: ChatSession?
    /// False: only the chat shown is built (iPhone, `RootView.keepsHiddenChats`).
    var keepsHidden = true
    /// The chats shown since this view appeared.
    @State private var built: Set<ObjectIdentifier> = []

    var body: some View {
        ForEach(chats) { session in
            ChatView(session: session, isShown: session === shown, pushed: !keepsHidden)
                .keptChat(isShown: session === shown)
        }
        .onChange(of: shown?.id, initial: true) { _, id in
            if let id { built.insert(id) }
            let warm = Set(server.connection.warmSessions.map(\.id))
            built.formIntersection(warm.union(id.map { [$0] } ?? []))
        }
    }

    /// The warm chats shown since this view appeared, and the one shown now, in a
    /// fixed order: the warm chats reorder on every switch, and moving views in the
    /// stack is work for nothing.
    private var chats: [ChatSession] {
        guard keepsHidden else { return shown.map { [$0] } ?? [] }
        var chats = server.connection.warmSessions.filter { built.contains($0.id) && $0 !== shown }
        if let shown { chats.append(shown) }
        return chats.sorted { $0.id < $1.id }
    }
}

#if os(macOS)
/// The chat's title at the window's top, level with the window buttons; also the
/// window's title (`navigationTitle`), for the Window menu.
///
/// On a band of Liquid Glass, as the App Store's title bar: the messages scroll under it,
/// blurred (#54; #90 left the title bare, and scrolled text ran through it, 2026-10-21).
/// The glass is tinted with the chat's colour, so the theme carries through, and runs past
/// the band, cut to it: its rims drew a bright line along the band's edges. In dark a shade
/// over it, as the glass alone was a light slab there. Clear glass showed the rows sharp
/// and materials drew a solid band (2026-10-18).
private struct ChatHeader: View {
    let title: String
    @Environment(\.surfaces) private var surfaces
    @Environment(\.windowHeaderHeight) private var headerHeight

    var body: some View {
        Text(title)
            .uiFont(.headline)
            .lineLimit(1)
            .truncationMode(.middle)
            .opacity(title.isEmpty ? 0 : 1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .frame(height: headerHeight)
            .background {
                Self.shade
                    .background {
                        Color.clear
                            .glassEffect(.regular.tint(surfaces.chat.opacity(0.5)), in: .rect)
                            .padding(.vertical, -24)
                    }
                    .clipped()
            }
            // The messages fade in under its edge, as under Hermes Desktop's title bar
            // (`titlebarHeaderShadowClass`), not cut off sharp along it.
            .overlay(alignment: .bottom) {
                LinearGradient(colors: [surfaces.chat, surfaces.chat.opacity(0)], startPoint: .top, endPoint: .bottom)
                    .frame(height: 16)
                    .offset(y: 16)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            .contentShape(.rect)
            .gesture(WindowDragGesture())
            .accessibilityAddTraits(.isHeader)
            .accessibilityIdentifier("chatTitle")
    }

    private static let shade = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? NSColor(white: 0, alpha: 0.2) : .clear
    })
}
#endif
