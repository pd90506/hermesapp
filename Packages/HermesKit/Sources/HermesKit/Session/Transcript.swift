import Foundation
import HermesProtocol

/// One row of the chat as the UI shows it.
public struct TranscriptItem: Sendable, Hashable, Identifiable {
    public enum Role: Sendable, Hashable {
        case user, assistant, tool, system
    }

    public var id: String
    public var role: Role
    public var text: String
    /// Assistant reasoning/thinking streamed alongside the reply.
    public var reasoning: String = ""
    /// Tool rows: the tool name.
    public var toolName: String?
    /// Tool rows: short context at start (command/path), summary when done.
    public var detail: String?
    /// Assistant: still receiving deltas. Tool: still running.
    public var isActive: Bool = false
    /// Assistant: `message.complete` status (`complete` | `error` | `interrupted`).
    public var outcome: String?
    /// The stored row this item shows (`messages.id`), when it came from a stored page.
    public var rowID: Int?
    /// Tool rows: the call id (`tool_call_id`, `tool.start.tool_id`).
    public var toolCallID: String?

    public init(id: String, role: Role, text: String, isActive: Bool = false) {
        self.id = id
        self.role = role
        self.text = text
        self.isActive = isActive
    }
}

/// Paging position of the stored part of a transcript.
public struct HistoryPaging: Sendable, Hashable {
    /// The latest page (or the whole history) is in.
    public internal(set) var isLoaded = false
    /// Rows exist before the oldest loaded one.
    public internal(set) var hasOlder = false
    /// Rows received in pages, hidden ones included: the server's `offset` unit,
    /// one per display row (`display_order` group, or the deduped merged lineage,
    /// `hermes_state_messages.py:1336-1357,1402-1409`), mapped 1:1 by
    /// `_project_for_display` (`web_routers/sessions.py:648-682`).
    var rowsLoaded = 0
    /// The newest rows can be read again in bounded pages: the history came from
    /// paged reads, or there was none to read. A gateway that answered without
    /// `order=latest` paging is never re-read (`ChatSession.fetchLatest`).
    var rereadable = false
}

/// What a re-read of the newest rows may settle: everything that happened before
/// it was requested (`Transcript.beginReread()`).
public struct RereadTicket: Sendable, Hashable {
    let clock: Int
    let completions: Int
    let starts: Int
}

/// Pure reducer from gateway snapshots, stored pages and events to a display transcript.
///
/// Kept free of I/O so it is fully unit-tested on Linux. Event semantics
/// follow `tui_gateway/contracts/events.py`; see `docs/protocol.md` §4.1.
///
/// **The stored rows are the source of truth.** `items[..<historyCount]` are stored
/// rows (`GET /api/sessions/{id}/messages`), oldest first. The rest are live items,
/// and only for what is not settled yet:
/// - the turn streaming now (including the turn running when the chat opened);
/// - prompts sent here;
/// - finished turns, until a re-read of the newest rows shows what was stored.
///
/// Live and stored content are never matched. When a turn finishes, `needsReread`
/// asks for the newest rows again; `installRereadPage` grafts them by row id and
/// drops the live items they now show. Until then some content can show twice (a
/// turn that was already running at open, a prompt the history already holds);
/// nothing is hidden.
public struct Transcript: Sendable, Hashable {
    public private(set) var items: [TranscriptItem] = []
    /// `items[..<historyCount]` came from stored pages.
    public private(set) var historyCount = 0
    public private(set) var paging = HistoryPaging()
    /// A turn is running (between submit/`message.start` and `message.complete`).
    public private(set) var isRunning = false
    /// Latest `status.update` text while running.
    public private(set) var status: String?
    /// Last session-level or turn error.
    public private(set) var lastError: String?
    /// Unanswered server→client requests for this session, oldest first.
    public private(set) var pendingRequests: [ServerRequest] = []
    /// A turn finished: read the newest rows again (`beginReread()`, `installRereadPage`).
    public private(set) var needsReread = false

    private var counter = 0
    /// Ids of every stored row received in a page, rendered or not.
    private var heldRowIDs: Set<Int> = []
    /// The first stored user row seen so far, when it is hidden: the session's
    /// opening prompt if the beginning turns out to be in an older, empty page.
    private var hiddenOpening: StoredMessage?

