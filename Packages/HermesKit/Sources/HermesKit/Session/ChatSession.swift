import Foundation
import HermesProtocol
import Observation

/// Loading state of a chat's stored transcript. Where the pages stand is
/// `Transcript.paging`.
public enum HistoryLoad: Sendable, Equatable {
    case idle
    case loadingLatest
    case loadingOlder
    /// The newest page could not be read. The chat still works; `retryHistory()`.
    case latestFailed(String)
    /// An older page could not be read; `retryHistory()` or scrolling up retries.
    case olderFailed(String)
    /// This connection cannot read stored transcripts at all; retrying cannot help.
    case unavailable(String)
}

/// Why a gateway's stored transcript could not be read to the end.
public enum HistoryReadError: Error, Sendable, Equatable {
    /// The gateway answered the same rows again: it ignores `offset` too.
    case noProgress
    /// More rows than the app reads from a gateway that ignores `order` (`rows` is that limit).
    case tooLong(rows: Int)
}

/// A stored transcript's newest rows, and whether older ones exist.
struct LatestHistory: Sendable {
    var rows: [StoredMessage]
    var hasOlder: Bool
    /// Read with `order=latest` paging: the newest rows can be read again, bounded.
    var paged = false
}

/// UI-facing state of one attached gateway session.
///
/// Created by `GatewayConnection` (`newSession` / `open`). All calls go
/// through the connection's *current* client, so the same object survives
/// reconnects.
@MainActor
@Observable
public final class ChatSession: Identifiable {
    /// Runtime id used in calls on the current connection.
    public private(set) var sessionID: String
    /// Durable DB key (stable across reconnects and backend restarts).
    public private(set) var storedSessionID: String?
    public private(set) var title: String?
    public private(set) var info: SessionLiveInfo?
    public private(set) var transcript: Transcript
    /// Highest event `seq` applied — the watermark for `session.events.since`.
    public private(set) var lastSeq: Int?
    /// The profile whose state.db holds this session (`nil` = the gateway's
    /// launch profile). Sent again on a cold resume, which otherwise looks in
    /// the launch profile's db and answers 4007.
    public nonisolated let profile: String?
    public nonisolated let kind: ChatKind
    public private(set) var historyLoad: HistoryLoad = .idle

    /// Rows per page, Desktop's `LATEST_SESSION_MESSAGES_LIMIT` (`apps/desktop/src/api/sessions.ts:502`).
    public nonisolated static let pageSize = 120

    @ObservationIgnored weak var connection: GatewayConnection?
    /// Bumped whenever the transcript is rebuilt; a page read for an older
    /// transcript is dropped.
    @ObservationIgnored private var historyGeneration = 0
    /// The stored key pages are read for, fixed when the newest page is read.
    @ObservationIgnored private var historyKey: String?
    @ObservationIgnored private(set) var historyTask: Task<Void, Never>?
    /// The read started alongside the resume, while `historyTask` waits for it.
    @ObservationIgnored private var historyPrefetch: Task<LatestHistory, any Error>?
    /// The re-read of the newest rows in flight (`rereadIfNeeded`).
    @ObservationIgnored private(set) var rereadTask: Task<Void, Never>?

    public nonisolated var id: ObjectIdentifier { ObjectIdentifier(self) }

    /// - Parameter storedSessionID: the key the caller already knows (the
    ///   `session.list` row id); resume payloads only carry it as `session_key`.
    init(snapshot: LiveSessionSnapshot, storedSessionID: String? = nil, title: String?,
         profile: String? = nil, kind: ChatKind = .session, connection: GatewayConnection?) {
        self.sessionID = snapshot.sessionID
        self.storedSessionID = snapshot.storedKey ?? storedSessionID
        self.title = title ?? snapshot.info?.title
        self.info = snapshot.info
        self.transcript = Transcript(snapshot: snapshot)
        self.profile = profile
        self.kind = kind
        self.connection = connection
    }

