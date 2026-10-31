import Foundation
import HermesProtocol

/// A resume ack and, when it can be trusted, the newest transcript page read alongside it.
struct ResumedChat: Sendable {
    let snapshot: LiveSessionSnapshot
    let prefetch: Task<LatestHistory, any Error>?
}

/// A chat that was opened but not necessarily shown yet.
struct OpenedChat: Sendable {
    let session: ChatSession
    let openRequests: [OpenRequestEntry]
    var prefetch: Task<LatestHistory, any Error>? = nil

    init(session: ChatSession, openRequests: [OpenRequestEntry]) {
        self.session = session
        self.openRequests = openRequests
    }

    init(session: ChatSession, resumed: ResumedChat) {
        self.session = session
        self.openRequests = resumed.snapshot.openRequests ?? []
        self.prefetch = resumed.prefetch
    }
}

/// Bot roster, permanent Bot Chats and profile-scoped ordinary sessions.
///
/// The Bot Chat contract is Hermes Desktop's (`apps/desktop/src/AGENTS.md`, "Bot Mode";
/// `plugins/hermes-bots/canonical-chat.ts`):
/// - identity is (profile, session titled exactly `Bot.chatTitle`), resolved
///   with an exact-title `session.list` on **every** open; no session id is
///   stored or consulted as the bot's chat;
/// - a failed or unconfirmed lookup never creates a chat (fail closed);
/// - a chat is created only when the lookup confirms there is none, born
///   hidden, titled eagerly, and a title conflict adopts the winner.
extension GatewayConnection {
    // MARK: Roster

    /// Reloads `bots` from `profiles.list`.
    public func refreshBots() async throws {
        guard let client else { throw GatewayClientError.notConnected }
        let gen = generation
        let profiles = try await client.listProfiles()
        guard gen == generation else { return }
        bots = Bot.roster(profiles)
        loadAvatars()
        if !bots.contains(where: { $0.name == listProfile }) {
            let preferred = bots.first { $0.name == preferredListProfile }
            selectListProfile((preferred ?? bots.first(where: \.isDefault) ?? bots.first)?.name)
        }
    }

    /// A Bot Chat is never a History row, even if a listing shows it. Matching
    /// by title includes a *visible* row titled "Bot Chat": the registry lookup
    /// does not filter on `hidden` (`methods_session.py:526-550`), so such a row
    /// is what the bot row opens, and History must not offer it a second time.
    static func isBotChat(_ row: SessionSummary, of bot: Bot) -> Bool {
        Bot.isChatRow(row) || bot.chatStoredIDs.contains(row.id)
            || row.resolvedID.map(bot.chatStoredIDs.contains) == true
    }

    /// Refreshes the roster, then the visible selected profile (and with `includingSessions` the
    /// launch profile's `sessions`), without blocking the caller. A call while
    /// a refresh runs queues exactly one more, so a change that landed
    /// mid-refresh is not lost.
    public func refreshListsInBackground(includingSessions: Bool = false) {
        guard client != nil else { return }
        guard listsRefreshTask == nil else {
            listsRefreshQueued = true
            return
        }
        let gen = generation
        listsRefreshTask = Task { [weak self] in
            if includingSessions { try? await self?.refreshSessions() }
            try? await self?.refreshBots()
            await self?.refreshSessionListIfVisible()
            guard let self, gen == self.generation else { return }
            self.listsRefreshTask = nil
            if self.listsRefreshQueued {
                self.listsRefreshQueued = false
                self.refreshListsInBackground(includingSessions: true)
            }
        }
    }

    /// What the bot's row should show, including what this app sees live.
    public func activity(for bot: Bot, now: Date = Date()) -> BotActivity {
        let active = activeSession.flatMap { $0.profile == bot.name ? $0 : nil }
        let waiting = active.map { !$0.transcript.pendingRequests.isEmpty } == true
            || otherSessionRequests.contains { sessionProfiles[$0.sessionID ?? ""] == bot.name }
        return bot.activity(now: now, liveTurnRunning: active?.transcript.isRunning == true,
                            waitingForAnswer: waiting)
    }

    // MARK: Bot Chat

