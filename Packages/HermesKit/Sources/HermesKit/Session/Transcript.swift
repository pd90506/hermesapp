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
    /// User rows: the images sent with the prompt (`text` is then its caption).
    public var images: [TranscriptImage] = []
    /// User rows: names of the files sent with the prompt (`file.attach`); the stored
    /// row carries them as leading `@file:` lines (see `AttachmentRefs`).
    public var attachments: [String] = []
    /// User rows: `steer` for guidance injected into a running turn (`session.steer`;
    /// stored rows carry `display_kind: "steer"`, `agent/prompt_builder.py:594-601`).
    public var displayKind: String?
    /// Assistant: commentary written beside tool calls (`message.interim`), not the
    /// turn's final answer.
    public var isInterim: Bool = false
    /// Tool rows: everything known about the call.
    public var tool: ToolActivity?
    /// System rows: a `/btw` question or `/bg` task and its answer. Shown on this
    /// device only; never stored.
    public var sideQuestion: SideQuestion?

    public init(id: String, role: Role, text: String, isActive: Bool = false) {
        self.id = id
        self.role = role
        self.text = text
        self.isActive = isActive
    }

    /// A user row that steered a running turn rather than starting one.
    public var isSteer: Bool { displayKind == "steer" }
}

/// One tool call (`tool.start` → `tool.complete`, `contracts/events.py:261-294`).
/// The gateway has no separate output event: the output arrives with completion.
public struct ToolActivity: Sendable, Hashable {
    public enum Phase: Sendable, Hashable {
        case running
        case complete
        /// `tool.complete` carried an `error` (not in the contract; the app's own reading).
        case failed
    }

    public var toolID: String
    public var name: String
    public var phase: Phase
    /// Short preview of the main argument (command, path, query).
    public var context: String?
    public var args: JSONValue?
    public var summary: String?
    /// The tool's output: `result_text`, else the JSON `result`, as text. Stored
    /// rows keep it only for edit tools (`session_history.py:331`).
    public var output: String?
    /// Edit tools: a unified diff.
    public var inlineDiff: String?
    public var durationSeconds: Double?
    public var error: String?

    public init(toolID: String, name: String, phase: Phase = .running) {
        self.toolID = toolID
        self.name = name
        self.phase = phase
    }
}

/// A side agent's task and answer: a `/btw` question (`prompt.btw` →
/// `btw.complete`), answered from a snapshot of the conversation, or a `/bg`
/// task (`prompt.background` → `background.complete`) run on a fresh agent.
/// Neither becomes part of the conversation.
public struct SideQuestion: Sendable, Hashable {
    public enum Kind: Sendable, Hashable { case btw, background }

    public var taskID: String
    /// The question (`/btw`) or the task prompt (`/bg`).
    public var question: String?
    /// `nil` while the answer is pending.
    public var answer: String?
    public var kind: Kind = .btw

    public init(taskID: String, question: String? = nil, answer: String? = nil, kind: Kind = .btw) {
        self.taskID = taskID
        self.question = question
        self.answer = answer
        self.kind = kind
    }