    /// Replaces local state with a fresh snapshot (after a cold resume).
    /// - Parameter storedSessionID: the key that was resumed, used when the
    ///   payload carries none.
    func reset(to snapshot: LiveSessionSnapshot, storedSessionID resumedKey: String? = nil) {
        sessionID = snapshot.sessionID
        storedSessionID = snapshot.storedKey ?? resumedKey ?? storedSessionID
        if let info = snapshot.info {
            self.info = info
            if let title = info.title, !title.isEmpty { self.title = title }
        }
        transcript = Transcript(snapshot: snapshot)
        lastSeq = nil
        // Pages read for the old transcript, including older ones, are dropped;
        // a read still in flight for it is cancelled.
        historyGeneration += 1
        cancelHistoryReads()
        historyLoad = .idle
    }

    private func cancelHistoryReads() {
        historyTask?.cancel()
        historyTask = nil
        historyPrefetch?.cancel()
        historyPrefetch = nil
        rereadTask?.cancel()
        rereadTask = nil
    }

    // MARK: - Stored transcript

    /// The start of the conversation is on screen.
    public var reachedBeginning: Bool { transcript.paging.isLoaded && !transcript.paging.hasOlder }

    /// Reads the newest page of the stored transcript, unless the snapshot
    /// already carried the whole history. `prefetch` is a read of the same page
    /// started alongside the resume.
    func loadHistory(prefetch: Task<LatestHistory, any Error>? = nil) {
        guard !transcript.paging.isLoaded else {
            prefetch?.cancel()
            return
        }
        guard historyLoad != .loadingLatest else { return }  // already reading it (a shared open)
        guard let source = connection?.messagesSource, let key = storedSessionID else {
            prefetch?.cancel()
            historyLoad = .unavailable("This connection cannot read the chat history.")
            return
        }
        historyGeneration += 1
        let generation = historyGeneration
        cancelHistoryReads()
        historyPrefetch = prefetch
        historyKey = key
        historyLoad = .loadingLatest
        let query = SessionMessagesQuery(sessionID: key, profile: profile, limit: Self.pageSize)
        historyTask = Task { [weak self] in
            let latest: LatestHistory
            do {
                if let prefetch {
                    latest = try await prefetch.value
                } else {
                    latest = try await Self.fetchLatest(query, from: source)
                }
            } catch {
                guard let self, generation == self.historyGeneration else { return }
                // A gateway that cannot page this history fails the same way every
                // time: no retry is offered.
                self.historyLoad = error is HistoryReadError
                    ? .unavailable(GatewayConnection.describe(error))
                    : .latestFailed(GatewayConnection.describe(error))
                return
            }
            guard let self, generation == self.historyGeneration else { return }
            self.transcript.installLatestPage(latest.rows, hasOlder: latest.hasOlder, rereadable: latest.paged)
            self.historyLoad = .idle
            self.historyPrefetch = nil
            self.rereadIfNeeded()
        }
    }

    /// Reads the page just before the oldest loaded row. Does nothing at the
    /// beginning of the conversation or while another page is being read, so at
    /// most one older page is ever in flight.
    public func loadOlderMessages() async {
        guard transcript.paging.hasOlder else { return }
        switch historyLoad {
        case .idle, .olderFailed: break
        case .loadingLatest, .loadingOlder, .latestFailed, .unavailable: return
        }
        guard let source = connection?.messagesSource, let key = historyKey else { return }
        let generation = historyGeneration
        historyLoad = .loadingOlder
        let query = SessionMessagesQuery(sessionID: key, profile: profile, limit: Self.pageSize,
                                         offset: transcript.nextOlderOffset)
        do {
            let page = try await source.messagesPage(query)
            guard generation == historyGeneration else { return }
            // A short page is the first one (`hermes_state_messages.py:1409`).
            let limit = page.pagination?.limit ?? query.limit
            let hasOlder = page.pagination != nil && limit > 0 && page.messages.count >= limit
            transcript.prependOlderPage(page.messages, hasOlder: hasOlder)
            historyLoad = .idle
        } catch is CancellationError {
            // The header left the screen: nothing failed, scrolling back reads it again.
            guard generation == historyGeneration else { return }
            historyLoad = .idle
        } catch {
            guard generation == historyGeneration else { return }
            historyLoad = .olderFailed(GatewayConnection.describe(error))
        }
    }

