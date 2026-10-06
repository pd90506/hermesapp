import Foundation
import HermesProtocol
import Observation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// App-level connection to one Hermes gateway: owns the current
/// `GatewayClient`, the session list, the active `ChatSession`, and
/// automatic reconnect with replay.
///
/// Restoring the active session on a new socket (see `docs/protocol.md` §7):
/// - same backend (`replay_epoch` unchanged since the last *successful*
///   restore) and a known `seq` watermark → `GatewayClient.reattach`
///   (`session.activate` + `session.events.since`);
/// - otherwise, or if that reports the session gone / the replay incomplete
///   → `session.resume` by the stored key and rebuild the transcript.
@MainActor
@Observable
public final class GatewayConnection {
    public enum State: Sendable, Equatable {
        case disconnected
        case connecting
        case connected
        case reconnecting(attempt: Int)
        case failed(String)
    }

    public private(set) var state: State = .disconnected
    public internal(set) var sessions: [SessionSummary] = []
    public internal(set) var activeSession: ChatSession?
    /// Server requests for sessions other than the active one (badge-worthy:
    /// the agent is blocked until someone answers).
    public internal(set) var otherSessionRequests: [ServerRequest] = []
    /// Every profile as a bot, `default` first (`GatewayConnection+Bots.swift`).
    public internal(set) var bots: [Bot] = []
    /// Non-Bot-Chat sessions of every bot, newest first.
    public internal(set) var history: [HistoryEntry] = []
    /// A chat being opened for the first time: shown as a frame (title, loading)
    /// at once instead of the previous chat, until it is active or the open fails.
    public private(set) var opening: PendingChat?
    /// Out-of-band notices pushed by the gateway (`notification.show`), oldest
    /// first. Timed ones (`ttl_ms`) remove themselves; see `dismissNotification`.
    public internal(set) var notifications: [GatewayNotification] = []

    /// Least time between two list refreshes triggered by `sessions.changed`.
    /// The gateway sends it at most every 2 s, including during every streaming
    /// turn (`change_watcher.py:285-331`); Desktop's heavy refresh runs at most
    /// every 10 s (`use-background-sync.ts:1302-1381`).
    @ObservationIgnored public var pushedRefreshInterval: Duration = .seconds(10)

    /// Stop retrying after this many failed attempts (`nil` = retry forever).
    @ObservationIgnored public var maxReconnectAttempts: Int? = 20

    @ObservationIgnored private(set) var client: GatewayClient?
    @ObservationIgnored private var connector: (any GatewayConnector)?
    @ObservationIgnored private var inboundTask: Task<Void, Never>?
    @ObservationIgnored private var reconnectTask: Task<Void, Never>?
    /// Epoch the active session's `seq` watermark belongs to. Committed only
    /// after a restore succeeded, so a failed attempt on a restarted backend
    /// cannot make the next attempt believe it is on the same process.
    @ObservationIgnored private var committedEpoch: String?
    /// Images a failed send left queued on the gateway (see `GatewayConnection+StrandedImages`).
    /// Held here, not on `ChatSession`: reopening a chat makes a new `ChatSession`
    /// for the same live runtime session, whose queue still holds them.
    @ObservationIgnored var strandedImages: [StrandedImage] = []
    /// The running detach flush of each runtime session that has stranded images.
    @ObservationIgnored var strandedImageFlushes: [String: Task<Void, Never>] = [:]
    /// Bumped by every connect/disconnect; async work started under an older
    /// generation discards its result (and closes its socket) instead of
    /// overwriting newer state.
    @ObservationIgnored private(set) var generation = 0
    /// Bumped by every user-initiated open; an open that finishes after a
    /// newer one started does not take the screen.
    @ObservationIgnored var selectionToken = 0
    /// In-flight Bot Chat resolutions by profile: double-clicking a bot must not
    /// create two chats (`canonical-chat.ts:38-40`).
    @ObservationIgnored var botChatOpens: [String: Task<OpenedChat, any Error>] = [:]
    /// Profile of every runtime session this connection opened, so requests
    /// for background sessions can be attributed to a bot.
    @ObservationIgnored var sessionProfiles: [String: String] = [:]
    @ObservationIgnored var listsRefreshTask: Task<Void, Never>?
    /// A refresh was asked for while one was running: run again when it ends.
    @ObservationIgnored var listsRefreshQueued = false
    @ObservationIgnored var pushedRefreshTask: Task<Void, Never>?
    @ObservationIgnored var lastPushedRefresh: ContinuousClock.Instant?
    /// Runtime id of every session this connection opened, by `liveKey(profile:stored:)`:
    /// such a session must be closed before it can be deleted (4023 while live).
    @ObservationIgnored var liveRuntimeIDs: [String: String] = [:]
    /// Chats shown on this connection, most recent first, at most `warmChatLimit`
    /// (the active one included). Going back to one shows it at once; see
    /// `GatewayConnection+Revisit`.
    @ObservationIgnored var warmChats: [ChatSession] = []
    /// The composer of each warm chat (`composer(for:)`).
    @ObservationIgnored private var composers: [ObjectIdentifier: ChatComposer] = [:]
    /// The open that `opening` belongs to.
    @ObservationIgnored private var openingToken = 0
    @ObservationIgnored private let configuration: GatewayClient.Configuration
    @ObservationIgnored private let backoff: @Sendable (Int) -> Duration

