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
    /// The background reconcile of the last time this chat was shown again
    /// (`GatewayConnection.revisit`).
    @ObservationIgnored var revisitTask: Task<Void, Never>?
    /// That reconcile is still running, on `reconcileClient`'s socket.
    @ObservationIgnored var isReconciling = false
    @ObservationIgnored weak var reconcileClient: GatewayClient?
    /// Tells the latest reconcile from one it replaced.
    @ObservationIgnored var revisitToken = 0

    /// Waits until the chat knows which runtime session it is (`GatewayConnection.revisit`
    /// may still be binding it again, resuming it, or following a Bot Chat to a new
    /// tip). A send made meanwhile would go to a runtime session the chat is about to
    /// leave, and its bubble would be dropped with the old transcript. Throws
    /// `CancellationError` when the caller is cancelled while waiting.
    /// A reconcile replaced meanwhile (one on an older socket) ends first; the wait goes
    /// on until no reconcile is in progress.
    func settleIdentity() async throws {
        while isReconciling, let task = revisitTask {
            try await waitUnlessCancelled(task)
            // Still reconciling under the same task would mean it ended without
            // clearing the flag; never spin on it.
            if task == revisitTask { break }
        }
    }

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
        // Built from the snapshot and stored rows only: no bubble is carried over.
        let old = transcript
        transcript = Transcript(snapshot: snapshot, localIDsAfter: old.lastLocalID)
        returnFailedPrompts(of: old)
        lastSeq = nil
        // Pages read for the old transcript, including older ones, are dropped;
        // a read still in flight for it is cancelled.
        historyGeneration += 1
        cancelHistoryReads()
        historyLoad = .idle
    }

    /// A rebuilt transcript shows no bubbles of the old one. A failed prompt's text
    /// goes back to the composer, ahead of anything already there, and its error stays
    /// on screen. An image send's failure already put its text and cards back
    /// (`ChatComposer.submit`), so only text-only prompts are returned here.
    /// Unanswered sends settle themselves (`send`); row-less `streaming` prompts are
    /// stored by their turn and show with its re-read.
    private func returnFailedPrompts(of old: Transcript) {
        let failed = old.failedPrompts
        guard !failed.isEmpty else { return }
        // The snapshot's own failure (a retained failed turn) is the newer news.
        if transcript.lastError == nil, let message = old.lastError { transcript.keepError(message) }
        // In the order they were sent, ahead of the draft, in one go.
        let texts = failed.filter(\.images.isEmpty).map(\.text)
        if !texts.isEmpty { returnToDraft(texts.joined(separator: "\n")) }
    }

    /// Text only a vanished bubble held goes back to the composer.
    private func returnToDraft(_ text: String) {
        connection?.composer(for: self).restoreText(text)
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

    /// Shown again after a while and bound to this socket again
    /// (`GatewayConnection.revisit`): turns another client ran meanwhile reached
    /// another socket, so read the newest rows again, or the newest page if none
    /// was read yet.
    func reconcileAfterRevisit(running: Bool) {
        transcript.reconcileRunning(running)
        if transcript.paging.isLoaded {
            transcript.requestReread()
            rereadIfNeeded()
        } else if historyLoad != .loadingLatest {
            historyLoad = .idle
            loadHistory()
        }
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
    /// Throws `ComposerError.strandedImages`, before showing anything, when
    /// images a failed send left queued could not be detached first. Cancelling
    /// the caller while it waits for that throws `CancellationError`, also
    /// before showing anything; once the prompt is shown it is submitted
    /// regardless of cancellation.
    public func send(_ text: String) async throws {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        try await settleIdentity()
        if let client = connection?.client {
            try await clearStrandedImages(using: client)
        }
        let itemID = transcript.appendUserPrompt(trimmed)
        do {
            let client = try currentClient()
            let result = try await Self.submitUncancellably(client, sessionID: sessionID, text: trimmed)
            promptAnswered(itemID: itemID, result)
        } catch {
            let message = GatewayConnection.describe(error)
            if transcript.holdsPrompt(itemID) {
                transcript.submitFailed(message, itemID: itemID)
            } else {
                // A rebuild replaced the bubble meanwhile: its text goes back to the draft.
                transcript.keepError(message)
                returnToDraft(trimmed)
            }
            throw error
        }
    }

    /// Paths of this runtime session's images that a failed send uploaded but
    /// could not take back (kept by the connection; see `StrandedImage`).
    public var strandedImagePaths: [String] {
        connection?.strandedImagePaths(sessionID: sessionID) ?? []
    }

    /// Uploads `images` (`image.attach_bytes`), then submits `text` with them.
    /// - Idle session: the turn start takes every queued image
    ///   (`tui_gateway/prompt_turn.py:147-149`).
    /// - Busy session: Hermes claims the queued images at once and queues them
    ///   with this prompt as their own turn; a prompt with images is never
    ///   steered into the running one (`tui_gateway/session_auto_continue.py:414-448`).
    ///
    /// Throws `ComposerError` before anything is shown or submitted when the
    /// app is offline, stranded images can't be cleared, or an upload fails;
    /// the images already queued are then detached. A failed submit detaches
    /// them too. Cancelling the caller before the prompt is shown throws
    /// `CancellationError` and detaches the uploads; after that the prompt is
    /// submitted regardless.
    public func send(_ text: String, images: [ComposerAttachment]) async throws {
        guard !images.isEmpty else { return try await send(text) }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        try await settleIdentity()
        let sid = sessionID
        let client: GatewayClient
        do {
            client = try currentClient()
        } catch {
            throw ComposerError.notConnected
        }
        try await clearStrandedImages(using: client)
        var queued: [String] = []
        for image in images {
            do {
                let result = try await client.attachImage(sessionID: sid, profile: profile, data: image.data,
                                                          filename: image.filename)
                guard result.attached, let path = result.path else {
                    throw RPCError(code: 0, message: result.message ?? "the gateway did not queue it")
                }
                queued.append(path)
            } catch {
                await detach(queued, using: client, sessionID: sid)
                if error is CancellationError || Task.isCancelled { throw CancellationError() }
                throw ComposerError.attachmentFailed(filename: image.filename, reason: GatewayConnection.describe(error))
            }
        }
        if Task.isCancelled {
            await detach(queued, using: client, sessionID: sid)
            throw CancellationError()
        }
        // The bubble shows the caption and the images themselves: each keeps its local
        // id (its thumbnail is on this device) and its gateway path, which the stored
        // row's `@image:` line will name, so the row shows the same image.
        let shown = zip(images, queued).enumerated().map { position, pair in
            TranscriptImage(name: pair.0.filename, path: pair.1, localID: pair.0.id, position: position)
        }
        let itemID = transcript.appendUserPrompt(trimmed, images: shown)
        do {
            let result = try await Self.submitUncancellably(client, sessionID: sid, text: trimmed)
            // The bubble settles like any prompt (and like a row-less `streaming`
            // one when the caption is empty), never by matching text or images.
            promptAnswered(itemID: itemID, result)
        } catch {
            // Ambiguous when the socket dropped: Hermes may have accepted the
            // submit (and taken the images) before the answer was lost. Then the
            // detach below settles as `detached: false`, and a retry runs the
            // message again; the client cannot tell the two cases apart.
            // Bubble gone (a rebuild): the composer takes back the text and cards.
            let message = GatewayConnection.describe(error)
            if transcript.holdsPrompt(itemID) {
                transcript.submitFailed(message, itemID: itemID)
            } else {
                transcript.keepError(message)
            }
            await detach(queued, using: client, sessionID: sid)
            throw error
        }
    }

    /// `prompt.submit` answered. Whatever the status (a turn of its own, or a busy
    /// session's steer, redirect or queue, `session_auto_continue.py:398-450`), the
    /// stored rows show the outcome once the session is quiet; the bubble shows
    /// until then.
    /// When a rebuild replaced the bubble meanwhile, the stored row shows with a
    /// re-read of the newest rows instead.
    private func promptAnswered(itemID: String, _ result: PromptSubmitResult) {
        if transcript.holdsPrompt(itemID) {
            transcript.promptAnswered(itemID: itemID, status: result.status, userRowID: result.userRowID)
        } else {
            transcript.requestReread()
        }
        rereadIfNeeded()
    }

    /// A prompt already on screen goes out even if the send is cancelled now: a
    /// cancelled request would be reported as failed while Hermes may run it.
    private static func submitUncancellably(_ client: GatewayClient, sessionID: String, text: String) async throws
        -> PromptSubmitResult
    {
        try await Task { try await client.submitPrompt(sessionID: sessionID, text: text) }.value
    }

    /// Detaches `paths`; the ones whose detach got no answer become stranded.
    /// Runs outside the caller's task, so a cancelled send still cleans up.
    private func detach(_ paths: [String], using client: GatewayClient, sessionID sid: String) async {
        guard !paths.isEmpty else { return }
        let images = paths.map { StrandedImage(sessionID: sid, profile: profile, path: $0) }
        let unanswered = await Task {
            var unanswered: [StrandedImage] = []
            for image in images where !(await GatewayConnection.detach(image, using: client)) { unanswered.append(image) }
            return unanswered
        }.value
        connection?.strand(unanswered)
    }

    /// Before a send: stranded images of this session would ride with it.
    private func clearStrandedImages(using client: GatewayClient) async throws {
        guard let connection, !(try await connection.clearStrandedImages(sessionID: sessionID, using: client)) else {
            return
        }
        throw ComposerError.strandedImages
    }

    /// The models Hermes offers this session.
    public func modelOptions() async throws -> ModelOptionsResult {
        try await currentClient().modelOptions(sessionID: sessionID, profile: profile)
    }

    /// The session's effort as the gateway reports it (`config.get reasoning`).
    public func fetchReasoningEffort() async throws -> String? {
        try await currentClient().reasoningEffort(sessionID: sessionID, profile: profile)
    }

    /// Switches this session's model (never the profile default). When the
    /// answer is `confirm_required`, nothing changed; call again with
    /// `confirmExpensiveModel` once the user agrees.
    public func setModel(_ choice: ModelChoice, confirmExpensiveModel: Bool = false) async throws -> ConfigSetResult {
        modelSwitchGeneration += 1
        let generation = modelSwitchGeneration
        let result = try await currentClient().setSessionModel(sessionID: sessionID, profile: profile,
                                                               model: choice.model, provider: choice.provider,
                                                               confirmExpensiveModel: confirmExpensiveModel)
        // Show the newest switch that was *applied*. The gateway applies them in
        // arrival order, so a success newer than the last one shown is what the
        // session runs, even when a later pick then fails or awaits confirmation.
        // A success older than the one shown (answers out of order) is stale.
        if result.confirmRequired != true, generation > appliedModelSwitchGeneration {
            appliedModelSwitchGeneration = generation
            // `session.info` follows when the agent is built; a lazy session or a
            // deferred (mid-turn) switch sends none until later, so show the pick now.
            var info = self.info ?? SessionLiveInfo()
            info.model = choice.model
            info.provider = choice.provider
            self.info = info
        }
        return result
    }

    @ObservationIgnored private var modelSwitchGeneration = 0
    @ObservationIgnored private var appliedModelSwitchGeneration = 0

    /// Sets this session's reasoning effort (`none` turns thinking off). Only
    /// `none` and `ReasoningEffort.levels` are sent: other words reach
    /// `config.set reasoning`'s display branch, which rewrites the profile's
    /// display config whatever the session (`methods_config_set.py:312-317`).
    public func setReasoningEffort(_ effort: String) async throws {
        guard ReasoningEffort.isSendable(effort) else { throw ComposerError.unsupportedEffort(effort) }
        let result = try await currentClient().setSessionReasoningEffort(sessionID: sessionID, profile: profile,
                                                                         effort: effort)
        var info = self.info ?? SessionLiveInfo()
        info.reasoningEffort = result.value?.stringValue ?? effort
        self.info = info
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
