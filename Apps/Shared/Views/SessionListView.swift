import HermesKit
import HermesProtocol
import SwiftUI

/// What the sidebar can select. Every row belongs to one server.
enum SidebarItem: Hashable {
    /// A bot, by profile name. Selecting it opens its one Bot Chat.
    case bot(server: UUID, profile: String)
    /// A Sessions row, by `HistoryEntry.id`.
    case history(server: UUID, id: String)
    /// A scheduled job's run on the Cron Jobs tab, by its stored session id.
    case cronRun(server: UUID, profile: String, id: String)

    var server: UUID {
        switch self {
        case .bot(let server, _), .history(let server, _), .cronRun(let server, _, _): server
        }
    }
}

/// The profile picked in the profile rail: its Bot Chat, then its sessions. On macOS it
/// shares the sidebar with the rail (`RootView`), with the Bot Chat pinned at the top,
/// where it never scrolls away (`PinnedBotChat`). On iOS it is the middle column (on
/// iPhone the page under the profiles' drawer), with the Bot Chat as the list's first
/// group, which scrolls with the sessions under it (asked for by the user, 2026-10-18).
///
/// - The profile's name (and server) heads the list, with New chat (`NewChatButton`, a
///   compose icon) at its trailing edge, in the pinned `SessionListHeader`; rows scroll
///   under it. On the Mac New chat is in the window's toolbar over the sidebar
///   (`MacSidebar`), and the name under it; on iPhone the page's top, with no navigation
///   bar over it, led by the profile's avatar.
/// - Each session has Pin, Rename, Fork, Archive and Delete, in its context menu and its
///   "…" button; pinned sessions list first.
/// - Settings is at the bottom of the profile rail (on iPhone, of the profiles' drawer).
/// - At the bottom, the error and "waiting" banners, then the tabs, Sessions and Cron Jobs
///   (on iOS the system's tab bar; on the Mac `SessionListTabBar`). Cron Jobs shows the
///   profile's scheduled jobs in place of its
///   chats (`CronJobsList`). No connection status there on iOS either (asked for by the
///   user, 2026-10-19): the header's subtitle says when the server isn't connected, and
///   the profiles' avatars carry a status dot.
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
    /// Sessions or Cron Jobs. Not kept across launches: the app opens on the sessions.
    /// (Kept per window, a run left on Cron Jobs opened the next launch there.)
    @State private var tab: SessionListTab = .sessions
    #if os(macOS)
    /// Whether the profile rail shows (`MacSidebar`), for its toggle in the toolbar.
    @AppStorage("profileRailShown") private var isRailShown = true
    #endif
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    #endif

    var body: some View {
        #if os(macOS)
        // One clock for the whole sidebar. It only ages labels; row read tasks keep
        // their existing revisions/cache and issue no extra network refreshes.
        TimelineView(.periodic(from: .now, by: 60)) { context in
            content.environment(\.sessionListClock, context.date)
        }
        #else
        content
        #endif
    }

    private var content: some View {
        Group {
            #if os(macOS)
            // On macOS the Bot Chat above the list, not in a bar over it: always in reach,
            // and the rows scroll under nothing. As a bar the list's rows scrolled under, the
            // system drew a line across the column at its bottom, only under the pointer (or
            // with rows under it), beside the Bot Chat's own divider, which is always there.
            VStack(spacing: 0) {
                switch tab {
                case .sessions:
                    pinnedBotChat
                    sessionsList
                case .cron:
                    cronJobsList
                }
            }
            // No edge of the system's at the bottom: the Mac drew it, a band and a line, only
            // while the pointer was over the list.
            .scrollEdgeEffectHidden(true, for: .bottom)
            // No title of its own: the window's is the chat's (`RootView`), which a title here
            // took over once the two were no longer a split view's columns.
            // On the sidebar's own panel (`MacSidebar`).
            .scrollContentBackground(.hidden)
            .refreshable { await refresh() }
            // Pinned above the Bot Chat and the list, under the window's toolbar, which holds
            // New chat over the sidebar (`MacSidebar`): it never scrolls away.
            .safeAreaInset(edge: .top, spacing: 0) {
                header
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("sharedSidebarHeader")
            }
            // The sidebar's part of the toolbar: the rail's toggle after the window buttons,
            // New chat at the column's end.
            .toolbar {
                ToolbarItem(placement: .primaryAction) { CollapseButton(isRailShown: $isRailShown) }
                ToolbarSpacer(.flexible, placement: .primaryAction)
                if let newChatButton {
                    ToolbarItem(placement: .primaryAction) { newChatButton }
                }
            }
            // The banners and the tabs float over the rows, on their own glass.
            .safeAreaBar(edge: .bottom) {
                VStack(spacing: 0) {
                    banners
                    SessionListTabBar(tab: $tab, cronAlerts: cronAlerts)
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("sessionListBottomBar")
            }
            #else
            // The system's tab view, Liquid Glass's tab bar: Sessions and Cron Jobs, a failed
            // job's count on its tab's badge. Each tab is a page of its own, with the header
            // over it.
            TabView(selection: $tab) {
                Tab(SessionListTab.sessions.title, systemImage: SessionListTab.sessions.systemImage,
                    value: SessionListTab.sessions) {
                    page { sessionsList }
                }
                .accessibilityIdentifier("sessionListTab.sessions")
                Tab(SessionListTab.cron.title, systemImage: SessionListTab.cron.systemImage,
                    value: SessionListTab.cron) {
                    page { cronJobsList }
                }
                .badge(cronAlerts)
                .accessibilityIdentifier("sessionListTab.cron")
            }
            .tabViewStyle(.tabBarOnly)
            // The header shows the name; the navigation title stays for the back button.
            .navigationTitle(profileName ?? "Sessions")
            .toolbar(removing: .title)
            .navigationBarTitleDisplayMode(.inline)
            // On iPhone the header is the top of the page: the bar held only Profiles and
            // Settings, now the header's avatar and the drawer's Settings.
            .toolbarVisibility(isPhone ? .hidden : .automatic, for: .navigationBar)
            #endif
        }
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

    /// The profile's name and New chat, on iPhone led by the profile's avatar.
    @ViewBuilder private var header: some View {
        #if os(iOS)
        if isPhone {
            SessionListHeader(title: profileName ?? "No profile", subtitle: subtitle,
                              newChat: newChatButton) {
                CurrentProfileAvatar()
            }
        } else {
            SessionListHeader(title: profileName ?? "No profile", subtitle: subtitle, newChat: newChatButton)
        }
        #else
        ColumnTitle(title: profileName ?? "No profile", subtitle: subtitle)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Hover.rowContentInset)
            .padding(.bottom, 6)
            .accessibilityIdentifier("sidebarProfileTitle")
        #endif
    }

    /// On macOS, the profile's one ongoing chat, above its other sessions.
    private var sessionsList: some View {
        List(selection: $selection) {
            if let server = model.sessionsServer {
                Group {
                    botSection(server)
                    pinnedSection(server)
                    sessionsSection(server)
                }
                .themedRows()
            }
        }
        #if os(macOS)
        .listStyle(.sidebar)
        #endif
    }

    private var cronJobsList: some View {
        CronJobsList(selection: $selection, showChat: showChat)
    }

    private func refresh() async {
        switch tab {
        case .sessions: await model.refreshLists()
        case .cron: await model.sessionsServer?.connection.refreshCronJobs()
        }
    }

    #if os(iOS)
    /// A tab's page: on the theme's page, as the chat is on its chat colour (`ChatView`),
    /// with the header pinned over it and the banners over its bottom, each on its glass.
    private func page(@ViewBuilder _ list: () -> some View) -> some View {
        list()
            .themedPage()
            .refreshable { await refresh() }
            .safeAreaBar(edge: .top) { header }
            .safeAreaBar(edge: .bottom) { banners.padding(.bottom, 4) }
    }
    #endif

    @ViewBuilder private var pinnedBotChat: some View {
        #if os(macOS)
        if let server = model.sessionsServer, let bot = server.connection.listProfileBot {
            let item = SidebarItem.bot(server: server.id, profile: bot.name)
            PinnedBotChat(bot: bot, activity: server.connection.activity(for: bot), isSelected: selection == item) {
                selection = item
                showChat()
            }
        }
        #endif
    }

    /// On iOS, the profile's one ongoing chat, as the list's first group: it scrolls with
    /// the sessions, a row like theirs.
    @ViewBuilder private func botSection(_ server: ServerConnection) -> some View {
        #if os(iOS)
        if let bot = server.connection.listProfileBot {
            let item = SidebarItem.bot(server: server.id, profile: bot.name)
            Section {
                // A button, not a tagged row: the Bot Chat is often already the
                // selection (opened at launch, or the profile's last chat), and the
                // List took a tap on the selected row as no change, so it pushed no chat.
                Button {
                    selection = item
                    showChat()
                } label: {
                    BotRow(bot: bot, activity: server.connection.activity(for: bot))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("botChatRow")
                .accessibilityAddTraits(selection == item ? .isSelected : [])
                .sidebarRowHighlight(isSelected: selection == item)
            } header: {
                SidebarSectionTitle(Bot.chatTitle)
            }
        }
        #endif
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
        return HistoryRow(entry: entry, timestampRevision: "\(server.id)/\(server.connection.sessionListReads)",
                          loadTimestamp: { await server.connection.latestMessageDate(for: entry) }) {
            sessionActions(entry, on: server)
        }
        .sidebarRowHighlight(isSelected: selection == item)
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
        // Quiet while a dropped connection gets back within a few seconds (`shownState`).
        let state = server.connection.shownState
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

    /// Above the tabs, so they never push the rows (or New chat) around: on glass, as the
    /// tabs, so the rows under them don't show through the text.
    /// How far the banners are set in from the list's edges.
    private static var bannerInset: CGFloat {
        #if os(macOS)
        Hover.rowInset
        #else
        16
        #endif
    }

    @ViewBuilder private var banners: some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        if model.actionError != nil || waitingCount > 0 {
            VStack(spacing: 0) { bannerRows }
                .themedGlass(in: shape)
                .padding(.horizontal, Self.bannerInset)
                .padding(.top, 6)
        }
    }

    @ViewBuilder private var bannerRows: some View {
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

    /// The profile's jobs whose last run failed or wasn't delivered, as read last.
    private var cronAlerts: Int {
        guard let connection = model.sessionsServer?.connection,
            connection.cron.profile == connection.listProfile else { return 0 }
        return connection.cron.jobs.filter(\.needsAttention).count
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

    /// On iPhone: the compact layout, with the profiles in a drawer (`RootView`).
    private var isPhone: Bool {
        #if os(iOS)
        sizeClass == .compact
        #else
        false
        #endif
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