    public var isPending: Bool { answer == nil }
    /// The gateway reports failures as text starting with `error: ` (`methods_prompt.py:1282-1315`).
    public var isError: Bool { answer?.hasPrefix("error:") == true }
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
///
/// **Local rows** (`appendNote`, `beginSideQuestion`: slash-command output, `/btw` and
/// `/bg` answers) are never stored, so no re-read holds them. They join the history
/// part once no unsettled live item is ahead of them, anchored to the stored row they
/// follow, and keep that place when pages are installed or re-read. A local row added
/// mid-turn moves below that turn's rows once they are stored. A rebuild
/// (`init(snapshot:)`) has none.
public struct Transcript: Sendable, Hashable {
    public private(set) var items: [TranscriptItem] = []
    /// `items[..<historyCount]` came from stored pages, or are local rows placed among them.
    public private(set) var historyCount = 0
    public private(set) var paging = HistoryPaging()
    /// A turn is running (between submit/`message.start` and `message.complete`).
    public private(set) var isRunning = false
    /// Latest `status.update` text while running.
    public private(set) var status: String?
    /// An explained provider wait from `thinking.delta` ("⏳ still waiting on …"),
    /// cleared by the next model output. Other `thinking.delta` frames are spinner
    /// text and are dropped, as in Desktop (`gateway-event/message-stream.ts:195-205`).
    public private(set) var providerWait: String?
    /// The model is writing the arguments of a call to this tool (`tool.generating`).
    public private(set) var generatingTool: String?
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
    /// `starts` when each prompt sent here was shown.
    private var promptSentAtStarts: [String: Int] = [:]
    /// `requestReread` came before the newest page: read again once it is in.
    private var rereadWhenLoaded = false
    /// Prompts answered `streaming` without `user_row_id` whose turn has not started
    /// yet: no row exists until that turn runs (see `promptAnswered`).
    private var awaitingTurn: Set<String> = []
    /// Counts events that a re-read must not race: turn starts, completions, answers.
    private var clock = 0
    private var completions = 0
    private var starts = 0
    /// Appends go to the history part, not to a live turn.
    private var buildingHistory = false
    /// Ids of local rows (see the type's note).
    private var localIDs: Set<String> = []
    /// For each local row in the history part: the id of the stored row it follows
    /// (absent: it comes before every stored row).
    private var localAnchors: [String: Int] = [:]

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
    ///
    /// - Parameter localIDsAfter: a rebuild (`ChatSession.reset`) numbers its live items
    ///   above every id the transcript it replaces used, so an id a send still holds
    ///   for its old bubble never names an item of this one.
    public init(snapshot: LiveSessionSnapshot, localIDsAfter floor: Int = 0) {
        counter = floor
        buildingHistory = true
        for message in snapshot.messages {
            switch message.role {
            case "user":
                let index = appendUser(message.plainText, rowID: message.rowID)
                items[index].displayKind = message.displayKind
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
                // `_history_to_messages` tool rows: name, context, args; content only
                // for edit tools (`session_history.py:322-334`).
                var tool = ToolActivity(toolID: message.toolCallID ?? item.id, name: message.name ?? "tool",
                                        phase: .complete)
                tool.context = message.context
                tool.args = message.args
                if case .string(let output)? = message.content { tool.output = output }
                item.tool = tool
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
                echo = items[appendUser(user)].id
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
        if rereadable, rereadWhenLoaded || !finishedItems.isEmpty || prompts.values.contains(where: Self.isAnswered) {
            needsReread = true
        }
        rereadWhenLoaded = false
        absorbLocalRows()
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

    // MARK: - Rebuilds

    /// The highest `local-n` number used (`init(snapshot:localIDsAfter:)`).
    var lastLocalID: Int { counter }

    /// Whether `itemID` is a prompt sent here that this transcript still shows. After a
    /// rebuild it is not: the send settles without its bubble (`ChatSession.send`).
    public func holdsPrompt(_ itemID: String) -> Bool { prompts[itemID] != nil }

    /// Prompts sent here whose submit failed: only their bubble holds them. A rebuild
    /// shows none of them; their text goes back to the composer (`ChatSession.reset`).
    public var failedPrompts: [TranscriptItem] {
        items[historyCount...].filter { prompts[$0.id] == .failed }
    }

    /// Keeps a failure on screen when its bubble is gone (a rebuild, or a send whose
    /// bubble a rebuild replaced).
    public mutating func keepError(_ message: String) {
        lastError = message
    }

    // MARK: - Re-reading the newest rows

    /// Asks for a re-read of the newest rows (a chat shown again: rows may have been
    /// stored while its events went to another socket).
    /// Before the newest page is in, the request waits for it.
    public mutating func requestReread() {
        if paging.isLoaded {
            if paging.rereadable { needsReread = true }
        } else {
            rereadWhenLoaded = true
        }
    }

    /// A chat shown again reports whether a turn runs now (`session.activate`).
    /// - Running: the spinner shows; the turn's events reach this socket from now on.
    /// - Not running while a turn is still open here: its `message.complete` went to
    ///   another socket. The turn ends here as it would have; its live items wait for
    ///   the re-read, which holds what it stored (`finishedItems`).
    public mutating func reconcileRunning(_ running: Bool) {
        if running {
            isRunning = true
            return
        }
        guard turnActive else { return }
        endLiveActivity()
        removeLiveItems { $0.role == .assistant && $0.text.isEmpty && $0.reasoning.isEmpty && $0.rowID == nil }
        completions += 1
        clock += 1
        for id in turnItemIDs { finishedItems[id] = completions }
        turnItemIDs = []
        turnActive = false
        isRunning = prompts.values.contains(.sent)
        status = nil
    }

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
    /// Local rows in that range go back after the stored row they followed.
    private mutating func replaceHistory(from start: Int, with rows: [StoredMessage], startsSession: Bool) {
        var toolCalls: StoredMessageProjection.ToolCalls = [:]
        let stored = StoredMessageProjection.items(from: rows, toolCalls: &toolCalls, startsSession: startsSession)
        let locals = items[start..<historyCount].filter { localIDs.contains($0.id) }
        items.removeSubrange(start..<historyCount)
        historyCount = start
        let unique = uniqued(stored)
        items.insert(contentsOf: unique, at: start)
        historyCount += unique.count
        for local in locals { placeLocalRow(local) }
    }

    // MARK: - Local rows

    /// Appends a row no stored page will ever hold (see the type's note).
    private mutating func appendLocal(_ item: TranscriptItem) {
        sealActiveAssistant()
        items.append(item)
        localIDs.insert(item.id)
        absorbLocalRows()
    }

    /// Local rows with no unsettled live item ahead of them join the history part,
    /// after the stored row shown last. Not before the newest page is in (a row
    /// added while it loads follows it), nor while a turn runs (a row added during a
    /// turn follows that turn's rows, which are not stored yet).
    private mutating func absorbLocalRows() {
        guard paging.isLoaded, !turnActive else { return }
        while historyCount < items.count, localIDs.contains(items[historyCount].id) {
            let id = items[historyCount].id
            localAnchors[id] = items[..<historyCount].last { $0.rowID != nil }?.rowID
            historyCount += 1
        }
    }

    /// Puts a local row of the history part back after its anchor row (or the
    /// newest stored row before it), behind local rows already there.
    private mutating func placeLocalRow(_ item: TranscriptItem) {
        var position = 0
        if let anchor = localAnchors[item.id],
            let row = items[..<historyCount].lastIndex(where: { $0.rowID.map { $0 <= anchor } == true })
        {
            position = row + 1
        }
        while position < historyCount, localIDs.contains(items[position].id) { position += 1 }
        items.insert(item, at: position)
        historyCount += 1
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
        absorbLocalRows()
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
    ///
    /// The reply streaming so far is sealed: later deltas open a new bubble below the
    /// prompt, as Desktop orders it (`appendAfterActiveReply`, `use-prompt-actions/index.ts:817-825`).
    /// - Parameters:
    ///   - images: the images sent with it (`text` is then the caption, possibly empty).
    ///   - attachments: names of the files sent with it.
    ///   - displayKind: `steer` for guidance injected with `session.steer`.
    @discardableResult
    public mutating func appendUserPrompt(_ text: String, images: [TranscriptImage] = [], attachments: [String] = [],
                                          displayKind: String? = nil) -> String {
        sealActiveAssistant()
        counter += 1
        var item = TranscriptItem(id: "local-\(counter)", role: .user, text: text)
        item.images = images
        item.attachments = attachments
        item.displayKind = displayKind
        items.append(item)
        prompts[item.id] = .sent
        promptSentAtStarts[item.id] = starts
        isRunning = true
        lastError = nil
        return item.id
    }

    /// Takes back a prompt bubble the gateway never took (a failed or rejected
    /// `session.redirect`); the spinner stops unless a turn runs.
    public mutating func withdrawPrompt(_ itemID: String) {
        guard prompts.removeValue(forKey: itemID) != nil else { return }
        promptSentAtStarts[itemID] = nil
        removeLiveItems { $0.id == itemID }
        if !turnActive, !prompts.values.contains(.sent) { isRunning = false }
    }

    /// Moves a prompt bubble to the end: a redirect the gateway queued as the next
    /// turn (`use-prompt-actions/index.ts:854-860`).
    public mutating func movePromptToEnd(_ itemID: String) {
        guard prompts[itemID] != nil, let index = items.indices.last(where: { $0 >= historyCount && items[$0].id == itemID })
        else { return }
        items.append(items.remove(at: index))
    }

    /// A local system line (slash-command output, notices). Never stored.
    public mutating func appendNote(_ text: String) {
        appendLocal(TranscriptItem(id: nextID(), role: .system, text: text))
    }

    /// Shows a `/btw` question or `/bg` task until its answer arrives. The answer can
    /// beat the RPC reply; then the row already exists and only gains its question.
    /// The row is not `isActive`: `sideQuestion.isPending` says it still waits.
    public mutating func beginSideQuestion(taskID: String, question: String, kind: SideQuestion.Kind = .btw) {
        let id = Self.sideQuestionItemID(taskID, kind: kind)
        if let index = items.lastIndex(where: { $0.id == id }) {
            if items[index].sideQuestion?.question == nil { items[index].sideQuestion?.question = question }
            return
        }
        var item = TranscriptItem(id: id, role: .system, text: "")
        item.sideQuestion = SideQuestion(taskID: taskID, question: question, kind: kind)
        appendLocal(item)
    }

    static func sideQuestionItemID(_ taskID: String, kind: SideQuestion.Kind = .btw) -> String {
        (kind == .btw ? "btw-" : "bg-") + taskID
    }

    /// `prompt.submit` answered, whatever its `status`: Hermes stored the prompt
    /// (`streaming`, `queued`: `methods_prompt.py:817-820`, `session_auto_continue.py:436-439`)
    /// or will before the session is quiet again (`steered`, `redirected`).
    /// `status` only decides how soon its bubble can go; no status hides it.
    /// One quiet re-read is enough only for `streaming` with the stored row's id.
    /// `streaming` without it waits for its turn (below). Anything else, including
    /// a missing status, waits for two quiet re-reads.
    ///
    /// `streaming` *without* `user_row_id` means no row was written at submit: the
    /// text was empty (an image-only prompt; `_write_submit_user_row` returns early,
    /// `tui_gateway/session_workdir.py:621`), compute-host isolation, or a failed write
    /// (`methods_prompt.py:798-820`). Its row is stored by its own turn, which can start
    /// well after any quiet re-read (the agent build waits for a deferred history,
    /// `server.py:1164`). So such a bubble leaves the quiet rules and becomes part of
    /// that turn: the turn running now if it started after the prompt was shown (its
    /// `message.start` beat the answer), else the next one to start. It then goes like
    /// the turn's other live items, with the first re-read requested after the turn
    /// finished (`finishedItems`). If no turn ever starts, it stays: no row holds it.
    public mutating func promptAnswered(itemID: String, status: String? = nil, userRowID: Int? = nil) {
        guard prompts[itemID] != nil else { return }
        if status == "streaming", userRowID == nil {
            prompts[itemID] = nil
            let sentAt = promptSentAtStarts.removeValue(forKey: itemID) ?? starts
            if turnActive, starts > sentAt {
                turnItemIDs.insert(itemID)
            } else {
                awaitingTurn.insert(itemID)
            }
            return
        }
        promptSentAtStarts[itemID] = nil
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
        if let itemID, prompts[itemID] != nil {
            prompts[itemID] = .failed
            promptSentAtStarts[itemID] = nil
        }
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
        clearSupersededIndicators(event.type)
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
            // A whole block from a non-streaming provider replaces what streamed,
            // unless the reply text already started (`use-message-stream/index.ts:526-537`).
            let index = activeAssistantIndex ?? append(.assistant, "", active: true)
            if !delta.text.isEmpty, items[index].text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                items[index].reasoning = delta.text
            }

        case .thinkingDelta(let delta):
            // Mostly spinner rewrites: only an explained provider wait is kept, and
            // any other frame clears it (`message-stream.ts:195-205`). Never reasoning.
            providerWait = Self.providerWaitText(delta.text)

        case .messageInterim(let interim):
            startTurn()
            // Commentary beside tool calls. Desktop seals the streaming bubble in
            // place with the authoritative interim text; the next deltas open a new
            // one (`use-message-stream/index.ts:614-719`).
            let text = interim.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty {
                if interim.alreadyStreamed == true, let index = activeAssistantIndex { items[index].isActive = false }
            } else if let index = activeAssistantIndex {
                items[index].text = text
                items[index].isActive = false
                items[index].isInterim = true
            } else if let index = liveAssistantSinceUser(withText: text) {
                items[index].isInterim = true  // a duplicate delivery of the seal
            } else {
                let index = append(.assistant, text)
                items[index].isInterim = true
            }

        case .toolGenerating(let generating):
            startTurn()
            sealActiveAssistant()
            generatingTool = generating.name

        case .toolStart(let start):
            startTurn()
            sealActiveAssistant()
            generatingTool = nil
            // Call ids repeat across rounds and turns (`deterministic_call_id`,
            // `agent/message_sanitization.py:492-495`): only a start of a call still
            // running reuses its row.
            let index: Int
            if let running = runningToolIndex(start.toolID) {
                index = running
                items[index].isActive = true
            } else {
                var item = TranscriptItem(id: Self.toolItemID(start.toolID), role: .tool, text: "", isActive: true)
                item.toolCallID = start.toolID
                appendLive(item)
                index = items.count - 1
            }
            var tool = items[index].tool ?? ToolActivity(toolID: start.toolID, name: start.name)
            tool.phase = .running
            tool.context = start.context ?? start.preview ?? tool.context
            if let args = start.args { tool.args = args }
            items[index].tool = tool
            items[index].toolName = start.name
            items[index].detail = tool.context

        case .toolComplete(let complete):
            startTurn()
            generatingTool = nil
            let index: Int
            if let running = runningToolIndex(complete.toolID) {
                index = running
            } else {
                // Started before this chat attached.
                sealActiveAssistant()
                var item = TranscriptItem(id: Self.toolItemID(complete.toolID), role: .tool, text: "")
                item.toolCallID = complete.toolID
                appendLive(item)
                index = items.count - 1
            }
            var tool = items[index].tool ?? ToolActivity(toolID: complete.toolID, name: complete.name)
            let error = complete.error.flatMap { $0.isEmpty ? nil : $0 }
            tool.phase = error == nil ? .complete : .failed
            tool.error = error
            if let args = complete.args { tool.args = args }
            tool.summary = complete.summary
            tool.output = complete.resultText ?? Self.text(of: complete.result) ?? tool.output
            tool.inlineDiff = complete.inlineDiff
            tool.durationSeconds = complete.durationS
            items[index].tool = tool
            items[index].isActive = false
            items[index].toolName = complete.name
            if let summary = complete.summary, !summary.isEmpty { items[index].detail = summary }

        case .messageComplete(let complete):
            finishTurn(complete)

        case .statusUpdate(let update):
            status = update.text.isEmpty ? nil : update.text

        case .btwComplete(let answer):
            completeSideAgent(answer, kind: .btw)

        case .backgroundComplete(let answer):
            completeSideAgent(answer, kind: .background)

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

        case .gatewayReady, .sessionTitle, .sessionInfo, .sessionsChanged, .sessionReclaimed, .notificationShow,
            .notificationClear, .unknown:
            break
        }
    }

    // MARK: - Helpers

    /// Fills in (or adds, when another client asked) a `/btw` or `/bg` answer row.
    private mutating func completeSideAgent(_ answer: SideAgentComplete, kind: SideQuestion.Kind) {
        let id = Self.sideQuestionItemID(answer.taskID, kind: kind)
        if let index = items.lastIndex(where: { $0.id == id }) {
            items[index].sideQuestion?.answer = answer.text
            if let question = answer.question { items[index].sideQuestion?.question = question }
            items[index].text = answer.text
        } else {
            var item = TranscriptItem(id: id, role: .system, text: answer.text)
            item.sideQuestion = SideQuestion(taskID: answer.taskID, question: answer.question, answer: answer.text,
                                             kind: kind)
            appendLocal(item)
        }
    }

    /// Desktop's `providerWaitText` (`apps/desktop/src/store/provider-wait.ts:43-53`):
    /// the core's explained wait / reconnect frames, else `nil`.
    static func providerWaitText(_ text: String) -> String? {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let pattern = #"^(?:⏳|⚠|↻|⚙)\s*(?:(?:still\s+)?waiting on|loading|processing prompt|no (?:output|response)|model returned|rate limited|provider (?:overloaded|temporarily unavailable))"#
        guard value.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil else { return nil }
        return value
    }

    /// Events after which the wait line and the drafting-tool label are stale
    /// (`PROVIDER_WAIT_SUPERSEDING_EVENT_TYPES` / `DRAFT_SUPERSEDING_EVENT_TYPES`,
    /// `gateway-event/index.ts:41-78`).
    private mutating func clearSupersededIndicators(_ type: String) {
        if Self.providerWaitSuperseding.contains(type) { providerWait = nil }
        if Self.draftSuperseding.contains(type) { generatingTool = nil }
    }

    private static let providerWaitSuperseding: Set<String> = [
        "error", "message.complete", "message.delta", "message.interim", "message.start", "reasoning.available",
        "reasoning.delta", "tool.complete", "tool.generating", "tool.start",
    ]
    private static let draftSuperseding: Set<String> = [
        "error", "message.complete", "message.delta", "message.start", "reasoning.delta", "thinking.delta",
        "tool.complete", "tool.start",
    ]

    /// A tool result as display text: strings as-is, other JSON serialised.
    static func text(of value: JSONValue?) -> String? {
        switch value {
        case nil, .null?: return nil
        case .string(let text)?: return text
        case let value?:
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            return (try? encoder.encode(value)).map { String(decoding: $0, as: UTF8.self) }
        }
    }

    /// The live assistant item of the current turn with `text`, looking back to the
    /// prompt that started it (a steer is part of the running turn, not a new one).
    private func liveAssistantSinceUser(withText text: String) -> Int? {
        for index in items.indices.reversed() where index >= historyCount {
            if items[index].role == .user, !items[index].isSteer { return nil }
            if items[index].role == .assistant, items[index].text == text { return index }
        }
        return nil
    }

    /// A user row: its `@image:` lines become images, its leading `@file:` lines
    /// attachments, the rest its caption.
    @discardableResult
    private mutating func appendUser(_ text: String, rowID: Int? = nil) -> Int {
        let (caption, paths) = ImageDirectives.split(text)
        let (body, refs) = AttachmentRefs.splitLeading(caption)
        let index = append(.user, body, rowID: rowID)
        items[index].images = TranscriptImage.stored(paths)
        items[index].attachments = refs.map(AttachmentRefs.displayName)
        return index
    }

    /// The turn is over here: no live item streams or runs on.
    private mutating func endLiveActivity() {
        for index in items.indices where index >= historyCount {
            items[index].isActive = false
            if items[index].tool?.phase == .running { items[index].tool?.phase = .complete }
        }
        generatingTool = nil
    }

    /// A turn's first event starts it (`message.start`, or any streamed event of a
    /// turn this chat saw no start of).
    private mutating func startTurn() {
        guard !turnActive else { return }
        turnActive = true
        starts += 1
        clock += 1
        quietOnce = []
        // The turn that stores a row-less `streaming` prompt (see `promptAnswered`).
        turnItemIDs.formUnion(awaitingTurn)
        awaitingTurn = []
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
        endLiveActivity()
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
        var unstored: String?
        // `error`: the whole partial reply of the failing call is unstored, including
        // segments a note, `/btw` or prompt sealed mid-reply; earlier calls ended at a
        // tool row and were stored with it.
        var unstoredSplit: Set<String> = []
        switch complete.status {
        case "error":
            unstored = streaming
            let anchor = streaming ?? items.last { turnItemIDs.contains($0.id) && $0.role == .assistant }?.id
            if let anchor, let start = items.lastIndex(where: { $0.id == anchor }) {
                for index in stride(from: start, through: historyCount, by: -1) where turnItemIDs.contains(items[index].id) {
                    if items[index].role == .tool { break }
                    if items[index].role == .assistant, items[index].rowID == nil { unstoredSplit.insert(items[index].id) }
                }
            }
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
        for id in turnItemIDs where id != unstored && !unstoredSplit.contains(id) { finishedItems[id] = completions }
        turnItemIDs = []
        turnActive = false
        if paging.rereadable { needsReread = true }
    }

    /// Whether the turn streaming now already shows `text`: a reply that streamed
    /// into a sealed segment, or one split into segments by tools or a row added
    /// mid-turn, whose segments joined end with it. Only its own live items count.
    private func turnShows(_ text: String) -> Bool {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let own = items.filter { turnItemIDs.contains($0.id) && $0.role == .assistant }
        if own.contains(where: { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) == text }) { return true }
        func normalized(_ value: String) -> String { value.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
        let target = normalized(text)
        guard !target.isEmpty else { return false }
        // Segments may split mid-word ("Shor" + "ter") or between words ("foo" + "bar").
        let texts = own.map(\.text)
        return normalized(texts.joined()).hasSuffix(target) || normalized(texts.joined(separator: " ")).hasSuffix(target)
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