    public init(
        configuration: GatewayClient.Configuration = .init(),
        backoff: @escaping @Sendable (Int) -> Duration = GatewayConnection.exponentialBackoff
    ) {
        self.configuration = configuration
        self.backoff = backoff
    }

    /// 0.5 s, 1 s, 2 s, … capped at 30 s, with ±20 % jitter.
    public nonisolated static func exponentialBackoff(attempt: Int) -> Duration {
        let base = min(30.0, 0.5 * pow(2.0, Double(max(0, attempt - 1))))
        return .milliseconds(Int(base * Double.random(in: 0.8...1.2) * 1000))
    }

    // MARK: - Connect / disconnect

    /// Connects (or reconnects after `.failed`) with `connector`. An existing
    /// `activeSession` is restored on the new socket; if the server reports it
    /// gone (4001/4007/4064, or a Bot Chat no longer registered) it is cleared, any other restore error fails the
    /// connect and keeps the session for the next attempt. Call `disconnect()`
    /// first when switching servers.
    public func connect(using connector: any GatewayConnector) async throws {
        // Capture the generation at the bump, before any await: overlapping
        // calls must each own a distinct generation.
        let gen = beginGeneration()
        await discardClient()
        guard gen == generation else { throw CancellationError() }
        self.connector = connector
        state = .connecting
        do {
            let ready = try await establish(gen)
            try await restoreOrDropActiveSession(ready: ready, gen: gen)
            guard gen == generation else { throw CancellationError() }
            committedEpoch = ready.replayEpoch
            state = .connected
            flushStrandedImagesInBackground()
        } catch {
            guard gen == generation else { throw CancellationError() }
            await discardClient()
            state = .failed(Self.describe(error))
            self.connector = nil
            throw error
        }
        try? await refreshSessions()
        refreshListsInBackground()
    }

    /// Closes the connection and forgets all session state.
    public func disconnect() async {
        let gen = beginGeneration()
        await discardClient()
        guard gen == generation else { return }  // a newer connect() superseded this call
        connector = nil
        activeSession = nil
        opening = nil
        warmChats = []
        composers = [:]
        otherSessionRequests = []
        sessions = []
        bots = []
        history = []
        notifications = []
        sessionProfiles = [:]
        liveRuntimeIDs = [:]
        committedEpoch = nil
        state = .disconnected
    }

    /// Invalidates in-flight work synchronously and returns the new generation.
    private func beginGeneration() -> Int {
        generation += 1
        reconnectTask?.cancel()
        reconnectTask = nil
        listsRefreshTask?.cancel()
        listsRefreshTask = nil
        listsRefreshQueued = false
        pushedRefreshTask?.cancel()
        pushedRefreshTask = nil
        lastPushedRefresh = nil
        botChatOpens = [:]
        return generation
    }

    /// Restore errors meaning the session no longer exists on the server:
    /// 4001 session not found (`server.py:1237`), 4007 no longer live / stored
    /// session not found (`session_lifecycle.py:820`, `methods_session.py:833`),
    /// 4064 the session's profile no longer exists (`server.py:561-577`,
    /// `rpc_dispatch.py:35-36`).
    static let sessionGoneCodes: Set<Int> = [4001, 4007, 4064]