    /// Live items of the turn streaming now.
    private var turnItemIDs: Set<String> = []
    private var turnActive = false
    /// Live items of finished turns, with the completion they finished at. A re-read
    /// requested after that completion holds what the turn stored, and drops them.
    private var finishedItems: [String: Int] = [:]
    /// Prompts sent here, and how far they got.
    private var prompts: [String: PromptState] = [:]
    /// Answered prompts one quiet re-read has seen settled; the next one drops them.
    private var quietOnce: Set<String> = []
    /// Counts events that a re-read must not race: turn starts, completions, answers.
    private var clock = 0
    private var completions = 0
    private var starts = 0
    /// Appends go to the history part, not to a live turn.
    private var buildingHistory = false

    private enum PromptState: Sendable, Hashable {
        /// `prompt.submit` not answered yet.
        case sent
        /// Hermes took it (at `clock`): it is stored, or will be by the time the
        /// session is quiet again. `storedAtSubmit`: answered `streaming` with its
        /// row's id, so the row was written before the answer (`methods_prompt.py:815-819`).
        case answered(Int, storedAtSubmit: Bool)
        /// The submit failed: only this bubble holds the text.
        case failed
    }

    public init() {}

    /// Rebuilds from `session.resume` / `session.activate` / `session.create`.
    ///
    /// A resume with `omit_messages` carries no messages; the history then
    /// arrives with `installLatestPage`. A payload with messages (`session.create`,
    /// or a gateway that ignored `omit_messages`) is the whole history.
    public init(snapshot: LiveSessionSnapshot) {
        buildingHistory = true
        for message in snapshot.messages {
            switch message.role {
            case "user": append(.user, message.plainText, rowID: message.rowID)
            case "assistant":
                let text = message.plainText
                if text.isEmpty && message.reasoning == nil { continue }
                let index = append(.assistant, text, rowID: message.rowID)
                items[index].reasoning = message.reasoning ?? ""
            case "tool":
                var item = TranscriptItem(id: message.rowID.map { "row-\($0)" } ?? nextID(), role: .tool, text: "")
                item.toolName = message.name
                item.detail = message.context
                item.rowID = message.rowID
                item.toolCallID = message.toolCallID
                items.append(item)
            case "system": append(.system, message.plainText, rowID: message.rowID)
            default: continue
            }
        }
        buildingHistory = false
        historyCount = items.count
        heldRowIDs = Set(items.compactMap(\.rowID))
        // An ack that says it left the messages out (`hydrating`, `messages_omitted`)
        // needs a page even when `message_count` is 0: that count is the tip
        // segment's row counter (`methods_session.py:956-957`). Only a payload that
        // never omits anything (`session.create`, an unpersisted live session,
        // `methods_session.py:726-750`) is complete when empty.
        let omitted = snapshot.hydrating != nil || snapshot.messagesOmitted == true
        if !snapshot.messages.isEmpty || (snapshot.messageCount == 0 && !omitted) {
            paging = HistoryPaging(isLoaded: true, hasOlder: false, rowsLoaded: snapshot.messages.count,
                                   rereadable: snapshot.messages.isEmpty)
        }
        // The turn that was in flight when we attached: what streamed so far, or a
        // retained *failed* turn (`inflight.error`, `streaming:false`), which is over.
        if let inflight = snapshot.inflight {
            if !inflight.isFailed { startTurn() }
            var echo: String?
            if let user = inflight.user.map(StoredMessageProjection.userDisplayText), !user.isEmpty,
                items.last?.role != .user || items.last?.text != user
            {
                // The prompt is stored at submit (`methods_prompt.py:817-820`): until the
                // turn's re-read it shows twice.
                echo = items[append(.user, user)].id
            }
            let assistant = inflight.assistant ?? ""
            if inflight.isFailed {
                // A failed turn's partial reply is kept in memory, not stored
                // (`session_auto_continue.py:524-552`): it stays. Its prompt is stored.
                if !assistant.isEmpty {
                    let index = append(.assistant, assistant)
                    items[index].outcome = inflight.status ?? "error"
                }
                lastError = inflight.error
                turnItemIDs = []
                if let echo { finishedItems[echo] = completions }
                isRunning = snapshot.running == true
            } else {
                let streaming = inflight.streaming ?? (snapshot.running == true)
                append(.assistant, assistant, active: streaming)
                isRunning = streaming || snapshot.running == true
            }
        } else if snapshot.running == true {
            startTurn()
            isRunning = true
        }
    }

