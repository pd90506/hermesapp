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
    /// The backend reclaimed this chat's runtime (`session.reclaimed`). The next
    /// action resumes it from its stored key first, as Desktop does
    /// (`gateway-event/lifecycle.ts:123-165`).
    public internal(set) var isRuntimeGone = false
    /// The last slash-command catalog loaded for this session (`loadSlashCommands`).
    public private(set) var slashCatalog: SlashCatalog?

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
    /// Another restore of this chat's runtime in flight: a reconnect's restore
    /// (`GatewayConnection.restoreOrDropActiveSession`) or the resume of a reclaimed
    /// runtime (`revival`). Ends when that restore does, however it ends.
    @ObservationIgnored var identityGate: Task<Void, Never>?
    /// The resume of a reclaimed runtime in flight (`GatewayConnection.revive`).
    @ObservationIgnored var revival: Task<Void, any Error>?

    /// Waits until the chat knows which runtime session it is (`GatewayConnection.revisit`
    /// may still be binding it again, resuming it, or following a Bot Chat to a new
    /// tip; a reconnect or a revival may be resuming it). A send made meanwhile would go
    /// to a runtime session the chat is about to leave, and its bubble would be dropped
    /// with the old transcript; an action on a reclaimed chat would resume it a second
    /// time. Throws `CancellationError` when the caller is cancelled while waiting.
    /// A reconcile replaced meanwhile (one on an older socket) ends first; the wait goes
    /// on until no reconcile or restore is in progress.
    func settleIdentity() async throws {
        while true {
            if isReconciling, let task = revisitTask {
                try await waitUnlessCancelled(task)
                // Still reconciling under the same task would mean it ended without
                // clearing the flag; never spin on it.
                if task != revisitTask { continue }
            }
            guard let gate = identityGate else { return }
            try await waitUnlessCancelled(gate)
            if gate == identityGate { identityGate = nil }
        }
    }

    /// The runtime was reclaimed: its open requests died with it (`lifecycle.ts:143-149`),
    /// and so did a turn still shown as running here (nothing will complete it).
    func markRuntimeGone() {
        isRuntimeGone = true
        retainRequests(ids: [])
        transcript.reconcileRunning(false)
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
        transcript.adoptSentImages(of: old)
        returnFailedPrompts(of: old)
        lastSeq = nil
        isRuntimeGone = false
        // Pages read for the old transcript, including older ones, are dropped;
        // a read still in flight for it is cancelled.
        historyGeneration += 1
        cancelHistoryReads()
        historyLoad = .idle
    }

    /// A rebuilt transcript shows no bubbles of the old one. A failed prompt's text
    /// goes back to the composer, ahead of anything already there, and its error stays
    /// on screen. A send with images or files already put its text and cards back
    /// on failure (`ChatComposer.submit`), so only text-only prompts are returned here.
    /// Unanswered sends settle themselves (`send`); row-less `streaming` prompts are
    /// stored by their turn and show with its re-read.
    private func returnFailedPrompts(of old: Transcript) {
        let failed = old.failedPrompts
        guard !failed.isEmpty else { return }
        // The snapshot's own failure (a retained failed turn) is the newer news.
        if transcript.lastError == nil, let message = old.lastError { transcript.keepError(message) }
        // In the order they were sent, ahead of the draft, in one go.
        let texts = failed.filter { $0.images.isEmpty && $0.attachments.isEmpty }.map(\.text)
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
        cancelRereadRetry()
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
            applyInfo(newInfo)
        default:
            transcript.apply(event)
            rereadIfNeeded()
        }
    }

    private func applyInfo(_ newInfo: SessionLiveInfo) {
        info = newInfo
        // A turn that ended without `message.complete` (a refused `@` context) ends here
        // too: every turn body closes with `running: false` (`Transcript.serverReportsIdle`).
        if newInfo.running == false, transcript.isRunning {
            transcript.serverReportsIdle()
            if !transcript.isRunning {
                transcript.requestReread()
                rereadIfNeeded()
            }
        }
        if let title = newInfo.title, !title.isEmpty { self.title = title }
        // Compression can rotate the stored key mid-session.
        if let key = newInfo.storedSessionID, !key.isEmpty, key != storedSessionID {
            storedSessionID = key
            connection?.track(self)  // a delete of the new key must close this runtime first
        }
    }

    func setTitle(_ newTitle: String) { title = newTitle }

    // MARK: - Re-reading the newest rows

    /// A turn finished (`Transcript.needsReread`): read the newest rows again and let
    /// the transcript rebuild its tail from them (`Transcript.installRereadPage`).
    /// - Bounded: the newest page, then older pages only until one holds a row
    ///   already shown, at most `rereadPageLimit` pages. Never the whole history.
    /// - One re-read at a time; one that finishes while another is needed runs again.
    /// - A failed or cancelled re-read changes nothing on screen. A failed one is tried
    ///   again after `rereadRetryDelays` (a streak of failures stops after the last), so a
    ///   dropped read never leaves bubbles, or a queued prompt Hermes dropped without a
    ///   word, waiting for a turn that never comes.
    func rereadIfNeeded() {
        guard transcript.needsReread, rereadTask == nil, let source = connection?.messagesSource,
            let key = historyKey ?? storedSessionID
        else { return }
        let ticket = transcript.beginReread()
        let generation = historyGeneration
        // A read asked for by anything but a retry (a turn's end, a revisit, a reconnect)
        // starts a new streak: it gets every retry again, also after a long outage.
        if !rereadIsRetry { rereadFailures = 0 }
        let transcriptNow = transcript
        let profile = profile
        rereadTask = Task { [weak self] in
            var rows: [StoredMessage] = []
            var reachesStart = false
            var failed = false
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
                failed = !(error is CancellationError) && !Task.isCancelled
            }
            guard let self, generation == self.historyGeneration else { return }
            self.rereadTask = nil
            self.transcript.installRereadPage(rows, ticket: ticket, reachesStart: reachesStart)
            if failed { self.retryReread(generation: generation) } else { self.rereadFailures = 0 }
            self.rereadIfNeeded()
        }
    }

    /// Delays before trying a failed re-read again; a streak longer than this gives up
    /// until the next turn, revisit or reconnect asks for one, which starts a new streak.
    @ObservationIgnored var rereadRetryDelays: [Duration] = [.seconds(2), .seconds(8), .seconds(30)]
    @ObservationIgnored private var rereadFailures = 0
    /// Set only while a retry starts its re-read: that one continues the streak.
    @ObservationIgnored private var rereadIsRetry = false
    @ObservationIgnored private(set) var rereadRetry: Task<Void, Never>?

    private func retryReread(generation: Int) {
        guard rereadFailures < rereadRetryDelays.count else { return }
        let delay = rereadRetryDelays[rereadFailures]
        rereadFailures += 1
        rereadRetry?.cancel()
        rereadRetry = Task { [weak self] in
            do { try await Task.sleep(for: delay) } catch { return }
            guard let self, generation == self.historyGeneration else { return }
            self.rereadRetry = nil
            self.transcript.requestReread()
            self.rereadIsRetry = true
            self.rereadIfNeeded()
            self.rereadIsRetry = false
        }
    }

    /// No re-read is tried again any more: the chat was rebuilt or forgotten.
    func cancelRereadRetry() {
        rereadRetry?.cancel()
        rereadRetry = nil
        rereadFailures = 0
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
    ///
    /// A chat whose runtime was reclaimed (`isRuntimeGone`) is resumed first; when
    /// that fails, the prompt shows as failed with the reason.
    public func send(_ text: String) async throws {
        try await send(text, images: [], files: [])
    }

    /// Paths of this runtime session's images that a failed send uploaded but
    /// could not take back (kept by the connection; see `StrandedImage`).
    public var strandedImagePaths: [String] {
        connection?.strandedImagePaths(sessionID: sessionID) ?? []
    }

    /// `send(_:images:files:)` without files.
    public func send(_ text: String, images: [ComposerAttachment]) async throws {
        try await send(text, images: images, files: [])
    }

    /// Submits `text` with `files` (already staged by `attachFile`) and `images`.
    /// The files' `@file:` references go in front of the text, one per line, as
    /// Desktop sends them (`use-prompt-actions/submit.ts:224-234`); the bubble shows
    /// the text and the files' names. Images: see `sendWithImages`.
    public func send(_ text: String, images: [ComposerAttachment], files: [ComposerFile]) async throws {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let names = files.map(\.name)
        let paths = files.map(\.refPath)
        let prompt = ([files.map(\.refText).joined(separator: "\n"), trimmed].filter { !$0.isEmpty })
            .joined(separator: "\n\n")
        if !images.isEmpty { return try await sendWithImages(trimmed, prompt: prompt, images: images, files: names, filePaths: paths) }
        guard !prompt.isEmpty else { return }
        try await settleIdentity()
        // A failed resume shows on the prompt's bubble, like a failed submit.
        var reviveError: (any Error)?
        do {
            try await reviveIfGone()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            reviveError = error
        }
        if reviveError == nil, let client = connection?.client {
            try await clearStrandedImages(using: client)
        }
        let itemID = transcript.appendUserPrompt(trimmed, attachments: names, attachmentPaths: paths)
        do {
            if let reviveError { throw reviveError }
            let client = try currentClient()
            let result = try await Self.submitUncancellably(client, sessionID: sessionID, text: prompt)
            promptAnswered(itemID: itemID, status: result.status, userRowID: result.userRowID)
        } catch {
            let message = GatewayConnection.describe(error)
            if transcript.holdsPrompt(itemID) {
                transcript.submitFailed(message, itemID: itemID)
            } else {
                // A rebuild replaced the bubble meanwhile: its text goes back to the draft
                // (with files, the composer already keeps the cards and the text).
                transcript.keepError(message)
                if files.isEmpty { returnToDraft(trimmed) }
            }
            throw error
        }
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
    /// submitted regardless. A reclaimed runtime is resumed before any upload; a
    /// failed resume shows as the transcript's error, nothing else is shown.
    /// - Parameters:
    ///   - trimmed: the caption the bubble shows; `prompt`: the text submitted
    ///     (the caption behind the files' references).
    ///   - files: the names of the files the prompt references; `filePaths` their paths.
    private func sendWithImages(_ trimmed: String, prompt: String, images: [ComposerAttachment],
                                files: [String], filePaths: [String]) async throws {
        try await settleIdentity()
        do {
            try await reviveIfGone()
        } catch is CancellationError {
            throw CancellationError()
        } catch GatewayClientError.notConnected {
            throw ComposerError.notConnected
        } catch {
            transcript.keepError(GatewayConnection.describe(error))
            throw error
        }
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
        let itemID = transcript.appendUserPrompt(trimmed, images: shown, attachments: files, attachmentPaths: filePaths)
        do {
            let result = try await Self.submitUncancellably(client, sessionID: sid, text: prompt)
            // The bubble settles like any prompt (and like a row-less `streaming`
            // one when the caption is empty), never by matching text or images.
            promptAnswered(itemID: itemID, status: result.status, userRowID: result.userRowID)
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
    private func promptAnswered(itemID: String, status: String?, userRowID: Int? = nil) {
        if transcript.holdsPrompt(itemID) {
            transcript.promptAnswered(itemID: itemID, status: status, userRowID: userRowID)
        } else {
            transcript.requestReread()
        }
        rereadIfNeeded()
    }

    /// A prompt already on screen goes out even if the send is cancelled now: a
    /// cancelled request would be reported as failed while Hermes may run it.
    private static func submitUncancellably(_ client: GatewayClient, sessionID: String, text: String,
                                            queued: Bool? = nil) async throws -> PromptSubmitResult
    {
        try await Task { try await client.submitPrompt(sessionID: sessionID, text: text, queued: queued) }.value
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

    // MARK: - Files

    /// Uploads a file (a PDF, a text file, anything) into the session's attachments
    /// folder on the gateway (`file.attach`) and returns it with the `@file:`
    /// reference a `send` puts in front of its text. `ChatComposer.attachFile` sends
    /// images that need no conversion through the image queue instead.
    /// Throws `ComposerError` when the file is empty or too large, the app is
    /// offline, or the gateway did not stage it.
    public func attachFile(_ data: Data, filename: String, mimeType: String? = nil) async throws -> ComposerFile {
        if let reason = FileAttachmentPolicy.rejection(byteCount: data.count) {
            throw ComposerError.attachmentFailed(filename: filename, reason: reason)
        }
        let client: GatewayClient
        do {
            client = try await liveClient()
        } catch GatewayClientError.notConnected {
            throw ComposerError.notConnected
        }
        let result: FileAttachResult
        do {
            result = try await client.attachFile(sessionID: sessionID, data: data, name: filename, mimeType: mimeType)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw ComposerError.attachmentFailed(filename: filename, reason: GatewayConnection.describe(error))
        }
        guard result.attached, let ref = result.refText, !ref.isEmpty else {
            throw ComposerError.attachmentFailed(filename: filename, reason: "the gateway did not stage it")
        }
        return ComposerFile(name: result.name?.nonEmpty ?? filename, byteCount: data.count, refText: ref,
                            path: result.path?.nonEmpty)
    }

    // MARK: - Model and reasoning effort

    /// The models Hermes offers this session (the profile's, while a reclaimed
    /// runtime waits to be resumed).
    public func modelOptions() async throws -> ModelOptionsResult {
        try await currentClient().modelOptions(sessionID: isRuntimeGone ? nil : sessionID, profile: profile)
    }

    /// The session's effort as the gateway reports it (`config.get reasoning`);
    /// the last one known while a reclaimed runtime waits to be resumed.
    public func fetchReasoningEffort() async throws -> String? {
        if isRuntimeGone { return info?.reasoningEffort }
        return try await currentClient().reasoningEffort(sessionID: sessionID, profile: profile)
    }

    /// Switches this session's model (never the profile default). When the
    /// answer is `confirm_required`, nothing changed; call again with
    /// `confirmExpensiveModel` once the user agrees.
    public func setModel(_ choice: ModelChoice, confirmExpensiveModel: Bool = false) async throws -> ConfigSetResult {
        modelSwitchGeneration += 1
        let generation = modelSwitchGeneration
        let client = try await liveClient()
        let result = try await client.setSessionModel(sessionID: sessionID, profile: profile,
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
        let client = try await liveClient()
        let result = try await client.setSessionReasoningEffort(sessionID: sessionID, profile: profile, effort: effort)
        var info = self.info ?? SessionLiveInfo()
        info.reasoningEffort = result.value?.stringValue ?? effort
        self.info = info
    }

    /// Stops the running turn. A reclaimed runtime has nothing running.
    public func interrupt() async throws {
        guard !isRuntimeGone else { return }
        let client = try currentClient()
        // Their submits reach Hermes before the Stop: one answered `queued` was cleared by it,
        // even when its answer arrives after the Stop's.
        let sentBeforeStop = transcript.unansweredPrompts
        let result = try await client.interrupt(sessionID: sessionID)
        // Hermes cleared its queue with the Stop (`session_lifecycle.py:708-712`). Only a
        // hosted-task check answers `not_interrupted`, before touching it.
        if result.status != "not_interrupted" { transcript.serverClearedQueue(sentBeforeStop: sentBeforeStop) }
    }

    // MARK: - Steering a running turn

    /// Injects guidance into the running turn: the agent sees it with its next
    /// tool result, without a new user turn (`session.steer`,
    /// `methods_session.py:2444-2482`). The transcript shows it as a `steer`
    /// prompt until the stored row (`display_kind: "steer"`) replaces it. With no
    /// turn running the gateway answers `rejected`, and the text is sent as a
    /// normal prompt instead.
    @discardableResult
    public func steer(_ text: String) async throws -> SteerOutcome {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .ignored }
        let client = try await liveClient()
        let result = try await client.steer(sessionID: sessionID, text: trimmed)
        guard result.status == "queued" else {
            try await send(trimmed)
            return .sentAsPrompt
        }
        let itemID = transcript.appendUserPrompt(trimmed, displayKind: "steer")
        promptAnswered(itemID: itemID, status: "steered")
        return .steered
    }

    /// Stops the current model request and continues the turn with `text`
    /// (`session.redirect`). This is what Desktop does when you press Enter
    /// while a turn is running (`use-prompt-actions/index.ts:775-895`), and the
    /// row is placed the same way: a user row below the reply so far, added
    /// before the call (the turn's end can race its answer). While the turn is
    /// still being set up the gateway queues the text as the next turn instead
    /// (`queued`, `methods_session.py:2453-2469`); the row then moves to the end.
    /// Anything else withdraws the row and sends the text as a prompt. The row
    /// settles like any prompt: the stored rows replace it once the session is quiet.
    @discardableResult
    public func redirect(_ text: String) async throws -> SteerOutcome {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .ignored }
        let client = try await liveClient()
        let itemID = transcript.appendUserPrompt(trimmed)
        let result: SessionCorrectionResult
        do {
            result = try await client.redirect(sessionID: sessionID, text: trimmed)
        } catch {
            transcript.withdrawPrompt(itemID)
            throw error
        }
        switch result.status {
        case "redirected":
            promptAnswered(itemID: itemID, status: "redirected")
            return .redirected
        case "queued":
            transcript.movePromptToEnd(itemID)
            promptAnswered(itemID: itemID, status: "queued")
            return .queuedForNextTurn
        default:
            transcript.withdrawPrompt(itemID)
            try await send(trimmed)
            return .sentAsPrompt
        }
    }

    /// Asks a side question ("by the way") answered from a snapshot of the
    /// conversation without touching the running turn or its history
    /// (`prompt.btw`). The transcript shows it as a local system row whose
    /// `sideQuestion.answer` fills in when `btw.complete` arrives.
    public func askBTW(_ question: String) async throws {
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let client = try await liveClient()
        let taskID = try await client.askBTW(sessionID: sessionID, text: trimmed)
        transcript.beginSideQuestion(taskID: taskID, question: trimmed)
    }

    /// Runs `prompt` on a fresh agent in the background (`prompt.background`,
    /// `/bg`). The transcript shows a local system row whose `sideQuestion.answer`
    /// fills in when `background.complete` arrives (`gateway-event/status.ts:212-240`).
    public func startBackgroundTask(_ prompt: String) async throws {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let client = try await liveClient()
        let taskID = try await client.startBackgroundTask(sessionID: sessionID, text: trimmed)
        transcript.beginSideQuestion(taskID: taskID, question: trimmed, kind: .background)
    }

    /// Compresses the conversation context (`session.compress`, `/compress`),
    /// optionally focused on a topic. Like Desktop (`use-prompt-actions/slash.ts:684-865`)
    /// the transcript keeps the earlier messages and gains the summary line.
    @discardableResult
    public func compress(focusTopic: String? = nil) async throws -> String {
        let client = try await liveClient()
        let topic = focusTopic?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
        let result = try await client.compress(sessionID: sessionID, focusTopic: topic)
        if let info = result.info { applyInfo(info) }
        let message: String
        if result.status == "pending" {
            message = result.message?.nonEmpty ?? "compression still running in the background"
        } else if result.compressed == false, let skipped = result.message?.nonEmpty {
            message = skipped  // another compression holds the lock (`methods_session.py:2160-2163`)
        } else if let summary = result.summary, let headline = summary.headline?.nonEmpty {
            message = [headline, summary.tokenLine?.nonEmpty, summary.note?.nonEmpty].compactMap { $0 }
                .joined(separator: "\n")
        } else if let removed = result.removed, removed > 0 {
            message = "compressed \(removed) messages"
        } else {
            message = "nothing to compress"
        }
        transcript.appendNote(message)
        return message
    }

    // MARK: - Slash commands

    /// Loads the commands available in this session: built-ins, the profile's
    /// quick commands, plugin commands and skills (`commands.catalog`).
    @discardableResult
    public func loadSlashCommands() async throws -> SlashCatalog {
        let client = try await liveClient()
        let catalog = SlashCatalog(try await client.commandsCatalog(sessionID: sessionID))
        slashCatalog = catalog
        return catalog
    }

    /// Ranked completions for a typed `/` prefix (`complete.slash`).
    public func completeSlash(_ text: String) async throws -> SlashCompletions {
        guard text.hasPrefix("/") else { return SlashCompletions(CompleteSlashResult(items: []), text: text) }
        let client = try await liveClient()
        return SlashCompletions(try await client.completeSlash(text: text, sessionID: sessionID), text: text)
    }

    /// Runs a slash command typed in the composer, following Desktop's routing
    /// (`use-prompt-actions/slash.ts:262-464,1332-1389`):
    /// - in a Bot Chat, `/new`, `/reset` and `/clear` compress instead: the
    ///   bot's chat never restarts (`plugins/hermes-bots/plugin.tsx:765-800`);
    /// - commands that are a plain RPC run here: `/btw`, `/bg`, `/compress`,
    ///   `/save`, `/status`, `/title`, `/stop`;
    /// - Desktop's client-side actions and pickers come back as `.clientAction`,
    ///   with the command's canonical name when the catalog knows the alias;
    /// - the rest goes to the gateway, after the catalog's gate (loaded first if
    ///   needed; a failed load throws): commands unavailable in a GUI and
    ///   subcommands outside `desktop_subcommands` come back as `.unavailable`.
    ///   Then `slash.exec`, and on any error `command.dispatch`. A skill (or
    ///   another composed prompt) is sent as a normal prompt, queued behind a
    ///   running turn.
    public func runSlash(_ text: String) async throws -> SlashOutcome {
        try await runSlash(text, depth: 0)
    }

    private func runSlash(_ text: String, depth: Int) async throws -> SlashOutcome {
        let (typed, argument) = SlashCommand.parse(text)
        guard !typed.isEmpty else { return .unavailable("Type a command after /.") }
        let known = slashCatalog.map { String($0.canonicalName(typed).dropFirst()) }
        func isOne(of names: Set<String>) -> Bool { names.contains(typed) || known.map(names.contains) == true }

        if kind == .botChat, isOne(of: ["new", "reset", "clear"]) {
            transcript.appendNote("Bot chats are one continuous conversation — compacting instead.")
            return .output(try await compress())
        }
        if isOne(of: ["btw"]) {
            guard !argument.isEmpty else { return note("Usage: /btw <question>") }
            try await askBTW(argument)
            return .handled
        }
        if isOne(of: ["bg", "background"]) {
            guard !argument.isEmpty else {
                return note("Usage: /background <prompt> — the result appears here when done.")
            }
            try await startBackgroundTask(argument)
            return .handled
        }
        if isOne(of: ["compress", "compact"]) { return .output(try await compress(focusTopic: argument)) }
        if isOne(of: ["save"]) {
            let file = try await liveClient().save(sessionID: sessionID).file
            return note(file.map { "Saved transcript to \($0)" } ?? "Saved transcript.")
        }
        if isOne(of: ["status"]) { return note(try await liveClient().status(sessionID: sessionID).output) }
        if isOne(of: ["title"]) {
            guard !argument.isEmpty else { return note("Title: \(title ?? "untitled")") }
            guard let connection else { throw GatewayClientError.notConnected }
            try await connection.rename(self, to: argument)
            return note("Renamed to \(argument).")
        }
        if isOne(of: ["stop"]) {
            // Desktop's `/stop` (`use-prompt-actions/slash.ts:525-570`): the running turn,
            // then the registry's meaning, every background process (`commands.py:124`).
            var lines: [String] = []
            do {
                try await interrupt()
                lines.append("Stopped the active turn.")
            } catch {
                lines.append("Could not stop the active turn: \(GatewayConnection.describe(error))")
            }
            do {
                let killed = try await currentClient().stopProcesses().killed
                lines.append(killed > 0 ? "Stopped \(killed) background process\(killed == 1 ? "" : "es")."
                                        : "No background processes to stop.")
            } catch {
                lines.append("Could not stop background processes: \(GatewayConnection.describe(error))")
            }
            return note(lines.joined(separator: "\n"))
        }
        if isOne(of: SlashCommand.clientActions) {
            // The canonical name when the typed one is an alias the catalog knows.
            let name = known.flatMap { SlashCommand.clientActions.contains($0) ? $0 : nil } ?? typed
            return .clientAction(name: name, argument: argument)
        }

        // Gateway-bound: gate on the catalog, loading it if this session has none.
        let catalog: SlashCatalog
        if let loaded = slashCatalog { catalog = loaded } else { catalog = try await loadSlashCommands() }
        if let reason = catalog.refusal(for: typed, argument: argument) { return .unavailable(reason) }
        let name = String(catalog.canonicalName(typed).dropFirst())

        let client = try await liveClient()
        let commandLine = argument.isEmpty ? name : "\(name) \(argument)"
        let result: SlashCommandResult
        do {
            result = try await client.slashExec(sessionID: sessionID, command: commandLine)
        } catch let execError {
            // Skills, quick commands and anything the worker refused (`slash.ts:430-463`).
            do {
                result = try await client.commandDispatch(name: name, arg: argument.isEmpty ? nil : argument,
                                                          sessionID: sessionID)
            } catch let dispatchError as RPCError
                where dispatchError.message.range(of: #"not a quick/plugin/(bundle/)?skill command"#,
                                                  options: [.regularExpression, .caseInsensitive]) != nil
            {
                // The fallback had nothing to add: the worker's failure is the real error.
                throw execError
            }
        }
        guard let type = result.type else {
            var output = result.output ?? ""
            if let warning = result.warning, !warning.isEmpty { output = "warning: \(warning)\n\(output)" }
            return note(output.isEmpty ? "(no output)" : output)
        }
        switch type {
        case "exec", "plugin":
            return note(result.output ?? "(no output)")
        case "alias":
            guard let target = result.target, depth < 3 else { return note("/\(name): bad alias") }
            return try await runSlash("/\(target)\(argument.isEmpty ? "" : " \(argument)")", depth: depth + 1)
        default:
            break
        }
        if let notice = result.notice?.trimmingCharacters(in: .whitespacesAndNewlines), !notice.isEmpty,
            type == "send" || type == "prefill"
        {
            transcript.appendNote(notice)
        }
        let message = (result.message ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if type == "prefill" { return .prefill(message) }
        guard type == "send" || type == "skill" else { return note("/\(name): unsupported result \(type)") }
        guard !message.isEmpty else {
            return note("/\(name): \(type == "skill" ? "skill payload missing message" : "empty message")")
        }
        // Show the invocation, never the expanded skill body; the stored row shows
        // it the same way (`StoredMessageProjection.skillInvocation`).
        let display = result.display?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
            ?? (argument.isEmpty ? "/\(name)" : "/\(name) \(argument)")
        // Images a failed send left queued would ride with this prompt, as with `send`.
        try await clearStrandedImages(using: client)
        let running = transcript.isRunning
        let itemID = transcript.appendUserPrompt(display)
        do {
            let answer = try await Self.submitUncancellably(client, sessionID: sessionID, text: message,
                                                            queued: running ? true : nil)
            promptAnswered(itemID: itemID, status: answer.status, userRowID: answer.userRowID)
        } catch {
            let failure = GatewayConnection.describe(error)
            if transcript.holdsPrompt(itemID) { transcript.submitFailed(failure, itemID: itemID) } else {
                transcript.keepError(failure)
            }
            throw error
        }
        return .submitted(display: display)
    }

    private func note(_ text: String) -> SlashOutcome {
        transcript.appendNote(text)
        return .output(text)
    }

    /// Device-local feedback for client actions and unavailable commands.
    public func appendLocalNote(_ text: String) {
        transcript.appendNote(text)
    }

    // MARK: - Server requests

    public func answer(_ request: ServerRequest, approval choice: ApprovalChoice, all: Bool = false) async throws {
        try await currentClient().answer(request, approval: ApprovalAnswer(choice: choice, all: all ? true : nil))
        transcript.removeRequest(id: request.id)
    }

    /// `answers == nil` cancels the clarify request.
    public func answer(_ request: ServerRequest, clarify answers: [String: String?]?) async throws {
        try await currentClient().answer(request, clarify: ClarifyAnswer(answers: answers))
        transcript.removeRequest(id: request.id)
    }

    /// Answers a clarify request from per-question selections (multi-select
    /// included); questions without a selection are sent as skipped. Throws
    /// `ComposerError.notAClarifyRequest` for any other request.
    public func answer(_ request: ServerRequest, selections: [String: ClarifySelection]) async throws {
        guard case .clarify(let clarify) = request.kind else { throw ComposerError.notAClarifyRequest }
        try await answer(request, clarify: clarify.answers(for: selections))
    }

    /// sudo / secret prompts. An empty string means "skip".
    public func answer(_ request: ServerRequest, value: String) async throws {
        try await currentClient().answer(request, value: ValueAnswer(value: value))
        transcript.removeRequest(id: request.id)
    }

    // MARK: - Clients

    private func currentClient() throws -> GatewayClient {
        guard let client = connection?.client else { throw GatewayClientError.notConnected }
        return client
    }

    /// Resumes a reclaimed runtime (`isRuntimeGone`) from its stored key first.
    private func reviveIfGone() async throws {
        guard isRuntimeGone else { return }
        guard let connection else { throw GatewayClientError.notConnected }
        do {
            try await connection.revive(self)
        } catch is CancellationError where !Task.isCancelled {
            // A reconnect took the restore over (it cancels a revival in flight):
            // wait for it, and resume only if it did not.
            try await settleIdentity()
            if isRuntimeGone { try await connection.revive(self) }
        }
    }

    /// The current client, once the chat knows its runtime session and that runtime
    /// is live: every session-scoped call needs a live runtime id.
    func liveClient() async throws -> GatewayClient {
        try await settleIdentity()
        try await reviveIfGone()
        return try currentClient()
    }
}