    static func isSessionGone(_ error: any Error) -> Bool {
        if let rpc = error as? RPCError { return sessionGoneCodes.contains(rpc.code) }
        return error is RestoreError
    }

    /// Restores the active session. When the server says it is gone, stays
    /// connected and drops it from screen; retrying could never succeed. Other
    /// errors (4009 "disconnect interrupt settling", 5000, -32000, …) are
    /// transient and propagate, keeping the session for the next attempt.
    ///
    /// The chat's actions wait for the restore (`ChatSession.settleIdentity`): a
    /// reclaimed chat must not be resumed by an action meanwhile as well.
    private func restoreOrDropActiveSession(ready: GatewayReady, gen: Int) async throws {
        guard let session = activeSession else { return }
        // This restore owns the chat now: a revival started on the old socket must not race it.
        session.revival?.cancel()
        let (gate, finished) = AsyncStream<Void>.makeStream()
        let gateTask = Task { for await _ in gate {} }
        session.identityGate = gateTask
        defer { finished.finish() }
        do {
            try await restoreActiveSession(ready: ready, gen: gen)
        } catch where Self.isSessionGone(error) {
            guard gen == generation else { throw CancellationError() }
            activeSession = nil
        }
    }

    private func discardClient() async {
        inboundTask?.cancel()
        inboundTask = nil
        let old = client
        client = nil
        await old?.close()
    }

    /// Opens a socket and installs the client. Throws `CancellationError`
    /// (after closing what it opened) if the generation moved on meanwhile.
    private func establish(_ gen: Int) async throws -> GatewayReady {
        guard let connector else { throw GatewayClientError.notConnected }
        let transport = try await connector.makeTransport()
        guard gen == generation else {
            await transport.close()
            throw CancellationError()
        }
        let newClient = GatewayClient(transport: transport, configuration: configuration)
        let stream = await newClient.inbound()
        let ready = try await newClient.connect()
        guard gen == generation else {
            await newClient.close()
            throw CancellationError()
        }
        client = newClient
        inboundTask?.cancel()
        inboundTask = Task { [weak self] in
            for await item in stream {
                self?.handle(item, from: newClient)
            }
        }
        return ready
    }

    // MARK: - Sessions

    public func refreshSessions(limit: Int = 50) async throws {
        guard let client else { throw GatewayClientError.notConnected }
        sessions = try await client.listSessions(limit: limit)
    }

    /// Creates a new live session and makes it active.
    @discardableResult
    public func newSession(title: String? = nil) async throws -> ChatSession {
        let token = beginSelection()
        guard let client else { throw GatewayClientError.notConnected }
        let created = try await client.createSession(SessionCreateParams(title: title))
        let session = ChatSession(snapshot: created.snapshot, storedSessionID: created.storedSessionID,
                                  title: title, connection: self)
        if token == selectionToken { activate(session) }
        return session
    }

    /// Resumes a stored session of the launch profile and makes it active.
    /// Returns the current session unchanged if it already is that stored session.
    @discardableResult
    public func open(_ summary: SessionSummary) async throws -> ChatSession {
        let token = beginSelection()
        if let current = activeSession, current.profile == nil, current.storedSessionID == summary.id {
            return keepShowing(current)
        }
        guard let client else { throw GatewayClientError.notConnected }
        if let warm = warmChat(where: { $0.profile == nil && $0.kind == .session && $0.storedSessionID == summary.id }) {
            return revisit(warm, token: token, client: client)
        }
        beginOpening(PendingChat(profile: nil, kind: .session, title: summary.title), token: token)
        defer { endOpening(token) }
        let resumed = try await resume(summary.id, profile: nil, client: client)
        let session = ChatSession(snapshot: resumed.snapshot, storedSessionID: summary.id, title: summary.title,
                                  connection: self)
        try await show(OpenedChat(session: session, resumed: resumed), token: token, client: client)
        return session
    }

    /// REST reads of stored transcripts, with this connection's credential.
    var messagesSource: (any SessionMessagesSource)? { connector?.messagesSource }