    /// Opens the bot's one permanent chat, creating it only if the profile
    /// confirmably has none, and makes it active. Concurrent calls for one
    /// profile share one resolution.
    ///
    /// Throws `BotChatError` when the registry cannot be read or confirmed:
    /// retry, never create.
    @discardableResult
    public func openBotChat(profile: String) async throws -> ChatSession {
        let token = beginSelection()
        if let current = activeSession, current.kind == .botChat, current.profile == profile {
            return keepShowing(current)
        }
        guard let client else { throw GatewayClientError.notConnected }
        // Shown before: at once, then looked up by name again in the background
        // (`GatewayConnection+Revisit`), so the identity rule of §8.2 still holds.
        if let warm = warmChat(where: { $0.kind == .botChat && $0.profile == profile }) {
            return revisit(warm, token: token, client: client)
        }
        beginOpening(PendingChat(profile: profile, kind: .botChat, title: nil), token: token)
        defer { endOpening(token) }
        let gen = generation
        let task: Task<OpenedChat, any Error>
        if let inflight = botChatOpens[profile] {
            task = inflight
        } else {
            task = Task { try await self.resolveBotChat(profile: profile, client: client) }
            botChatOpens[profile] = task
        }
        let opened: OpenedChat
        do {
            opened = try await task.value
        } catch {
            if botChatOpens[profile] == task { botChatOpens[profile] = nil }
            throw error
        }
        if botChatOpens[profile] == task { botChatOpens[profile] = nil }
        guard gen == generation else {
            opened.prefetch?.cancel()
            throw CancellationError()
        }
        try await show(opened, token: token, client: client)
        refreshListsInBackground()
        return opened.session
    }

    private func resolveBotChat(profile: String, client: GatewayClient) async throws -> OpenedChat {
        // The roster already names the chat's tip (`canonical_session`), so its newest
        // page is read now, alongside the registry lookup, not after it. It is used
        // only if the lookup names the same tip; the lookup stays the identity (§8.2).
        let guess = bots.first { $0.name == profile }?.profile.canonicalSession
            .flatMap { canonical in canonical.resolvedID.flatMap { $0.isEmpty ? nil : $0 } ?? canonical.id }
        let early = guess.flatMap { latestPageRead($0, profile: profile) }
        let row: SessionSummary?
        do {
            row = try await lookUpBotChat(profile: profile, client: client)
        } catch {
            early?.cancel()
            throw error
        }
        if let row {
            let target = row.resolvedID.flatMap { $0.isEmpty ? nil : $0 } ?? row.id
            let prefetch = target == guess ? early : nil
            if prefetch == nil { early?.cancel() }
            return try await resumeBotChat(row, profile: profile, client: client, prefetch: prefetch)
        }
        early?.cancel()
        // An empty answer is not proof: a backend mid-restart can list nothing.
        // The roster saw a Bot Chat, so this absence is unconfirmed (`canonical-chat.ts:328-338`).
        if bots.first(where: { $0.name == profile })?.hasChat == true {
            throw BotChatError.registryUnconfirmed(profile: profile)
        }
        let created = try await client.createSession(SessionCreateParams(
            title: Bot.chatTitle, source: SessionSourceSettings.newSessionSource, profile: profile, hidden: true,
            followProfileConfig: true))
        // Persists the row under the canonical title now, closing the window in
        // which a second open would find no "Bot Chat" (`canonical-chat.ts:493-502`).
        // Only a registered row may become the Bot Chat. An unregistered lazy session
        // is hidden and untitled: a second open would create another chat, and turns
        // typed into this one could not be reached from any list. So every failure
        // other than a title conflict, and `pending: true` (row not written,
        // `methods_session.py:1238-1241`), fails closed; the lazy session is left
        // for the gateway to prune.
        let titled: SessionTitleResult
        do {
            titled = try await client.setTitle(sessionID: created.sessionID, title: Bot.chatTitle)
        } catch let error as RPCError where error.message.range(of: "already in use", options: .caseInsensitive) != nil {
            // Another writer created the Bot Chat since our lookup: adopt it. The
            // stray lazy session has no row and is pruned by the gateway
            // (`canonical-chat.ts:513-535`).
            guard let winner = try await lookUpBotChat(profile: profile, client: client) else {
                throw BotChatError.registryUnconfirmed(profile: profile)
            }
            return try await resumeBotChat(winner, profile: profile, client: client)
        } catch {
            throw BotChatError.notRegistered(profile: profile, detail: Self.describe(error))
        }
        if titled.pending == true {
            throw BotChatError.notRegistered(profile: profile, detail: "the gateway did not save the chat yet")
        }
        let session = ChatSession(snapshot: created.snapshot, storedSessionID: created.storedSessionID,
                                  title: Bot.chatTitle, profile: profile, kind: .botChat, connection: self)
        return OpenedChat(session: session, openRequests: [])
    }

