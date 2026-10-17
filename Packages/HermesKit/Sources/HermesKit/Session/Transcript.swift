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
    /// User rows: where those files are on the gateway (`@file:` values), in the same
    /// order; a relative path belongs to the session's folder.
    public var attachmentPaths: [String] = []
    /// Assistant rows: the files the reply delivers with `MEDIA:` tags (`MediaTags`),
    /// in order. `text` keeps the tags; views show `MediaTags.extract(text)`.
    public var deliveredFiles: [DeliveredFile] {
        guard role == .assistant, text.contains(MediaTags.prefix) else { return [] }
        return MediaTags.extract(text, isStreaming: isActive).files
    }
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
/// **Running and waiting** (`isRunning`, `waiting`; the state table is `docs/protocol.md` §5)
/// follow three server facts, never a chain of guesses:
/// - a turn is open here (`message.start` or any streamed event of the turn: text, reasoning,
///   `thinking.delta`, an interim or tool event; until `message.complete`);
/// - a `message.start` is still to come for a prompt sent here (`expectedStarts`): sent and
///   not answered yet, or answered `streaming` / `queued`. `steered` and `redirected` go
///   into the running turn and expect none. Any `message.start` settles them all;
/// - the server said a turn runs (a chat shown again) and none is open here yet.
///
/// `isRunning` is exactly "any of these" (`refreshRunning`). The waiting row is `isRunning`
/// with no visible output since the latest send or turn start. What ends each fact:
/// `message.complete`; for expectations, `message.start`, a failed submit, an in-turn answer,
/// an `error` before any turn starts, and the server reporting the session idle (which ends
/// `streaming` ones: Hermes marks the session running before it answers `streaming`).
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
    /// The slow agent-build notice for this session (`notification.show` with key
    /// `agent-build-slow`, `tui_gateway/server.py:989-996`), until it is cleared.
    public private(set) var buildNotice: String?
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
    /// The newest row of each finished turn's receipt (`persisted_turn`), by the completion
    /// it finished at; none for a turn that sent no receipt or ended without its
    /// `message.complete` (`closeTurnHere`).
    private var receiptRowByCompletion: [Int: Int] = [:]
    /// Live items an `error` end left as unstored (the failing round), with the rows that turn's
    /// receipt says it stored. Hermes may have stored them after all; a re-read that shows one
    /// of those rows with the item's text settles it (`settleByReceipt`).
    private var unstoredByReceipt: [String: Set<Int>] = [:]
    /// Prompts sent here, and how far they got.
    private var prompts: [String: PromptState] = [:]
    /// Answered prompts one quiet re-read has seen settled; the next one drops them.
    private var quietOnce: Set<String> = []
    /// `starts` when each prompt sent here was shown.
    private var promptSentAtStarts: [String: Int] = [:]
    /// When the latest prompt was sent here, while its reply is pending: the waiting
    /// row counts from it (see `waiting`). Cleared when no turn runs any more.
    private var lastSentAt: Date?
    /// The latest prompt sent here (`appendUserPrompt`), by its row's id. The chat
    /// scrolls to the bottom when it changes. A rebuild starts without one.
    public private(set) var lastPromptID: String?
    /// Prompts sent here for which a `message.start` is still to come (see the type's
    /// note on running). Any `message.start` empties it.
    private var expectedStarts: Set<String> = []
    /// Those of `expectedStarts` answered `queued`: their turn follows the running one, so
    /// the closing `running: false` between the two does not end them.
    private var queuedStarts: Set<String> = []
    /// Prompts unanswered when a Stop that cleared Hermes's queue was sent
    /// (`serverClearedQueue`): a `queued` answer for one expects no start.
    private var queueClearedBeforeAnswer: Set<String> = []
    /// The newest row id of a turn this chat saw end (`persisted_turn`, the receipt).
    private var newestReceiptRow = 0
    /// Rows up to this id belong to what came before the open turn: the newest row the
    /// history held, or a finished turn's receipt named, when the turn opened here.
    private var openTurnRowFloor = 0
    /// The server said a turn runs (`reconcileRunning(true)`, a chat shown again) and
    /// none is open here yet; the next `message.start` or `message.complete` takes over.
    private var serverBusy = false
    /// The stored row of the open turn's prompt, when known: its "Interrupted" mark goes
    /// after it.
    private var turnPromptRow: Int?
    /// Visible output (assistant text, a tool row) arrived since the latest send or
    /// the latest turn start: the waiting row is over (see `waiting`).
    private var outputSinceWait = false
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
        /// session is quiet again. `storedRow`: answered `streaming` with its row's id
        /// (`user_row_id`), so that row was written before the answer
        /// (`methods_prompt.py:815-819`); once a shown stored row has that id, the
        /// bubble goes (`dropPromptsShownByRows`).
        case answered(Int, storedRow: Int?)
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
                serverBusy = snapshot.running == true
            } else {
                let streaming = inflight.streaming ?? (snapshot.running == true)
                append(.assistant, assistant, active: streaming)
            }
        } else if snapshot.running == true {
            startTurn()
        }
        refreshRunning()
        outputSinceWait = items[historyCount...].contains(where: Self.isVisibleOutput)
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
        // An `error` end's receipt rows can be on this older page: newer rows from elsewhere
        // pushed them off the latest one.
        let storedAfterAll = settleByReceipt()
        if !storedAfterAll.isEmpty { removeLiveItems { storedAfterAll.contains($0.id) } }
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
    /// - Not running, also before any `message.start` arrived here: no turn runs and none
    ///   is coming, except for a submit still unanswered (its answer decides).
    public mutating func reconcileRunning(_ running: Bool) {
        if running {
            if !turnActive { serverBusy = true }
            refreshRunning()
            return
        }
        if turnActive { closeTurnHere() }
        serverBusy = false
        expectedStarts = expectedStarts.filter { prompts[$0] == .sent }
        queuedStarts.formIntersection(expectedStarts)
        refreshRunning()
    }

    /// The open turn ends here without its `message.complete`: it went to another socket,
    /// or Hermes sent none (`serverReportsIdle`). Its live items wait for the re-read,
    /// which holds what it stored (`finishedItems`); only empty reply bubbles go.
    private mutating func closeTurnHere() {
        endLiveActivity()
        removeLiveItems { $0.role == .assistant && $0.text.isEmpty && $0.reasoning.isEmpty && $0.rowID == nil }
        completions += 1
        clock += 1
        for id in turnItemIDs { finishedItems[id] = completions }
        turnItemIDs = []
        turnActive = false
        turnPromptRow = nil
        status = nil
    }

    /// `session.info` with `running: false` (`tui_gateway/server.py:2400`): every turn
    /// body ends with it (`prompt_turn.py:1196-1225`, `_emit_settled_session_info`),
    /// also one that sent no `message.complete`, such as a refused `@` context
    /// (`prompt_turn.py:715-718`: `message.start`, `error`, then this).
    ///
    /// - An open turn that has shown nothing (no text, tool row or reasoning) ends: Hermes
    ///   sent no `message.complete` for it. One that has shown something ends with its own
    ///   `message.complete`, so a stale report cannot hide what it streamed.
    /// - With no turn open, a `streaming` answer expects no start any more: Hermes marks
    ///   the session running before it answers `streaming` (`_lock_in_submit_turn`,
    ///   `methods_prompt.py:668`).
    ///   A `queued` one does (its turn follows this report, `prompt_turn.py:438-448`), and
    ///   so does a submit still unanswered.
    public mutating func serverReportsIdle() {
        serverBusy = false
        if turnActive, !outputSinceWait, !turnShowsReasoning { closeTurnHere() }
        if !turnActive {
            expectedStarts = expectedStarts.filter { prompts[$0] == .sent || queuedStarts.contains($0) }
            queuedStarts.formIntersection(expectedStarts)
        }
        refreshRunning()
    }

    /// `session.interrupt` succeeded: Hermes cleared its queue (`queued_prompt = None`,
    /// generation bumped, `session_lifecycle.py:708-712`) and sends no event for it, so no
    /// `message.start` comes for a prompt answered `queued`. Its row, stored when it was
    /// accepted (`_persist_queued_user_row`, `session_auto_continue.py:441`), still
    /// shows after the re-read; its bubble settles as before.
    ///
    /// - Parameter sentBeforeStop: prompts still unanswered when the Stop was sent
    ///   (`unansweredPrompts`). Hermes handled their submit before the Stop (both inline, in
    ///   arrival order, `rpc_dispatch.py:62`), so one answered `queued` after this was in the
    ///   queue the Stop cleared: its answer expects no start.
    public mutating func serverClearedQueue(sentBeforeStop: Set<String> = []) {
        expectedStarts.subtract(queuedStarts)
        queuedStarts = []
        queueClearedBeforeAnswer.formUnion(sentBeforeStop.filter { prompts[$0] == .sent })
        refreshRunning()
    }

    /// Prompts sent here whose submit is not answered yet.
    public var unansweredPrompts: Set<String> {
        Set(prompts.compactMap { $0.value == .sent ? $0.key : nil })
    }

    /// The open turn's live reply holds reasoning.
    private var turnShowsReasoning: Bool {
        items[historyCount...].contains { turnItemIDs.contains($0.id) && !$0.reasoning.isEmpty }
    }

    /// `isRunning` from the three facts (see the type's note). Everything that changes
    /// one of them calls this; nothing else sets `isRunning`.
    private mutating func refreshRunning() {
        isRunning = turnActive || !expectedStarts.isEmpty || serverBusy
        if !isRunning {
            lastSentAt = nil
            buildNotice = nil
            status = nil
        }
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

    /// `rows` up to the first one the open turn shows live: a tool row, or an assistant
    /// row, of a call the turn shows, or an assistant row with the text of one of its
    /// live segments (whitespace aside). Those rows and every newer one stay out of the
    /// history until the turn's own re-read: they are newer than something the turn
    /// streamed here, so the turn shows them live. Never cut:
    /// - a row up to `openTurnRowFloor`, or up to the open turn's own prompt row when known
    ///   (`turnPromptRow`: its `streaming` answer's `user_row_id`, before or after its
    ///   start). Such a row came before the turn: a call id or a phrase can repeat across
    ///   turns, `deterministic_call_id`, `agent/message_sanitization.py:505-508`;
    /// - a row the history shows already, or one before it.
    /// A finished turn whose rows may sit past the cut keeps its live items (see
    /// `installRereadPage`).
    private func rowsBeforeOpenTurn(_ rows: [StoredMessage]) -> [StoredMessage] {
        let floor = max(openTurnRowFloor, turnPromptRow ?? 0)
        let live = items[historyCount...].filter { turnItemIDs.contains($0.id) }
        let calls = Set(live.compactMap { $0.role == .tool ? $0.toolCallID : nil })
        let texts = Set(live.compactMap { $0.role == .assistant ? Self.normalizedText($0.text) : nil }.filter { !$0.isEmpty })
        guard !calls.isEmpty || !texts.isEmpty else { return rows }
        func shownLive(_ row: StoredMessage) -> Bool {
            guard let id = row.id, id > floor, !heldRowIDs.contains(id) else { return false }
            switch row.role {
            case "tool":
                return row.toolCallID.map(calls.contains) == true
            case "assistant":
                let rowCalls = (row.toolCalls?.arrayValue ?? []).compactMap { $0["id"]?.stringValue }
                return rowCalls.contains(where: calls.contains)
                    || texts.contains(Self.normalizedText(StoredMessageProjection.displayText(row)))
            default:
                return false
            }
        }
        guard var cut = rows.firstIndex(where: shownLive) else { return rows }
        if let held = rows.lastIndex(where: { $0.id.map(heldRowIDs.contains) == true }), held >= cut { cut = held + 1 }
        return Array(rows[..<cut])
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
    /// - A page that lands while a turn is open (a retry, the submit answer's read, a
    ///   chat shown again) also holds that turn's rows stored so far, which the turn shows
    ///   live: only the rows before the first of them go in (`rowsBeforeOpenTurn`). The
    ///   turn's own re-read, once it ends, brings the rest. A finished turn's live items
    ///   then go only if its rows went in: the open turn's own prompt row went in (every
    ///   earlier turn is below it), or its receipt's rows did. Any other (no receipt, ended
    ///   without `message.complete`) waits for a read that is not cut: shown twice for a
    ///   while rather than not at all.
    ///
    /// - Parameter reachesStart: the re-read reached the session's first row.
    public mutating func installRereadPage(_ rows: [StoredMessage], ticket: RereadTicket, reachesStart: Bool) {
        let page = turnActive ? rowsBeforeOpenTurn(rows) : rows
        let cut = page.count < rows.count
        let rows = page
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
        // Rows of a turn that finished before the open turn's prompt row are below it: a
        // prompt answered `streaming` was stored at submit, with no turn running
        // (`methods_prompt.py:668,815-821`).
        let installedUpTo = rows.compactMap(\.id).max() ?? 0
        let promptRowIn = turnPromptRow.map { $0 <= installedUpTo } == true
        let settled = Set(finishedItems.filter { _, completion in
            completion <= ticket.completions
                && (!cut || promptRowIn || receiptRowByCompletion[completion].map { $0 <= installedUpTo } == true)
        }.keys)
        finishedItems = finishedItems.filter { !settled.contains($0.key) }
        let unsettled = Set(finishedItems.values)
        receiptRowByCompletion = receiptRowByCompletion.filter { unsettled.contains($0.key) }
        let quiet = !turnActive && starts == ticket.starts && !prompts.values.contains(.sent)
        var eligible: Set<String> = [], storedAtSubmit: Set<String> = []
        for (id, state) in prompts where quiet {
            guard case .answered(let at, let storedRow) = state, at <= ticket.clock else { continue }
            eligible.insert(id)
            if storedRow != nil { storedAtSubmit.insert(id) }
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
        let storedAfterAll = settleByReceipt()
        removeLiveItems { settled.contains($0.id) || dropped.contains($0.id) || storedAfterAll.contains($0.id) }
        // A queued prompt the quiet re-reads settled had no turn of its own start in
        // all that time: Hermes merged or dropped it (a superseded queue entry sends
        // nothing, `prompt_turn.py:135-146`). It expects no start any more.
        let unstarted = dropped.intersection(queuedStarts)
        if !unstarted.isEmpty {
            expectedStarts.subtract(unstarted)
            queuedStarts.subtract(unstarted)
            refreshRunning()
        }
        // Quiet or not: a prompt whose stored row this read shows is settled by that row.
        dropPromptsShownByRows()
    }

    /// Drops prompt bubbles whose own stored row (`user_row_id`, see `PromptState`)
    /// the history now shows: the row is the prompt, as in Desktop, which ties its
    /// optimistic message to that id (`use-prompt-actions/submit.ts:969-986`). This
    /// needs no quiet session: the id proves this row is this prompt, whatever ran
    /// since. A prompt without that proof keeps its bubble (the quiet rules above).
    private mutating func dropPromptsShownByRows() {
        let shown = Set(items[..<historyCount].compactMap(\.rowID))
        let proven = Set(prompts.compactMap { id, state -> String? in
            guard case .answered(_, let row?) = state, shown.contains(row) else { return nil }
            return id
        })
        guard !proven.isEmpty else { return }
        prompts = prompts.filter { !proven.contains($0.key) }
        quietOnce.subtract(proven)
        removeLiveItems { proven.contains($0.id) }
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
        placeAnchoredLocalRows()
        guard paging.isLoaded, !turnActive else { return }
        while historyCount < items.count, localIDs.contains(items[historyCount].id) {
            let id = items[historyCount].id
            localAnchors[id] = items[..<historyCount].last { $0.rowID != nil }?.rowID
            historyCount += 1
        }
    }

    /// Live local rows whose anchor was fixed when they were made (a stopped turn's
    /// "Interrupted" mark, after that turn's prompt row) join the history after that row
    /// as soon as it shows, whatever is live meanwhile: the next turn cannot take them.
    private mutating func placeAnchoredLocalRows() {
        let shown = Set(items[..<historyCount].compactMap(\.rowID))
        let ready = items[historyCount...].filter { item in
            localIDs.contains(item.id) && localAnchors[item.id].map(shown.contains) == true
        }
        guard !ready.isEmpty else { return }
        let ids = Set(ready.map(\.id))
        let live = items[historyCount...].filter { !ids.contains($0.id) }
        items.removeSubrange(historyCount...)
        items.append(contentsOf: live)
        for item in ready { placeLocalRow(item) }
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
    ///   - attachments: names of the files sent with it; `attachmentPaths` their paths.
    ///   - displayKind: `steer` for guidance injected with `session.steer`.
    ///   - sentAt: when it was sent; the waiting row counts from it.
    @discardableResult
    public mutating func appendUserPrompt(_ text: String, images: [TranscriptImage] = [], attachments: [String] = [],
                                          attachmentPaths: [String] = [], displayKind: String? = nil,
                                          sentAt: Date = Date()) -> String {
        sealActiveAssistant()
        counter += 1
        var item = TranscriptItem(id: "local-\(counter)", role: .user, text: text)
        item.images = images
        item.attachments = attachments
        item.attachmentPaths = attachmentPaths
        item.displayKind = displayKind
        items.append(item)
        prompts[item.id] = .sent
        promptSentAtStarts[item.id] = starts
        expectedStarts.insert(item.id)
        lastSentAt = sentAt
        lastPromptID = item.id
        outputSinceWait = false
        lastError = nil
        refreshRunning()
        return item.id
    }

    /// Takes back a prompt bubble the gateway never took (a failed or rejected
    /// `session.redirect`); the spinner stops unless a turn runs.
    public mutating func withdrawPrompt(_ itemID: String) {
        guard prompts.removeValue(forKey: itemID) != nil else { return }
        promptSentAtStarts[itemID] = nil
        expectedStarts.remove(itemID)
        queuedStarts.remove(itemID)
        queueClearedBeforeAnswer.remove(itemID)
        removeLiveItems { $0.id == itemID }
        refreshRunning()
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
        defer { refreshRunning() }
        let queueCleared = queueClearedBeforeAnswer.remove(itemID) != nil
        switch status {
        case "steered", "redirected":
            // Into the running turn, as guidance or a correction (`interrupt_control.py:265-281`,
            // `turn_iteration_prep.py:370-375`): no `message.start` of its own. Answered after
            // that turn ended, nothing runs any more. A steer the turn left over is queued and
            // starts its own turn with `message.start` (`prompt_turn.py:441-447`).
            expectedStarts.remove(itemID)
            queuedStarts.remove(itemID)
        case "queued":
            // Queued before a Stop that cleared the queue (its answer came after the Stop's).
            if queueCleared {
                expectedStarts.remove(itemID)
            } else if expectedStarts.contains(itemID) {
                queuedStarts.insert(itemID)
            }
        case "streaming":
            // The open turn is this prompt's if it started after the send: its row anchors
            // the turn's "Interrupted" mark.
            if turnActive, !expectedStarts.contains(itemID), let userRowID { turnPromptRow = userRowID }
        default:
            break
        }
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
        prompts[itemID] = .answered(clock, storedRow: status == "streaming" ? userRowID : nil)
        // A re-read can land before the answer (a fast reply): its row may already show.
        dropPromptsShownByRows()
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
            expectedStarts.remove(itemID)
            queuedStarts.remove(itemID)
            queueClearedBeforeAnswer.remove(itemID)
        }
        refreshRunning()
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
            if activeAssistantIndex == nil { append(.assistant, "", active: true) }

        case .messageDelta(let delta):
            startTurn()
            let index = activeAssistantIndex ?? append(.assistant, "", active: true)
            items[index].text += delta.text
            if Self.isVisibleOutput(items[index]) { outputSinceWait = true }

        case .reasoningDelta(let delta):
            startTurn()
            let index = activeAssistantIndex ?? append(.assistant, "", active: true)
            items[index].reasoning += delta.text

        case .reasoningAvailable(let delta):
            startTurn()
            // Hermes's one emitter relays the round's model-call *content* once the response
            // ended (`_relay_thinking`, `agent/turn_response_intake.py:103-117,157-158`, with
            // show-reasoning on, `tool_progress.py:383-386`). If the round shows text, the frame
            // is that text: dropped, whichever bubble is open (Desktop drops it once reply text
            // arrived, `use-message-stream/index.ts:526-537`), so it never replaces reasoning
            // there. Otherwise (no text streamed) it is the block, as Desktop shows it.
            if roundShowsText { break }
            let index = activeAssistantIndex ?? append(.assistant, "", active: true)
            if !delta.text.isEmpty, items[index].text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                items[index].reasoning = delta.text
            }

        case .thinkingDelta(let delta):
            // A streamed event of the agent at work (`_STREAMING_EVENT_TYPES`, `ws.py:82`): only
            // the session's agent sends it, from its API-call loop (`agent_callbacks.py:123`,
            // `turn_iteration_prep.py:319-324`), so a turn runs. It reopens one an `error` at
            // its start closed, at the first API call (after any turn-start compression, which
            // sends none). Hermes sends none after the turn's `message.complete`; this relies on it.
            startTurn()
            // Mostly spinner rewrites: only an explained provider wait is kept, and
            // any other frame clears it (`message-stream.ts:195-205`). Never reasoning.
            providerWait = Self.providerWaitText(delta.text)

        case .messageInterim(let interim):
            startTurn()
            // The visible text of the round's model call, stripped (`stream_delivery.py:211`):
            // it seals that round's text (`sealRound`). The next deltas open a new bubble, as
            // in Desktop (`use-message-stream/index.ts:614-719`).
            let text = interim.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { outputSinceWait = true }
            if text.isEmpty {
                if interim.alreadyStreamed == true, let index = activeAssistantIndex { items[index].isActive = false }
            } else {
                sealRound(with: text)
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
            outputSinceWait = true

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
            outputSinceWait = true

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
            // Before any turn starts, an `error` is the end of what was sent: Hermes
            // cancelled or refused it and sends nothing more (Stop during the agent build,
            // `methods_prompt.py:625-635`; an ownership refusal, `prompt_turn.py:123-134`;
            // a queued prompt that failed to dispatch, `session_auto_continue.py:505-513`),
            // or a `message.complete` follows (a failed build, `methods_prompt.py:617-623`).
            // An open turn that has shown nothing ends too, by the rule `running: false` uses:
            // a follow-up refused after its `message.start` sends only this
            // (`_dispatch_followup_turn`, `prompt_turn.py:421-436`, then `:123-134`). A failed
            // pending model switch also sends it at turn start and its turn goes on
            // (`session_compression.py:197-211`, `model_switch.py:495`, `prompt_turn.py:685`):
            // that turn's next streamed event, at the latest the `thinking.delta` of its first
            // API call (after any turn-start compression), opens it again (the timer then counts
            // from there). A refused
            // follow-up never reaches the agent, so nothing reopens it.
            if turnActive, !outputSinceWait, !turnShowsReasoning { closeTurnHere() }
            // With no turn open, no start is coming, except for a submit still unanswered.
            if !turnActive {
                serverBusy = false
                expectedStarts = expectedStarts.filter { prompts[$0] == .sent }
                queuedStarts.formIntersection(expectedStarts)
                refreshRunning()
            }

        case .requestCancel(let cancel):
            removeRequest(id: cancel.id)

        case .approvalCancelled(let cancelled):
            // `request_ids` are approval request ids (params.request_id), not frame ids.
            let ids = Set(cancelled.requestIDs)
            pendingRequests.removeAll { request in
                if case .approval(let approval) = request.kind { return ids.contains(approval.requestID) }
                return false
            }

        case .notificationShow(let notice):
            if notice.key == Self.buildNoticeKey { buildNotice = notice.text }

        case .notificationClear(let clear):
            if clear.key == Self.buildNoticeKey { buildNotice = nil }

        case .gatewayReady, .sessionTitle, .sessionInfo, .sessionsChanged, .sessionReclaimed, .unknown:
            break
        }
    }

    /// `_AGENT_BUILD_SLOW_NOTICE_KEY` (`tui_gateway/server.py:945`).
    static let buildNoticeKey = "agent-build-slow"

    // MARK: - Waiting for the reply

    /// The waiting row: from a send until the reply shows text or a tool row.
    public struct Waiting: Sendable, Hashable {
        /// When the prompt was sent here; `nil` for a turn this chat did not start
        /// (it was running at open, or started elsewhere).
        public var since: Date?
        /// What the wait is about, when Hermes says (see `Transcript.waiting`).
        public var hint: String?

        public init(since: Date?, hint: String?) {
            self.since = since
            self.hint = hint
        }

        /// The label: the hint, else "Thinking…". Never a bare ellipsis.
        public var label: String { hint ?? "Thinking…" }

        /// Elapsed time as the row shows it: `4s`, `1m 05s`, `1h 02m`.
        public static func elapsedText(from start: Date, to now: Date) -> String {
            func twoDigits(_ value: Int) -> String { value < 10 ? "0\(value)" : "\(value)" }
            let seconds = max(0, Int(now.timeIntervalSince(start)))
            if seconds < 60 { return "\(seconds)s" }
            let minutes = seconds / 60
            if minutes < 60 { return "\(minutes)m \(twoDigits(seconds % 60))s" }
            return "\(minutes / 60)h \(twoDigits(minutes % 60))m"
        }
    }

    /// The reply is awaited and nothing of it shows yet: a turn runs (or a submit is
    /// pending) and no live item since the latest prompt is visible output, that is,
    /// assistant text or a tool row (reasoning alone keeps the row, as Desktop's
    /// `ResponseLoadingIndicator` stands in for an empty running reply,
    /// `components/assistant-ui/thread/status.tsx:243-268`). `nil` otherwise.
    ///
    /// The hint, most specific first: the turn's `status.update` (compaction, memory
    /// recall), an explained provider wait, the tool whose call is being drafted, then
    /// the slow agent-build notice.
    ///
    /// Only output since the latest send, or since the turn now running started,
    /// counts: an earlier turn's reply (one that failed stays live, unstored) does not
    /// end the wait for a new prompt.
    public var waiting: Waiting? {
        guard isRunning, !outputSinceWait else { return nil }
        return Waiting(since: lastSentAt, hint: waitingHint)
    }

    /// Output the waiting row gives way to: assistant text that is not blank, or a tool row.
    static func isVisibleOutput(_ item: TranscriptItem) -> Bool {
        item.role == .tool
            || (item.role == .assistant && !item.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    private var waitingHint: String? {
        if let status, !status.isEmpty { return status }
        if let providerWait { return providerWait }
        if let generatingTool { return "Drafting \(generatingTool)…" }
        return buildNotice
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
    /// Whitespace does not count (`_normalize_interim_visible_text`).
    private func liveAssistantSinceUser(withText text: String) -> Int? {
        let target = Self.normalizedText(text)
        for index in items.indices.reversed() where index >= historyCount {
            if items[index].role == .user, !items[index].isSteer { return nil }
            if items[index].role == .assistant, Self.normalizedText(items[index].text) == target { return index }
        }
        return nil
    }

    /// The open turn's current round: its live assistant items (not local rows) since the
    /// round began, oldest first. A round is one model call and what it showed. Hermes runs a
    /// call's tools only after storing its row (`agent/turn_tool_round.py:130-163`), so a turn
    /// tool row (`tool.start`, `tool.complete`) ends a round: every item before it is stored.
    /// `tool.generating` does not: it fires while the call still streams its tool calls
    /// (`chat_completion_helpers.py:2643,2924`), and that call's text can go on after it.
    /// With no tool rows in the turn (tool progress off: no `tool.start`, `tool_progress.py:291`;
    /// no `tool.generating`, `agent_callbacks.py:156`), an interim ends a round instead: Hermes
    /// sends it once the round's row is stored (`turn_tool_round.py:150-155`).
    /// See `docs/protocol.md` §5, "Rounds".
    private var currentRound: [Int] {
        let turn = items.indices.filter {
            $0 >= historyCount && turnItemIDs.contains(items[$0].id) && !localIDs.contains(items[$0].id)
        }
        let boundary = turn.last { items[$0].role == .tool }
            ?? turn.last { items[$0].role == .assistant && items[$0].isInterim }
        return turn.filter { $0 > (boundary ?? historyCount - 1) && items[$0].role == .assistant }
    }

    /// The current round already shows reply text.
    private var roundShowsText: Bool {
        currentRound.contains { !items[$0].text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    /// `message.interim`: the current round's call ended with `text` visible. Matched as Hermes
    /// matches it, whitespace-normalized (`_normalize_interim_visible_text`,
    /// `stream_delivery.py:103-104`): the first delta after a tool round starts with "\n\n"
    /// (`stream_delivery.py:305-310`), and `tool.generating` may have split the call's text into
    /// segments. Among the round's segments no interim sealed yet, most specific first:
    /// 1. one whose text is the interim's: it is sealed;
    /// 2. all of their text, joined, is the interim's or its start (a partial stream): the first
    ///    takes it in place, the others give up their text (one copy);
    /// 3. an interim of this turn already shows it: a repeated delivery stays one row;
    /// 4. none has text: the bubble streaming now, or the newest reasoning-only segment, takes it;
    /// 5. otherwise it is appended once. Their text is other text (Codex commentary that never
    ///    streamed, beside a streamed partial answer, `stream_delivery.py:188-195`).
    /// Either way the call ended: none of the round's segments streams on.
    private mutating func sealRound(with text: String) {
        let target = Self.normalizedText(text)
        let open = currentRound.filter { !items[$0].isInterim }
        let segments = open.filter { !Self.normalizedText(items[$0].text).isEmpty }
        let joined = Self.normalizedText(segments.map { items[$0].text }.joined(separator: " "))
        for index in open { items[index].isActive = false }
        func seal(_ index: Int) {
            items[index].text = text
            items[index].isActive = false
            items[index].isInterim = true
        }
        if let match = segments.last(where: { Self.normalizedText(items[$0].text) == target }) {
            seal(match)
        } else if let first = segments.first, target.hasPrefix(joined) {
            seal(first)
            let emptied = segments.dropFirst()
            for index in emptied { items[index].text = "" }
            let gone = Set(emptied.filter { items[$0].reasoning.isEmpty }.map { items[$0].id })
            items.removeAll { gone.contains($0.id) }
            turnItemIDs.subtract(gone)
        } else if let index = liveAssistantSinceUser(withText: text), items[index].isInterim {
            items[index].text = text
        } else if segments.isEmpty, let index = activeAssistantIndex ?? open.last(where: { !items[$0].reasoning.isEmpty }) {
            seal(index)
        } else {
            seal(append(.assistant, text))
        }
    }

    /// Text with no whitespace at all, for the receipt match (`settleByReceipt`).
    static func squeezed(_ text: String) -> String {
        String(text.filter { !$0.isWhitespace })
    }

    /// Text with every run of whitespace one space, trimmed, as Hermes compares interim
    /// text (`_normalize_interim_visible_text`, `stream_delivery.py:103-104`).
    static func normalizedText(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// A user row: recalled memory is dropped, its `@image:` lines and image hints
    /// become images, its leading `@file:` lines attachments, the rest its caption.
    @discardableResult
    private mutating func appendUser(_ text: String, rowID: Int? = nil) -> Int {
        let (typed, hinted) = InjectedContext.userTurn(text)
        let (caption, directives) = ImageDirectives.split(typed)
        let (body, refs) = AttachmentRefs.splitLeading(caption)
        let index = append(.user, body, rowID: rowID)
        items[index].images = TranscriptImage.stored(directives + hinted)
        items[index].attachments = refs.map(AttachmentRefs.displayName)
        items[index].attachmentPaths = refs
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
        openTurnRowFloor = max(heldRowIDs.max() ?? 0, newestReceiptRow)
        starts += 1
        clock += 1
        quietOnce = []
        // This is the start the expected prompts waited for (or one before theirs, which
        // ends the same way): its prompt's stored row, when known, anchors its mark.
        turnPromptRow = expectedStarts.compactMap { id -> Int? in
            if case .answered(_, let row?) = prompts[id] { return row }
            return nil
        }.max()
        expectedStarts = []
        queuedStarts = []
        serverBusy = false
        outputSinceWait = false
        refreshRunning()
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
        let receipt = (complete.persistedRowIDs ?? []) + [complete.persistedUserRowID].compactMap { $0 }
        newestReceiptRow = max(newestReceiptRow, receipt.max() ?? 0)
        let finalText = complete.textValue
        // The segment that was still streaming when the turn ended.
        var streaming = activeAssistantIndex.map { items[$0].id }
        // A reply stopped before it showed any text: the "Interrupted" mark, with whatever
        // reasoning streamed. Hermes stores no assistant row for an empty partial
        // (`agent/turn_api_call.py:204-210`), so it is a local row: it stays across re-reads,
        // right after the turn's last committed row (`persisted_turn.row_ids`, so below the
        // turn's own tool rows, `prompt_turn.py:897-903`). Without a receipt, after the
        // turn's prompt row (its answered `user_row_id`).
        var stoppedMark: String?
        if let index = activeAssistantIndex {
            if items[index].text.isEmpty, !finalText.isEmpty, !turnShows(finalText) { items[index].text = finalText }
            if items[index].reasoning.isEmpty, let reasoning = complete.reasoning { items[index].reasoning = reasoning }
            items[index].outcome = complete.status
            if complete.status == "interrupted", items[index].text.isEmpty {
                stoppedMark = items[index].id
            }
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
        if let stoppedMark {
            turnItemIDs.remove(stoppedMark)
            localIDs.insert(stoppedMark)
            if let anchor = complete.persistedRowIDs?.max() ?? complete.persistedUserRowID ?? turnPromptRow {
                localAnchors[stoppedMark] = anchor
            }
        }
        removeLiveItems {
            $0.role == .assistant && $0.text.isEmpty && $0.reasoning.isEmpty && $0.rowID == nil && $0.id != stoppedMark
        }
        if complete.status == "error" { lastError = complete.error ?? "The turn failed." }
        status = nil

        // The turn's rows are stored before `message.complete` (`prompt_turn.py:1153-1182`).
        // The segment still streaming when the turn ended may not be:
        // - `error`: the failing round's items (`currentRound`) may be unstored; the turn's
        //   receipt says which were stored after all (`settleByReceipt`). Retry exhaustion stores
        //   the message list (`agent/turn_recovery.py:1241`), a streamed partial merged into one
        //   row (`settle_delivered_partial`, `:830-847`).
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
        if let row = receipt.max() { receiptRowByCompletion[completions] = row }
        var unstored: String?
        // `error`: the failing call's items, the current round (`currentRound`), are unstored,
        // including segments a note, `/btw` or prompt sealed mid-reply, and Codex commentary
        // it delivered mid-stream. Every earlier round was stored before its tools ran.
        var unstoredSplit: Set<String> = []
        switch complete.status {
        case "error":
            unstored = streaming
            for index in currentRound where items[index].rowID == nil { unstoredSplit.insert(items[index].id) }
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
        // The round model says what the failing call may not have stored; the receipt says what
        // Hermes did store, for every status (`prompt_turn.py:874-941`), also on an `error` end
        // (the persist on retry exhaustion, `agent/turn_recovery.py:820-826,1241`).
        if complete.status == "error", let rows = complete.persistedRowIDs, !rows.isEmpty {
            for id in unstoredSplit { unstoredByReceipt[id] = Set(rows) }
        }
        turnItemIDs = []
        turnActive = false
        turnPromptRow = nil
        // A prompt sent while this turn ran and not answered yet, or answered `queued`,
        // still expects its own start: its waiting row and send time stay.
        refreshRunning()
        if paging.rereadable { needsReread = true }
    }

    /// Whether the turn streaming now already shows `text`: a reply that streamed
    /// into a sealed segment, or one split into segments by tools or a row added
    /// mid-turn, whose segments joined end with it. Only its own live items count.
    private func turnShows(_ text: String) -> Bool {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let own = items.filter { turnItemIDs.contains($0.id) && $0.role == .assistant }
        if own.contains(where: { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) == text }) { return true }
        let target = Self.normalizedText(text)
        guard !target.isEmpty else { return false }
        // Segments may split mid-word ("Shor" + "ter") or between words ("foo" + "bar").
        let texts = own.map(\.text)
        return Self.normalizedText(texts.joined()).hasSuffix(target)
            || Self.normalizedText(texts.joined(separator: " ")).hasSuffix(target)
    }

    /// The items an `error` end left unstored that the history now shows stored: an assistant
    /// row of that turn's receipt with the item's text, all whitespace aside (`squeezed`): a reply
    /// cut off twice is stored joined with a "\n" at the seam the screen never had
    /// (`_join_truncated_parts`, `agent/conversation_loop.py:301-302`). Hermes stores such a
    /// partial on some error ends: a stream that died after visible text, merged into one row
    /// when the retries ran out (`settle_delivered_partial`, `agent/turn_recovery.py:830-847`,
    /// `agent/turn_truncation.py:89-90`), or a stall-guard or degenerate-final reply sent as an
    /// interim before it was stored (`agent/turn_final_response.py:231-237`). Only the turn's own
    /// rows are compared. An item is let go once every receipt row was read without a match:
    /// Hermes did not store it, and it stays.
    private mutating func settleByReceipt() -> Set<String> {
        // Called after a re-read (`installRereadPage`) and an older page (`prependOlderPage`):
        // the receipt's rows can sit on either.
        guard !unstoredByReceipt.isEmpty else { return [] }
        let stored = items[..<historyCount].filter { $0.role == .assistant }
        var settled: Set<String> = []
        for (id, receipt) in unstoredByReceipt {
            guard let item = items[historyCount...].first(where: { $0.id == id }) else {
                unstoredByReceipt[id] = nil  // gone (a rebuild, or settled otherwise)
                continue
            }
            let text = Self.squeezed(item.text)
            if !text.isEmpty, stored.contains(where: { $0.rowID.map(receipt.contains) == true && Self.squeezed($0.text) == text }) {
                settled.insert(id)
                unstoredByReceipt[id] = nil
            } else if receipt.isSubset(of: heldRowIDs) {
                unstoredByReceipt[id] = nil
            }
        }
        return settled
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