    /// `session.resume` with a bounded ack, and the newest transcript page read
    /// alongside it, as Desktop opens chats (`use-session-actions/index.ts:2169-2194`).
    ///
    /// The concurrent read can predate a turn that finished before this socket
    /// was attached, whose events this socket never saw. It is kept only when the
    /// ack says the runtime session is still hydrating: no turn has run on it yet
    /// (`server.py:1066-1074`). Otherwise the page is read again after the ack;
    /// from then on every turn reaches this socket.
    /// - Parameter started: a read of the same page already started (a Bot Chat's
    ///   page, read while its registry lookup ran).
    func resume(_ key: String, profile: String?, client: GatewayClient,
                prefetch started: Task<LatestHistory, any Error>? = nil) async throws -> ResumedChat {
        let prefetch = started ?? latestPageRead(key, profile: profile)
        do {
            let snapshot = try await client.resumeSession(storedSessionID: key, profile: profile)
            if snapshot.hydrating == true, (snapshot.storedKey ?? key) == key { return ResumedChat(snapshot: snapshot, prefetch: prefetch) }
            prefetch?.cancel()
            return ResumedChat(snapshot: snapshot, prefetch: nil)
        } catch {
            prefetch?.cancel()
            throw error
        }
    }

    /// The bytes of an image stored on the gateway (an `@image:` path, or the path an
    /// upload answered), read for `profile` (see `DashboardConnector.imageData`).
    /// Throws `GatewayClientError.notConnected` when this connection has no REST access.
    public func imageData(path: String, profile: String?) async throws -> Data {
        guard let source = connector?.mediaSource else { throw GatewayClientError.notConnected }
        return try await source.imageData(path: path, profile: profile)
    }

    /// A read of a stored transcript's newest page, started now.
    func latestPageRead(_ key: String, profile: String?) -> Task<LatestHistory, any Error>? {
        messagesSource.map { source in
            let query = SessionMessagesQuery(sessionID: key, profile: profile, limit: ChatSession.pageSize)
            return Task { try await ChatSession.fetchLatest(query, from: source) }
        }
    }

    /// The chat's composer: draft, attached images, model and effort pickers. It
    /// lives with the chat, not with its view, so nothing typed or attached is lost
    /// when another chat is shown or being opened (whether that open succeeds, fails
    /// or is cancelled), and a warm chat comes back with its draft. It goes when the
    /// chat leaves the warm cache (`warmChatLimit`) or on `disconnect()`.
    public func composer(for session: ChatSession) -> ChatComposer {
        let key = ObjectIdentifier(session)
        if let existing = composers[key] { return existing }
        let made = ChatComposer(session: session)
        composers[key] = made
        return made
    }

    /// A chat that can no longer be shown takes its composer with it.
    func forgetComposer(of session: ChatSession) {
        composers[ObjectIdentifier(session)] = nil
    }

    /// No chat on screen (the one shown can no longer be).
    func clearActiveSession() {
        activeSession = nil
    }

    /// The user picked the chat already on screen: it stays, and an open still in
    /// flight for another chat no longer hides it (that open, superseded by the new
    /// selection, will not take the screen either).
    func keepShowing(_ current: ChatSession) -> ChatSession {
        opening = nil
        return current
    }

    /// Shows `chat` as opening, on behalf of the open holding `token`.
    func beginOpening(_ chat: PendingChat, token: Int) {
        opening = chat
        openingToken = token
    }

    /// The open holding `token` ended (shown, failed or superseded by itself).
    func endOpening(_ token: Int) {
        if openingToken == token { opening = nil }
    }

    /// Starts a user-initiated open; see `selectionToken`.
    func beginSelection() -> Int {
        selectionToken += 1
        return selectionToken
    }

    /// Activates an opened chat unless a newer open started meanwhile, then
    /// re-delivers its open server requests. Throws `CancellationError` if the
    /// socket was replaced meanwhile: the chat was opened on the old one.
    ///
    /// An open that lost the race still stays attached to this socket, so its
    /// open requests are re-delivered too: they land in `otherSessionRequests`
    /// and, through `sessionProfiles`, on the bot's row.
    func show(_ opened: OpenedChat, token: Int, client: GatewayClient) async throws {
        guard client === self.client else {
            opened.prefetch?.cancel()
            throw CancellationError()
        }
        if let profile = opened.session.profile { sessionProfiles[opened.session.sessionID] = profile }
        track(opened.session)
        if token == selectionToken, activeSession !== opened.session { activate(opened.session) }
        // On screen first; the stored transcript fills in as its newest page arrives.
        opened.session.loadHistory(prefetch: opened.prefetch)
        await client.redeliver(opened.openRequests)
    }