    static func toolItemID(_ toolID: String) -> String { "tool-" + toolID }

    /// `message.complete`'s text for a reply stopped as a repetition loop; Hermes
    /// stores that reply hidden (`agent/repetition_guard.py:29`, `agent/turn_api_call.py:197-205`).
    static let repetitionLoopSentinel = "[the reply degenerated into a repetition loop and was interrupted]"

    // MARK: - Stored pages

    /// Where the next older page starts: the rows received, as Desktop counts
    /// (`apps/desktop/src/store/transcript-tail.ts:132-153`), less a margin.
    /// - Rows stored since the newest page was read shift the server's offsets
    ///   toward the past: the next page overlaps rows already held, which
    ///   `prependOlderPage` drops.
    /// - Rows that leave the display read shift them the other way: a queued
    ///   prompt's accept-time row is deactivated when it runs
    ///   (`session_auto_continue.py:387-390`), and the read only counts active or
    ///   compacted rows (`hermes_state_messages.py:1340-1356`). Starting
    ///   `olderPageOverlap` rows early covers up to that many such rows.
    public var nextOlderOffset: Int { max(0, paging.rowsLoaded - Self.olderPageOverlap) }

    /// Rows an older page re-reads from the loaded window.
    static let olderPageOverlap = 10

    /// Replaces the history with the newest page (`order=latest`, chronological).
    /// - Parameter rereadable: the page came from a gateway that pages by `order=latest`.
    public mutating func installLatestPage(_ rows: [StoredMessage], hasOlder: Bool, rereadable: Bool = true) {
        replaceHistory(from: 0, with: rows, startsSession: !hasOlder)
        heldRowIDs = Set(rows.compactMap(\.id))
        paging = HistoryPaging(isLoaded: true, hasOlder: hasOlder, rowsLoaded: rows.count, rereadable: rereadable)
        hiddenOpening = hasOlder ? Self.hiddenFirstPrompt(rows) : nil
        // Live items that are not the streaming turn's may or may not be in this page
        // (it may have been read before they were stored): settle them by a re-read.
        if rereadable, !finishedItems.isEmpty || prompts.values.contains(where: Self.isAnswered) {
            needsReread = true
        }
    }

    /// The first user row of `rows`, if compaction stamped it hidden.
    private static func hiddenFirstPrompt(_ rows: some Collection<StoredMessage>) -> StoredMessage? {
        rows.first { $0.role == "user" }.flatMap { $0.displayKind == "hidden" ? $0 : nil }
    }

    /// Prepends the page just before the loaded rows.
    ///
    /// Offsets drift (see `nextOlderOffset`), so the page can overlap rows already
    /// held (Desktop: `transcript-backfill.ts:10-16`). It is cut at its first held row.
    public mutating func prependOlderPage(_ rows: [StoredMessage], hasOlder: Bool) {
        paging.rowsLoaded += rows.count
        let firstHeld = rows.firstIndex { $0.id.map(heldRowIDs.contains) == true } ?? rows.endIndex
        heldRowIDs.formUnion(rows.compactMap(\.id))
        let fresh = rows[..<firstHeld]
        let reachesBeginning = !hasOlder || rows.isEmpty
        var toolCalls: StoredMessageProjection.ToolCalls = [:]
        let older = uniqued(StoredMessageProjection.items(from: Array(fresh), toolCalls: &toolCalls,
                                                          startsSession: reachesBeginning))
        items.insert(contentsOf: older, at: 0)
        historyCount += older.count
        paging.hasOlder = hasOlder && !rows.isEmpty
        if fresh.contains(where: { $0.role == "user" }) {
            hiddenOpening = reachesBeginning ? nil : Self.hiddenFirstPrompt(fresh)
        } else if reachesBeginning, let opening = hiddenOpening {
            // The beginning holds no prompt (an empty page at an exact page boundary):
            // the first prompt already loaded opens the session, as in Desktop
            // (`transcript-backfill.ts:29-71,599-622`).
            hiddenOpening = nil
            var none: StoredMessageProjection.ToolCalls = [:]
            let shown = uniqued(StoredMessageProjection.items(from: [opening], toolCalls: &none, startsSession: true))
            let position = items[..<historyCount].firstIndex { ($0.rowID ?? .max) > (opening.id ?? .max) } ?? historyCount
            items.insert(contentsOf: shown, at: position)
            historyCount += shown.count
        }
    }