    /// The exact-title registry lookup on the bot's own profile. Hidden rows
    /// must resolve: Bot Chats are born hidden.
    private func lookUpBotChat(profile: String, client: GatewayClient) async throws -> SessionSummary? {
        do {
            return try await findBotChat(profile: profile, client: client)
        } catch {
            throw BotChatError.registryUnavailable(profile: profile, detail: Self.describe(error))
        }
    }

    /// The lookup with the gateway's own errors (4064 for a profile that is gone).
    func findBotChat(profile: String, client: GatewayClient) async throws -> SessionSummary? {
        let rows = try await client.listSessions(SessionListParams(
            limit: 200, includeHidden: true, title: Bot.chatTitle, profile: profile))
        return rows.first(where: Bot.isChatRow)
    }

    /// The stored id a cold restore of a Bot Chat must resume: the registry's
    /// current lineage tip, looked up again (Desktop re-resolves on every wake,
    /// `canonical-chat.ts:110-116,602-651`). The id the chat had before the
    /// outage is not trusted: Desktop may have retired and replaced the chat
    /// meanwhile, and resuming an old key can even re-create a missing row
    /// (`methods_session.py:782-808,811-833`). Throws `RestoreError.botChatGone`
    /// when the profile has no Bot Chat any more.
    func botChatRestoreTarget(profile: String, client: GatewayClient) async throws -> String {
        guard let row = try await findBotChat(profile: profile, client: client) else {
            throw RestoreError.botChatGone
        }
        return row.resolvedID.flatMap { $0.isEmpty ? nil : $0 } ?? row.id
    }

    /// Opens the lineage tip; the registry row stays the identity.
    private func resumeBotChat(_ row: SessionSummary, profile: String, client: GatewayClient,
                               prefetch: Task<LatestHistory, any Error>? = nil) async throws -> OpenedChat {
        let target = row.resolvedID.flatMap { $0.isEmpty ? nil : $0 } ?? row.id
        let resumed = try await resume(target, profile: profile, client: client, prefetch: prefetch)
        let session = ChatSession(snapshot: resumed.snapshot, storedSessionID: target, title: Bot.chatTitle,
                                  profile: profile, kind: .botChat, connection: self)
        return OpenedChat(session: session, resumed: resumed)
    }

    // MARK: Side chats and History

    /// Starts a temporary chat with a bot: a plain, visible, untitled session
    /// on its profile. It shows up in History after its first turn, never as
    /// the bot's chat.
    ///
    /// The profile's last New chat, while nothing has been sent in it, comes back
    /// instead of a new one, with what was typed in it (it has no Sessions row to go
    /// back to). One whose runtime was reclaimed is replaced, and its draft carried over.
    @discardableResult
    public func newSideChat(profile: String) async throws -> ChatSession {
        let token = beginSelection()
        guard let client else { throw GatewayClientError.notConnected }
        var carried: String?
        if let unsent = unsentChats[profile] {
            if unsent.hasPrompted || !unsent.transcript.items.isEmpty {
                unsentChats[profile] = nil
            } else if !unsent.isRuntimeGone {
                return activeSession === unsent ? keepShowing(unsent) : revisit(unsent, token: token, client: client)
            } else {
                carried = composer(for: unsent).draft
                unsentChats[profile] = nil
                forget(unsent)
            }
        }
        let created = try await client.createSession(SessionCreateParams(source: SessionSourceSettings.newSessionSource, profile: profile))
        let session = ChatSession(snapshot: created.snapshot, storedSessionID: created.storedSessionID,
                                  title: nil, profile: profile, kind: .sideChat, connection: self)
        if let carried, !carried.isEmpty { composer(for: session).draft = carried }
        try await show(OpenedChat(session: session, openRequests: []), token: token, client: client)
        unsentChats[profile] = session
        refreshListsInBackground()
        return session
    }

    /// The profile's New chat as a row of the session list, above its sessions, as other
    /// harnesses show a new chat: while nothing is sent in it, and once something is (a
    /// failed send too), until the list has the session's own row.
    public func newChatRow(profile: String) -> ChatSession? {
        guard let chat = unsentChats[profile] else { return nil }
        guard chat.hasPrompted || !chat.transcript.items.isEmpty else { return chat }
        let listed = historyProfile == profile && history.contains { $0.summary.id == chat.storedSessionID }
        return listed ? nil : chat
    }