    func activate(_ session: ChatSession) {
        activeSession = session
        opening = nil
        warmChats.removeAll { $0 === session }
        warmChats.insert(session, at: 0)
        if warmChats.count > Self.warmChatLimit { warmChats.removeLast(warmChats.count - Self.warmChatLimit) }
        // A chat that left the cache takes its draft with it.
        let warm = Set(warmChats.map { ObjectIdentifier($0) })
        composers = composers.filter { warm.contains($0.key) }
        if let profile = session.profile { sessionProfiles[session.sessionID] = profile }
        track(session)
        // Requests already queued for this session move into its transcript.
        let mine = otherSessionRequests.filter { $0.sessionID == session.sessionID }
        otherSessionRequests.removeAll { $0.sessionID == session.sessionID }
        for request in mine { session.receive(request) }
    }

    // MARK: - Inbound

    private func handle(_ item: GatewayClient.Inbound, from source: GatewayClient) {
        guard source === client else { return }  // stale connection
        switch item {
        case .event(let event):
            // Sidebar rows, notices, reclaimed runtimes (`GatewayConnection+Live`).
            handleConnectionEvent(event)
            // The active chat, and the warm ones behind it while this socket still
            // serves them: going back to one then shows what happened meanwhile.
            for session in eventTargets(event.sessionID ?? "") {
                session.apply(event)
                // A finished turn moved the bot's preview / the History rows: at once,
                // and the turn's own `sessions.changed` collapse behind it.
                if case .messageComplete = event.kind, session.profile != nil {
                    schedulePushedRefresh(immediately: true)
                }
            }

        case .serverRequest(let request):
            if let session = activeSession, request.sessionID == session.sessionID {
                session.receive(request)
            } else if !otherSessionRequests.contains(where: { $0.id == request.id }) {
                otherSessionRequests.append(request)
            }

        case .disconnected(let error):
            client = nil
            inboundTask = nil
            if error != nil, connector != nil { startReconnect() }
        }
    }

    // MARK: - Reconnect

    private func startReconnect() {
        guard reconnectTask == nil else { return }
        let gen = generation
        reconnectTask = Task { [weak self] in
            await self?.reconnectLoop(gen)
        }
    }

    private func reconnectLoop(_ gen: Int) async {
        var attempt = 0
        while gen == generation, connector != nil {
            attempt += 1
            state = .reconnecting(attempt: attempt)
            do { try await Task.sleep(for: backoff(attempt)) } catch { return }
            guard gen == generation else { return }
            do {
                let ready = try await establish(gen)
                try await restoreOrDropActiveSession(ready: ready, gen: gen)
                guard gen == generation else { return }
                committedEpoch = ready.replayEpoch
                state = .connected
                reconnectTask = nil
                flushStrandedImagesInBackground()
                try? await refreshSessions()
                refreshListsInBackground()
                return
            } catch {
                guard gen == generation else { return }
                // Never keep a half-restored socket around (it would linger
                // until deinit, still subscribed to the session).
                await discardClient()
                if case DashboardError.unauthenticated(let reason) = error {
                    state = .failed("Authentication failed\(reason.map { ": \($0)" } ?? "")")
                    break
                }
                if case DashboardError.invalidCredentials = error {
                    state = .failed(Self.describe(error))
                    break
                }
                if case DashboardError.refreshRejected = error {
                    state = .failed(Self.describe(error))
                    break
                }
                if let max = maxReconnectAttempts, attempt >= max {
                    state = .failed(Self.describe(error))
                    break
                }
            }
        }
        if gen == generation { reconnectTask = nil }
    }