    /// Retries whichever page read failed.
    public func retryHistory() async {
        switch historyLoad {
        case .latestFailed:
            historyLoad = .idle
            loadHistory()
            await historyTask?.value
        case .olderFailed:
            await loadOlderMessages()
        case .idle, .loadingLatest, .loadingOlder, .unavailable:
            break
        }
    }

    /// The newest page, `order=latest` (`hermes_cli/web_routers/sessions.py:685-729`):
    /// - no `pagination` (a gateway older than paging): the whole history,
    ///   as Desktop reads it (`apps/desktop/src/store/transcript-tail.ts:132-153`);
    /// - `pagination.order` other than `latest` (a gateway that pages but ignores
    ///   `order`): the page holds the *oldest* rows. A short page is still the
    ///   whole history; otherwise the rest is read oldest first, 500 rows a page,
    ///   like Desktop's `completeTranscriptForOrderlessBackend` (`api/sessions.ts:579-592,653-698`).
    nonisolated static func fetchLatest(_ query: SessionMessagesQuery,
                                        from source: any SessionMessagesSource) async throws -> LatestHistory {
        let page = try await source.messagesPage(query)
        guard let pagination = page.pagination, let limit = pagination.limit, limit > 0 else {
            return LatestHistory(rows: page.messages, hasOlder: false)
        }
        if pagination.order == SessionMessagesOrder.latest.rawValue {
            return LatestHistory(rows: page.messages, hasOlder: page.messages.count >= limit, paged: true)
        }
        guard page.messages.count >= limit else { return LatestHistory(rows: page.messages, hasOlder: false) }
        // Bounded, unlike a gateway that might also ignore `offset`: every page must
        // bring rows not seen yet, and the read stops at `orderlessRowLimit` rows.
        // Desktop caps the same read by size (`maxJsonChars`, `api/sessions.ts:653-698`).
        var rows = page.messages
        var seen = Set(rows.compactMap(\.id))
        var last = page
        while let pagination = last.pagination, let limit = pagination.limit, limit > 0,
            !last.messages.isEmpty, last.messages.count >= limit
        {
            try Task.checkCancellation()
            guard rows.count < orderlessRowLimit else { throw HistoryReadError.tooLong(rows: orderlessRowLimit) }
            last = try await source.messagesPage(SessionMessagesQuery(
                sessionID: query.sessionID, profile: query.profile, order: .oldest, limit: 500, offset: rows.count))
            let fresh = last.messages.filter { $0.id.map { seen.insert($0).inserted } ?? true }
            guard !last.messages.isEmpty, !fresh.isEmpty else {
                if last.messages.isEmpty { break }
                throw HistoryReadError.noProgress
            }
            rows += fresh
        }
        return LatestHistory(rows: rows, hasOlder: false)
    }

    /// Most rows read from a gateway that pages but ignores `order`.
    nonisolated static let orderlessRowLimit = 20_000

    /// After a fast-path reattach: pick up the (possibly rotated) stored key.
    func update(from snapshot: LiveSessionSnapshot) {
        if let key = snapshot.storedKey { storedSessionID = key }
        if let info = snapshot.info { self.info = info }
    }

    /// Drops pending requests the server no longer lists as open.
    func retainRequests(ids: Set<String>) {
        for request in transcript.pendingRequests where !ids.contains(request.id) {
            transcript.removeRequest(id: request.id)
        }
    }

    func apply(_ event: GatewayEvent) {
        if let seq = event.seq, event.sessionID == sessionID { lastSeq = max(lastSeq ?? 0, seq) }
        switch event.kind {
        case .sessionTitle(let change):
            if change.sessionID == storedSessionID || change.sessionID == sessionID { title = change.title }
        case .sessionInfo(let newInfo):
            info = newInfo
            if let title = newInfo.title, !title.isEmpty { self.title = title }
            // Compression can rotate the stored key mid-session.
            if let key = newInfo.storedSessionID, !key.isEmpty { storedSessionID = key }
        default:
            transcript.apply(event)
            rereadIfNeeded()
        }
    }