    // MARK: - Re-reading the newest rows

    /// Starts a re-read of the newest rows: it may settle everything up to now.
    public mutating func beginReread() -> RereadTicket {
        needsReread = false
        return RereadTicket(clock: clock, completions: completions, starts: starts)
    }

    /// Whether any of `rows` is one the history already holds.
    func holdsAny(of rows: [StoredMessage]) -> Bool {
        rows.contains { $0.id.map(heldRowIDs.contains) == true }
    }

    /// Installs a re-read of the newest rows (`order=latest`, chronological), then
    /// drops the live items it settles.
    ///
    /// - The history from the first shown row the re-read holds on is replaced by
    ///   it: newer and contiguous, it also drops rows that left the display read.
    ///   Older rows, including older pages the user loaded, stay.
    /// - If it holds no shown row (the history was empty, or more rows were stored
    ///   than the re-read covers), it becomes the history; older rows load again by
    ///   scrolling.
    /// - Finished turns' live items go: their rows were stored before their
    ///   `message.complete` (`prompt_turn.py:1182`), so a re-read requested after it
    ///   holds them. The turn streaming now stays live.
    /// - Prompts sent here go only if the session was quiet throughout: nothing
    ///   running, no turn started since the re-read was requested, every submit
    ///   answered. A follow-up turn (a queued prompt, a steer the turn could not
    ///   deliver, `prompt_turn.py:438-450`) announces itself with `message.start`
    ///   before it stores its prompt (`prompt_turn.py:421-427`); until it finishes,
    ///   the bubble stays. It takes two quiet re-reads in a row (see `quietOnce`).
    ///
    /// - Parameter reachesStart: the re-read reached the session's first row.
    public mutating func installRereadPage(_ rows: [StoredMessage], ticket: RereadTicket, reachesStart: Bool) {
        guard paging.rereadable, !rows.isEmpty else { return }
        let rereadIDs = Set(rows.compactMap(\.id))
        if let start = items[..<historyCount].firstIndex(where: { $0.rowID.map(rereadIDs.contains) == true }) {
            replaceHistory(from: start, with: rows, startsSession: reachesStart)
            paging.rowsLoaded += rereadIDs.subtracting(heldRowIDs).count
            heldRowIDs.formUnion(rereadIDs)
        } else {
            replaceHistory(from: 0, with: rows, startsSession: reachesStart)
            heldRowIDs = rereadIDs
            paging.rowsLoaded = rows.count
            paging.hasOlder = !reachesStart
            hiddenOpening = reachesStart ? nil : Self.hiddenFirstPrompt(rows)
        }
        let settled = Set(finishedItems.filter { $0.value <= ticket.completions }.keys)
        finishedItems = finishedItems.filter { !settled.contains($0.key) }
        let quiet = !turnActive && starts == ticket.starts && !prompts.values.contains(.sent)
        var eligible: Set<String> = [], storedAtSubmit: Set<String> = []
        for (id, state) in prompts where quiet {
            guard case .answered(let at, let stored) = state, at <= ticket.clock else { continue }
            eligible.insert(id)
            if stored { storedAtSubmit.insert(id) }
        }
        // A prompt answered `streaming` was stored before its answer: this read holds it.
        // Any other prompt can still be ahead of its row: a follow-up's `message.start`
        // travels on the socket, this read over HTTP, and one quiet read could beat a
        // start already sent. Such a prompt goes after a second quiet read, requested
        // once this one had landed; by then its row is stored, or a start has arrived
        // and reset `quietOnce`.
        let dropped = storedAtSubmit.union(eligible.intersection(quietOnce))
        quietOnce = eligible.subtracting(dropped)
        if !quietOnce.isEmpty { needsReread = true }
        prompts = prompts.filter { !dropped.contains($0.key) }
        removeLiveItems { settled.contains($0.id) || dropped.contains($0.id) }
    }