    /// Goes back to the profile's New chat, its row clicked: a blank one as New chat does
    /// (`newSideChat`), one already sent in as it was left.
    @discardableResult
    public func openNewChat(profile: String) async throws -> ChatSession {
        guard let chat = unsentChats[profile], chat.hasPrompted || !chat.transcript.items.isEmpty else {
            return try await newSideChat(profile: profile)
        }
        let token = beginSelection()
        guard let client else { throw GatewayClientError.notConnected }
        return activeSession === chat ? keepShowing(chat) : revisit(chat, token: token, client: client)
    }

    /// Resumes a History entry on its profile and makes it active.
    @discardableResult
    public func open(_ entry: HistoryEntry) async throws -> ChatSession {
        let token = beginSelection()
        if let current = activeSession, current.profile == entry.profile, current.kind == .sideChat,
            current.storedSessionID == entry.summary.id
        {
            return keepShowing(current)
        }
        guard let client else { throw GatewayClientError.notConnected }
        if let warm = warmChat(where: {
            $0.profile == entry.profile && $0.kind == .sideChat && $0.storedSessionID == entry.summary.id
        }) {
            return revisit(warm, token: token, client: client)
        }
        beginOpening(PendingChat(profile: entry.profile, kind: .sideChat, title: entry.summary.title), token: token)
        defer { endOpening(token) }
        let resumed = try await resume(entry.summary.id, profile: entry.profile, client: client)
        let session = ChatSession(snapshot: resumed.snapshot, storedSessionID: entry.summary.id,
                                  title: entry.summary.title, profile: entry.profile, kind: .sideChat, connection: self)
        try await show(OpenedChat(session: session, resumed: resumed), token: token, client: client)
        return session
    }
}

// Navigation changes only list state; chat selection and composers are untouched.
extension GatewayConnection {
    /// The Sessions page's selected profile, while it is in the roster.
    public var listProfileBot: Bot? {
        bots.first { $0.name == listProfile }
    }

    /// Whether the Sessions page's "New chat" can start a side chat: connected,
    /// with a roster profile selected.
    public var canStartListChat: Bool {
        state == .connected && listProfileBot != nil
    }

    public func selectListProfile(_ profile: String?) {
        guard listProfile != profile else { return }
        listProfile = profile
        sessionListToken += 1
        history = []
        historyProfile = nil
        sessionListLoading = false
        sessionListError = nil
        cron.reset(to: profile)
    }

    /// Reads the activity (`SessionRowActivity`) of every row not read since its stored
    /// message count last changed, top rows first, a few at a time. Failures leave the
    /// row unknown until the next refresh.
    func readRowActivity(_ entries: [HistoryEntry]) async {
        guard let source = messagesSource else { return }
        let gen = generation
        var pending = entries.compactMap { entry -> (String, HistoryEntry)? in
            // No count to key on: read each time.
            let key = SessionRowTimestamp.cacheKey(for: entry) ?? "\(entry.id)/?"
            let cached = SessionRowTimestamp.cacheKey(for: entry) != nil && rowActivity[key] != nil
            guard !cached, !rowActivityReads.contains(key) else { return nil }
            return (key, entry)
        }[...]
        guard !pending.isEmpty else { return }
        rowActivityReads.formUnion(pending.map(\.0))
        await withTaskGroup(of: (String, HistoryEntry, SessionRowActivity?).self) { group in
            func next() {
                guard let (key, entry) = pending.popFirst() else { return }
                group.addTask { (key, entry, try? await SessionRowActivity.read(for: entry, from: source)) }
            }
            for _ in 0..<Self.rowActivityReadLimit { next() }
            for await (key, entry, activity) in group {
                rowActivityReads.remove(key)
                if gen == generation, let activity {
                    rowActivity[key] = activity
                    if isOnScreen(entry) { markSeen(entry, through: activity.newestReply) }
                    noteReply(profile: entry.profile, storedID: entry.summary.id, isBotChat: false,
                              label: (entry.summary.title ?? entry.summary.preview)?.trimmed.nonEmpty, activity: activity)
                }
                next()
            }
        }
    }

    static let rowActivityReadLimit = 4

    /// The activity read for `entry` at its current message count.
    public func activity(for entry: HistoryEntry) -> SessionRowActivity? {
        rowActivity[SessionRowTimestamp.cacheKey(for: entry) ?? "\(entry.id)/?"]
    }

    /// The row's date in the list: the user's last prompt (one just sent from here
    /// counts at once), else its newest message.
    public func listDate(for entry: HistoryEntry) -> Date? {
        let read = activity(for: entry)?.listDate
        guard let local = openChat(for: entry)?.lastPromptAt else { return read }
        return max(local, read ?? local)
    }