    // MARK: - Re-reading the newest rows

    /// A turn finished (`Transcript.needsReread`): read the newest rows again and let
    /// the transcript rebuild its tail from them (`Transcript.installRereadPage`).
    /// - Bounded: the newest page, then older pages only until one holds a row
    ///   already shown, at most `rereadPageLimit` pages. Never the whole history.
    /// - One re-read at a time; one that finishes while another is needed runs again.
    /// - A failed or cancelled re-read changes nothing on screen.
    func rereadIfNeeded() {
        guard transcript.needsReread, rereadTask == nil, let source = connection?.messagesSource,
            let key = historyKey ?? storedSessionID
        else { return }
        let ticket = transcript.beginReread()
        let generation = historyGeneration
        let transcriptNow = transcript
        let profile = profile
        rereadTask = Task { [weak self] in
            var rows: [StoredMessage] = []
            var reachesStart = false
            do {
                for page in 0..<Self.rereadPageLimit {
                    let read = try await source.messagesPage(SessionMessagesQuery(
                        sessionID: key, profile: profile, limit: Self.pageSize, offset: page * Self.pageSize))
                    rows = read.messages + rows
                    reachesStart = read.messages.count < Self.pageSize
                    if reachesStart || transcriptNow.holdsAny(of: read.messages) { break }
                }
            } catch {
                rows = []
            }
            guard let self, generation == self.historyGeneration else { return }
            self.rereadTask = nil
            self.transcript.installRereadPage(rows, ticket: ticket, reachesStart: reachesStart)
            self.rereadIfNeeded()
        }
    }

    /// Most pages one re-read reads. If they reach no row shown yet, they replace the
    /// history and older rows load again by scrolling (`Transcript.installRereadPage`).
    nonisolated static let rereadPageLimit = 4

    func receive(_ request: ServerRequest) {
        transcript.addRequest(request)
    }

    // MARK: - Actions

    /// Shows the prompt immediately, then submits it. The reply streams in as events.
    public func send(_ text: String) async throws {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let itemID = transcript.appendUserPrompt(trimmed)
        do {
            let client = try currentClient()
            // Whatever the status (a turn of its own, or a busy session's steer, redirect
            // or queue, `session_auto_continue.py:398-450`), the stored rows show the
            // outcome once the session is quiet; the bubble shows until then.
            let result = try await client.submitPrompt(sessionID: sessionID, text: trimmed)
            transcript.promptAnswered(itemID: itemID, status: result.status, userRowID: result.userRowID)
            rereadIfNeeded()
        } catch {
            transcript.submitFailed(GatewayConnection.describe(error), itemID: itemID)
            throw error
        }
    }

    /// Stops the running turn.
    public func interrupt() async throws {
        try await currentClient().interrupt(sessionID: sessionID)
    }

    public func answer(_ request: ServerRequest, approval choice: ApprovalChoice, all: Bool = false) async throws {
        try await currentClient().answer(request, approval: ApprovalAnswer(choice: choice, all: all ? true : nil))
        transcript.removeRequest(id: request.id)
    }

    /// `answers == nil` cancels the clarify request.
    public func answer(_ request: ServerRequest, clarify answers: [String: String?]?) async throws {
        try await currentClient().answer(request, clarify: ClarifyAnswer(answers: answers))
        transcript.removeRequest(id: request.id)
    }

    /// sudo / secret prompts. An empty string means "skip".
    public func answer(_ request: ServerRequest, value: String) async throws {
        try await currentClient().answer(request, value: ValueAnswer(value: value))
        transcript.removeRequest(id: request.id)
    }

    private func currentClient() throws -> GatewayClient {
        guard let client = connection?.client else { throw GatewayClientError.notConnected }
        return client
    }
}