    /// Projects `rows` into the history from `start` on, replacing what was there.
    private mutating func replaceHistory(from start: Int, with rows: [StoredMessage], startsSession: Bool) {
        var toolCalls: StoredMessageProjection.ToolCalls = [:]
        let stored = StoredMessageProjection.items(from: rows, toolCalls: &toolCalls, startsSession: startsSession)
        items.removeSubrange(start..<historyCount)
        historyCount = start
        let unique = uniqued(stored)
        items.insert(contentsOf: unique, at: start)
        historyCount += unique.count
    }

    /// Item ids must stay unique for `ForEach`. Stored items are keyed by row
    /// (`row-<id>`), live ones never are, so this only guards against a page that
    /// repeats a row: the repeat gets a suffix.
    private func uniqued(_ stored: [TranscriptItem]) -> [TranscriptItem] {
        var seen = Set(items.map(\.id))
        return stored.map { original in
            var item = original
            var suffix = 0
            while seen.contains(item.id) {
                suffix += 1
                item.id = "\(original.id)~\(suffix)"
            }
            seen.insert(item.id)
            return item
        }
    }

    /// Removes matching items from the live part only.
    private mutating func removeLiveItems(where shouldRemove: (TranscriptItem) -> Bool) {
        let live = items[historyCount...].filter { !shouldRemove($0) }
        items.removeSubrange(historyCount...)
        items.append(contentsOf: live)
    }

    private static func isAnswered(_ state: PromptState) -> Bool {
        if case .answered = state { return true }
        return false
    }

    // MARK: - Prompts sent here

    /// Shows the user's prompt at once; call before `prompt.submit`, then
    /// `promptAnswered` or `submitFailed`. Returns the item's id. A prompt sent while
    /// a turn runs works the same: the bubble shows until the stored rows show what
    /// Hermes made of it (a turn of its own, a steer, a redirect or a queued turn,
    /// `session_auto_continue.py:398-450`).
    @discardableResult
    public mutating func appendUserPrompt(_ text: String) -> String {
        counter += 1
        let item = TranscriptItem(id: "local-\(counter)", role: .user, text: text)
        items.append(item)
        prompts[item.id] = .sent
        isRunning = true
        lastError = nil
        return item.id
    }

    /// `prompt.submit` answered, whatever its `status`: Hermes stored the prompt
    /// (`streaming`, `queued`: `methods_prompt.py:817-820`, `session_auto_continue.py:436-439`)
    /// or will before the session is quiet again (`steered`, `redirected`).
    /// `status` only decides how soon its bubble can go; no status hides it.
    /// One quiet re-read is enough only for `streaming` with the stored row's id:
    /// with compute-host isolation, or when the submit-time write fails, `streaming`
    /// comes before any row (`methods_prompt.py:798-819`). Anything else waits for two.
    public mutating func promptAnswered(itemID: String, status: String? = nil, userRowID: Int? = nil) {
        guard prompts[itemID] != nil else { return }
        clock += 1
        prompts[itemID] = .answered(clock, storedAtSubmit: status == "streaming" && userRowID != nil)
        // No turn will finish to settle it if none runs (Hermes may have dropped or
        // merged it, or its turn has not started): read the newest rows again.
        if !turnActive, paging.rereadable { needsReread = true }
    }

    /// Marks a failed submit: the bubble stays (only it holds the text), and the
    /// spinner stops unless a turn is running.
    public mutating func submitFailed(_ message: String, itemID: String? = nil) {
        lastError = message
        if let itemID, prompts[itemID] != nil { prompts[itemID] = .failed }
        if !turnActive { isRunning = false }
    }

    public mutating func addRequest(_ request: ServerRequest) {
        guard !pendingRequests.contains(where: { $0.id == request.id }) else { return }
        pendingRequests.append(request)
    }

    public mutating func removeRequest(id: String) {
        pendingRequests.removeAll { $0.id == id }
    }

    // MARK: - Events

