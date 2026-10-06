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

/// Bot sidebar: the roster, each bot's one permanent Bot Chat, side chats and History.
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
    }

    /// Reloads `history`: each bot's sessions except its Bot Chat, grouped by
    /// bot in roster order. Within a bot, the server's order is kept: most recent
    /// activity first (`methods_session.py:149-152`). Listing rows carry no
    /// activity time (`_session_row_summary`, :118-126), so bots cannot be merged
    /// by it. A bot whose listing fails keeps its previous entries.
    public func refreshHistory(limitPerBot: Int = 20) async throws {
        guard let client else { throw GatewayClientError.notConnected }
        let gen = generation
        var entries: [HistoryEntry] = []
        for bot in bots {
            do {
                let rows = try await client.listSessions(SessionListParams(limit: limitPerBot, profile: bot.name))
                entries += rows.filter { !Self.isBotChat($0, of: bot) }.map { HistoryEntry(profile: bot.name, summary: $0) }
            } catch {
                entries += history.filter { $0.profile == bot.name }
            }
            guard gen == generation else { return }
        }
        history = entries
    }

    /// A Bot Chat is never a History row, even if a listing shows it. Matching
    /// by title includes a *visible* row titled "Bot Chat": the registry lookup
    /// does not filter on `hidden` (`methods_session.py:526-550`), so such a row
    /// is what the bot row opens, and History must not offer it a second time.
    static func isBotChat(_ row: SessionSummary, of bot: Bot) -> Bool {
        Bot.isChatRow(row) || bot.chatStoredIDs.contains(row.id)
            || row.resolvedID.map(bot.chatStoredIDs.contains) == true
    }

    /// Refreshes the roster, then History (and with `includingSessions` the
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
            try? await self?.refreshHistory()
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
            title: Bot.chatTitle, profile: profile, hidden: true, followProfileConfig: true))
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
    @discardableResult
    public func newSideChat(profile: String) async throws -> ChatSession {
        let token = beginSelection()
        guard let client else { throw GatewayClientError.notConnected }
        let created = try await client.createSession(SessionCreateParams(profile: profile))
        let session = ChatSession(snapshot: created.snapshot, storedSessionID: created.storedSessionID,
                                  title: nil, profile: profile, kind: .sideChat, connection: self)
        try await show(OpenedChat(session: session, openRequests: []), token: token, client: client)
        return session
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