    /// `entries` (server order) in the list's order (`SessionListOrder`).
    public func sessionListOrder(_ entries: [HistoryEntry]) -> [HistoryEntry] {
        SessionListOrder.sorted(entries, dates: entries.map(listDate(for:)))
    }

    /// Whether `entry` has a reply the user hasn't seen here.
    public func isUnread(_ entry: HistoryEntry) -> Bool {
        guard !isOnScreen(entry) else { return false }
        return readMarks.isUnread(profile: entry.profile, id: entry.summary.id,
                                  newestReply: activity(for: entry)?.newestReply)
    }

    /// `entries` (in list order) in Desktop's date groups, by their list dates
    /// (`SessionDateGrouping`).
    public func sessionDateGroups(_ entries: [HistoryEntry], now: Date = .now,
                                  calendar: Calendar = .current) -> [SessionDateGroup<HistoryEntry>] {
        SessionDateGrouping.groups(entries, times: entries.map(listDate(for:)), now: now, calendar: calendar)
    }

    /// The warm or on-screen chat showing `entry`, if any.
    private func openChat(for entry: HistoryEntry) -> ChatSession? {
        func shows(_ chat: ChatSession) -> Bool {
            chat.profile == entry.profile && chat.kind == .sideChat && chat.storedSessionID == entry.summary.id
        }
        if let activeSession, shows(activeSession) { return activeSession }
        return warmChats.first(where: shows) ?? unsentChats.values.first(where: shows)
    }

    private func isOnScreen(_ entry: HistoryEntry) -> Bool {
        guard isChatOnScreen, let activeSession else { return false }
        return activeSession.profile == entry.profile && activeSession.kind == .sideChat
            && activeSession.storedSessionID == entry.summary.id
    }

    /// `chat`, coming on screen or just leaving it, was seen up to now.
    func markSeen(_ chat: ChatSession?) {
        guard let chat, chat.kind == .sideChat, let profile = chat.profile, let id = chat.storedSessionID else { return }
        updateReadMarks { $0.markSeen(profile: profile, id: id, through: .now) }
    }

    private func markSeen(_ entry: HistoryEntry, through date: Date?) {
        guard let date else { return }
        updateReadMarks { $0.markSeen(profile: entry.profile, id: entry.summary.id, through: date) }
    }

    private func updateReadMarks(_ change: (inout SessionReadMarks) -> Bool) {
        var marks = readMarks
        guard change(&marks) else { return }
        readMarks = marks
        readMarksChanged?(marks)
    }

    public func refreshSessionListIfVisible() async {
        guard navigationPage == .sessions else { return }
        await refreshSessionList()
    }

    public func refreshSessionList() async {
        guard let client, let profile = listProfile else { return }
        sessionListToken += 1
        let token = sessionListToken
        let gen = generation
        sessionListLoading = true
        sessionListError = nil
        defer {
            // Token only: a reconnect bumps `generation` without starting a new read.
            if token == sessionListToken { sessionListLoading = false }
        }
        do {
            // No offset and no server clamp (`contracts/sessions.py:221-224`). The server reads
            // `max(2*limit, 200)` rows, drops internal sources, then cuts to `limit`
            // (`methods_session.py:570-571`, `_listing_rows` :149-152), so a short response
            // is either the end or a window crowded by internal rows. Re-read a doubled
            // prefix until a short response stops growing; later refreshes start at the
            // limit that settled, so they cost one read.
            var limit = sessionListLimits[profile] ?? 200
            var settledBefore = sessionListLimits[profile] != nil
            var previousCount = -1
            while true {
                let rows = try await client.listSessions(SessionListParams(limit: limit, profile: profile))
                guard token == sessionListToken && gen == generation else { return }
                if rows.count < limit && (settledBefore || rows.count <= previousCount) {
                    sessionListLimits[profile] = limit
                    let bot = bots.first { $0.name == profile }
                    history = rows.filter { row in
                        guard SessionSourceSettings.isListed(row.source) else { return false }
                        if let bot { return !Self.isBotChat(row, of: bot) }
                        return !Bot.isChatRow(row)
                    }.map { HistoryEntry(profile: profile, summary: $0) }
                    historyProfile = profile
                    sessionListReads += 1
                    let listed = history
                    rowActivityTask = Task { await readRowActivity(listed) }
                    return
                }
                guard limit <= Int.max / 2 else { throw SessionListError.tooLarge }
                settledBefore = false
                previousCount = rows.count
                limit *= 2
            }
        } catch {
            guard token == sessionListToken && gen == generation else { return }
            sessionListError = Self.describe(error)
        }
    }
}

private enum SessionListError: Error { case tooLarge }