    public mutating func apply(_ event: GatewayEvent) {
        switch event.kind {
        case .messageStart:
            startTurn()
            isRunning = true
            if activeAssistantIndex == nil { append(.assistant, "", active: true) }

        case .messageDelta(let delta):
            startTurn()
            isRunning = true
            let index = activeAssistantIndex ?? append(.assistant, "", active: true)
            items[index].text += delta.text

        case .reasoningDelta(let delta):
            startTurn()
            let index = activeAssistantIndex ?? append(.assistant, "", active: true)
            items[index].reasoning += delta.text

        case .reasoningAvailable(let delta):
            startTurn()
            let index = activeAssistantIndex ?? append(.assistant, "", active: true)
            if items[index].reasoning.isEmpty { items[index].reasoning = delta.text }

        case .messageInterim(let interim):
            startTurn()
            // Commentary beside tool calls is sealed as its own segment.
            if interim.alreadyStreamed == true, let index = activeAssistantIndex {
                items[index].isActive = false
            } else if !interim.text.isEmpty {
                sealActiveAssistant()
                append(.assistant, interim.text)
            }

        case .toolGenerating:
            startTurn()
            sealActiveAssistant()

        case .toolStart(let start):
            startTurn()
            sealActiveAssistant()
            // Call ids repeat across rounds and turns (`deterministic_call_id`,
            // `agent/message_sanitization.py:492-495`): only a start of a call still
            // running reuses its row.
            if let index = runningToolIndex(start.toolID) {
                items[index].isActive = true
            } else {
                var item = TranscriptItem(id: Self.toolItemID(start.toolID), role: .tool, text: "", isActive: true)
                item.toolName = start.name
                item.detail = start.context ?? start.preview
                item.toolCallID = start.toolID
                appendLive(item)
            }

        case .toolComplete(let complete):
            startTurn()
            if let index = runningToolIndex(complete.toolID) {
                items[index].isActive = false
                if let summary = complete.summary, !summary.isEmpty { items[index].detail = summary }
            } else {
                // Started before this chat attached.
                var item = TranscriptItem(id: Self.toolItemID(complete.toolID), role: .tool, text: "")
                item.toolName = complete.name
                item.detail = complete.summary
                item.toolCallID = complete.toolID
                appendLive(item)
            }

        case .messageComplete(let complete):
            finishTurn(complete)

        case .statusUpdate(let update):
            status = update.text.isEmpty ? nil : update.text

        case .error(let payload):
            lastError = payload.message

        case .requestCancel(let cancel):
            removeRequest(id: cancel.id)

        case .approvalCancelled(let cancelled):
            // `request_ids` are approval request ids (params.request_id), not frame ids.
            let ids = Set(cancelled.requestIDs)
            pendingRequests.removeAll { request in
                if case .approval(let approval) = request.kind { return ids.contains(approval.requestID) }
                return false
            }

        case .gatewayReady, .sessionTitle, .sessionInfo, .unknown:
            break
        }
    }

    // MARK: - Helpers

    /// A turn's first event starts it (`message.start`, or any streamed event of a
    /// turn this chat saw no start of).
    private mutating func startTurn() {
        guard !turnActive else { return }
        turnActive = true
        starts += 1
        clock += 1
        quietOnce = []
    }

    /// The live tool row of a call that is still running.
    private func runningToolIndex(_ toolID: String) -> Int? {
        items.indices.last { $0 >= historyCount && items[$0].isActive && items[$0].toolCallID == toolID }
    }

    private var activeAssistantIndex: Int? {
        guard let last = items.indices.last, last >= historyCount, items[last].role == .assistant,
            items[last].isActive
        else { return nil }
        return last
    }

    private mutating func sealActiveAssistant() {
        guard let index = activeAssistantIndex else { return }
        items[index].isActive = false
        if items[index].text.isEmpty && items[index].reasoning.isEmpty { items.remove(at: index) }
    }