    private func restoreActiveSession(ready: GatewayReady, gen: Int) async throws {
        guard let session = activeSession, let client else { return }
        // A reclaimed runtime has nothing to re-attach to.
        if !session.isRuntimeGone, let committedEpoch, committedEpoch == ready.replayEpoch,
            let lastSeq = session.lastSeq
        {
            do {
                let result = try await client.reattach(sessionID: session.sessionID, lastSeen: lastSeq)
                guard gen == generation else { throw CancellationError() }
                if result.isComplete {
                    session.update(from: result.snapshot)
                    let open = (result.replay.openRequests + (result.snapshot.openRequests ?? [])).map(\.id)
                    session.retainRequests(ids: Set(open))
                    return
                }
            } catch is RPCError {
                // 4001 not found / 4007 no longer live: the runtime session is gone; resume it.
            }
        }
        try await coldRestore(session, client: client, gen: gen)
    }

    /// Resumes `session` from its stored key on `client` and rebuilds its transcript.
    func coldRestore(_ session: ChatSession, client: GatewayClient, gen: Int) async throws {
        // A Bot Chat is found by its name again, never by the id it had before the
        // outage (see `botChatRestoreTarget`). Other sessions resume their stored key.
        let target: String
        if session.kind == .botChat, let profile = session.profile {
            target = try await botChatRestoreTarget(profile: profile, client: client)
            guard gen == generation else { throw CancellationError() }
        } else {
            target = session.storedSessionID ?? session.sessionID
        }
        // A profile's session lives in that profile's state.db: resume it there.
        let resumed = try await resume(target, profile: session.profile, client: client)
        guard gen == generation, client === self.client, !Task.isCancelled else {
            resumed.prefetch?.cancel()
            throw CancellationError()
        }
        // The snapshot supersedes the old transcript, older pages included; the
        // newest page is read again and pages in flight for the old one are dropped.
        session.reset(to: resumed.snapshot, storedSessionID: target)
        session.loadHistory(prefetch: resumed.prefetch)
        if let profile = session.profile { sessionProfiles[session.sessionID] = profile }
        track(session)
        await client.redeliver(resumed.snapshot.openRequests ?? [])
        // A disconnect() during that last hop must not be overwritten by the caller's `.connected`.
        guard gen == generation else { throw CancellationError() }
    }

    // MARK: - Errors

    /// A short user-facing message for errors thrown by this package. Never
    /// includes request URLs (a `?token=` credential could be in them).
    public nonisolated static func describe(_ error: any Error) -> String {
        switch error {
        case let rpc as RPCError: return rpc.message
        case BotChatError.registryUnavailable(let profile, let detail):
            return "Couldn't look up \(profile)'s Bot Chat (\(detail)). No new chat was started; try again."
        case BotChatError.registryUnconfirmed(let profile):
            return "Couldn't confirm \(profile)'s Bot Chat. No new chat was started; try again."
        case BotChatError.notRegistered(let profile, let detail):
            return "Couldn't save \(profile)'s new Bot Chat (\(detail)). Try again."
        case DashboardError.unauthenticated: return "Not signed in, or the session expired."
        case DashboardError.invalidCredentials: return "Username or password was rejected."
        case DashboardError.refreshRejected: return "The saved sign-in expired or was revoked. Sign in again."
        case DashboardError.rateLimited: return "Too many login attempts; wait a minute."
        case DashboardError.http(let status, _): return "The dashboard answered HTTP \(status)."
        case TransportError.handshakeFailed(let detail):
            // The gateway rejects bad tickets/tokens AND host/origin mismatches
            // before accepting, which surfaces as a bare HTTP 403 on the upgrade.
            return "The gateway refused the WebSocket (expired ticket/token or host check): \(detail)"
        case GatewayClientError.readyTimeout: return "The gateway did not respond."
        case HistoryReadError.noProgress:
            return "This gateway's chat history cannot be read page by page. Updating Hermes fixes this."
        case HistoryReadError.tooLong(let rows):
            return "This chat has more than \(rows) messages, too many to load from this gateway. Updating Hermes fixes this."
        case let composer as ComposerError: return composer.message
        case SessionActionError.botChatProtected:
            return "A bot's Bot Chat can't be renamed, archived or deleted."
        case SessionActionError.reservedTitle: return "\"\(Bot.chatTitle)\" is reserved for the bot's own chat."
        case SessionActionError.emptyTitle: return "Enter a title."
        case SessionActionError.notOpen: return "Open the chat first, then rename it."
        case let urlError as URLError: return urlError.localizedDescription
        default: return String(describing: error)
        }
    }
}