    private mutating func finishTurn(_ complete: MessageComplete) {
        startTurn()  // a reply that streamed nothing still was a turn
        let finalText = complete.textValue
        // The segment that was still streaming when the turn ended.
        var streaming = activeAssistantIndex.map { items[$0].id }
        if let index = activeAssistantIndex {
            if items[index].text.isEmpty, !finalText.isEmpty, !turnShows(finalText) { items[index].text = finalText }
            if items[index].reasoning.isEmpty, let reasoning = complete.reasoning { items[index].reasoning = reasoning }
            items[index].outcome = complete.status
        } else if !finalText.isEmpty, !turnShows(finalText) {
            let index = append(.assistant, finalText)
            items[index].outcome = complete.status
            streaming = items[index].id
        } else if let index = items.indices.last, index >= historyCount, items[index].role == .assistant {
            items[index].outcome = complete.status
        }
        // Nothing keeps spinning once the turn is over, wherever its items are (a
        // prompt sent during the reply can follow its open bubble); empty bubbles go.
        for index in items.indices where index >= historyCount { items[index].isActive = false }
        removeLiveItems { $0.role == .assistant && $0.text.isEmpty && $0.reasoning.isEmpty && $0.rowID == nil }
        if complete.status == "error" { lastError = complete.error ?? "The turn failed." }
        isRunning = false
        status = nil

        // The turn's rows are stored before `message.complete` (`prompt_turn.py:1153-1182`).
        // The segment still streaming when the turn ended may not be:
        // - `error`: the partial reply is kept in memory only (`session_auto_continue.py:524-552`).
        // - `interrupted`: the agent loop stores it and sends it as this event's text
        //   (`agent/turn_api_call.py:206-214`; Stop during a tool stores the same text as a
        //   closing row, `agent/message_sanitization.py:287-299`). A repetition loop is stored
        //   hidden on purpose and sent as the sentinel. Other runtimes may store nothing
        //   (the Codex app-server, `agent/transports/codex_app_server_session.py:583-586`; its
        //   event text is the last *completed* message, `agent/codex_runtime.py:743-749`), so the
        //   segment goes only when it and the event's non-empty text are the same reply:
        //   - equal;
        //   - the segment ends with it: the segment also holds what streamed before the
        //     current call, stored by then or by this Stop (`agent/turn_api_call.py:213`).
        //     A redirect sends no event, so its pre-redirect text, stored as a placeholder
        //     (`conversation_loop.py:345-353`), runs into the same segment; so do the turn's
        //     earlier calls in the segment rebuilt at open (`session_history.py:400-408`);
        //   - it ends with the segment: a prompt sent here split the call's text into an
        //     earlier segment and this one, and the event's text, stored, holds both.
        //   An empty event text keeps the segment. This compares the turn with its own
        //   event, never with stored rows; it can leave a duplicate.
        // That segment stays live; the turn's other live items wait for the re-read.
        completions += 1
        clock += 1
        let unstored: String?
        switch complete.status {
        case "error": unstored = streaming
        case "interrupted":
            let sent = finalText.trimmingCharacters(in: .whitespacesAndNewlines)
            let shown = streaming.flatMap { id in items.first { $0.id == id } }?.text
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let sameReply = shown.map { shown in
                shown == sent
                    || (!sent.isEmpty && shown.hasSuffix(sent))
                    || (!sent.isEmpty && !shown.isEmpty && sent.hasSuffix(shown))
            } ?? false
            unstored = sent == Self.repetitionLoopSentinel || sameReply ? nil : streaming
        default: unstored = nil
        }
        for id in turnItemIDs where id != unstored { finishedItems[id] = completions }
        turnItemIDs = []
        turnActive = false
        if paging.rereadable { needsReread = true }
    }

    /// Whether the turn streaming now already shows `text` (a reply that streamed
    /// into a sealed segment). Only its own live items count.
    private func turnShows(_ text: String) -> Bool {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return items.contains {
            turnItemIDs.contains($0.id) && $0.role == .assistant
                && $0.text.trimmingCharacters(in: .whitespacesAndNewlines) == text
        }
    }

    private mutating func nextID() -> String {
        counter += 1
        return "local-\(counter)"
    }

    @discardableResult
    private mutating func append(_ role: TranscriptItem.Role, _ text: String, active: Bool = false,
                                 rowID: Int? = nil) -> Int {
        var item = TranscriptItem(id: nextID(), role: role, text: text, isActive: active)
        item.rowID = rowID
        appendLive(item)
        return items.count - 1
    }

    /// Appends to the turn streaming now (`buildingHistory`: to the history).
    private mutating func appendLive(_ item: TranscriptItem) {
        var item = item
        // Ids stay unique for `ForEach`: a reused call id gives `tool-<call>` again.
        if items.contains(where: { $0.id == item.id }) {
            counter += 1
            item.id += "~\(counter)"
        }
        items.append(item)
        if !buildingHistory { turnItemIDs.insert(item.id) }
    }
}
