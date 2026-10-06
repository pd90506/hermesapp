import Foundation
import HermesProtocol
import Synchronization
import Testing

@testable import HermesKit

// The scenarios of the "stored rows are the source of truth" design (docs/protocol.md §4.1),
// through a scripted gateway and stored transcript. Every test checks `expectWellFormed`
// (unique ids, stored rows in order, nothing active once no turn runs), that nothing the
// user should see is missing at each step, and, once settled, that every segment shows
// exactly once and only stored rows remain.

private func user(_ id: Int, _ text: String, kind: String? = nil) -> StoredMessage {
    var row = StoredMessage(id: id, role: "user", content: .string(text))
    row.displayKind = kind
    return row
}

/// An assistant row; with `call`, a tool-call round, stored before the tool runs
/// (`agent/turn_tool_round.py:127-130`).
private func assistant(_ id: Int, _ text: String, call: String? = nil) -> StoredMessage {
    var row = StoredMessage(id: id, role: "assistant", content: .string(text))
    if let call {
        row.toolCalls = [["id": .string(call), "type": "function",
                          "function": ["name": "terminal", "arguments": #"{"command":"ls"}"#]]]
    }
    return row
}

private func tool(_ id: Int, call: String) -> StoredMessage {
    var row = StoredMessage(id: id, role: "tool", content: "output")
    row.toolCallID = call
    row.toolName = "terminal"
    return row
}

private func plain(_ range: ClosedRange<Int>) -> [StoredMessage] { range.map { storedRow(id: $0) } }

private func occurrences(_ transcript: Transcript, _ segment: String) -> Int {
    transcript.items.reduce(0) { $0 + $1.text.components(separatedBy: segment).count - 1 }
}

private func tools(_ transcript: Transcript) -> [TranscriptItem] { transcript.items.filter { $0.role == .tool } }

/// `message.complete` with its receipt (`prompt_turn.py:873-922`); `status` as Hermes sends it.
private func complete(_ text: String, rows: [Int], status: String = "complete") -> JSONValue {
    var payload = completePayload(text, rows: rows)
    payload = .object((payload.objectValue ?? [:]).merging(["status": .string(status)]) { $1 })
    return payload
}

/// The first rows of a chat opened while `查一下` runs, its first tool round stored.
private let runningRows = plain(1...289) + [
    user(290, "查一下"), assistant(291, "我先看一下文件", call: "call-A"), tool(292, call: "call-A"),
]

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct TranscriptScenarioTests {
    /// A chat opened while a turn runs (`inflight`, or `nil` for one with no `inflight`).
    private func open(_ rows: [StoredMessage], inflight: JSONValue?, running: Bool = true,
                      extra: [FakeTransport] = [], epoch: String = "E1")
        async throws -> (ChatSession, FakeTransport, PagedServer, GatewayConnection)
    {
        let server = PagedServer(store: FakeMessageStore(rows: rows))
        if running {
            server.runningTurn.withLock { $0 = inflight ?? ["streaming": true] }
        }
        let (connection, transport) = try await server.connect(log: FrameLog(), epoch: epoch, extra: extra)
        let session = try await connection.open(SessionSummary(id: "stored-1"))
        await settle(session)
        return (session, transport, server, connection)
    }

    private func send(_ transport: FakeTransport, _ session: ChatSession, _ type: String, _ seq: Int,
                      _ payload: JSONValue? = nil) {
        transport.sendEvent(type, sessionID: session.sessionID, seq: seq, payload: payload)
    }

    /// The turn is over and every re-read it set off has landed.
    private func settled(_ session: ChatSession) -> Bool {
        !session.transcript.isRunning && session.rereadTask == nil && !session.transcript.needsReread
    }

    /// Only stored rows are left, each shown once.
    private func expectAllStored(_ transcript: Transcript, sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(transcript.historyCount == transcript.items.count, "live items left: \(transcript.items[transcript.historyCount...].map(\.text))",
                sourceLocation: sourceLocation)
        expectWellFormed(transcript, sourceLocation: sourceLocation)
    }

    // MARK: Turns running at open

    /// With `inflight.user`: the stored part shows twice while the turn streams (the
    /// accepted cost), never less; once the turn's re-read lands, once.
    @Test func aTurnRunningAtOpenShowsTwiceWhileStreamingThenOnce() async throws {
        let (session, transport, server, connection) = try await open(
            runningRows, inflight: ["assistant": "我先看一下文件", "streaming": true, "user": "查一下"])
        #expect(occurrences(session.transcript, "查一下") == 2)
        #expect(occurrences(session.transcript, "我先看一下文件") == 2)
        expectWellFormed(session.transcript)

        send(transport, session, "message.delta", 1, ["text": "结果显示4"])
        #expect(await eventually { occurrences(session.transcript, "结果显示4") == 1 })
        server.store.append([assistant(293, "结果显示4")])
        send(transport, session, "message.complete", 2, complete("结果显示4", rows: [290, 291, 292, 293]))
        #expect(await eventually { settled(session) && occurrences(session.transcript, "查一下") == 1 })
        for text in ["查一下", "我先看一下文件", "结果显示4"] { #expect(occurrences(session.transcript, text) == 1, "\(text)") }
        #expect(tools(session.transcript).count == 1)
        expectAllStored(session.transcript)
        withExtendedLifetime(connection) {}
    }

    /// Without `inflight` (an auto-continue, `running` only): the same.
    @Test func aTurnRunningAtOpenWithoutInflightSettlesOnce() async throws {
        let rows = plain(1...289) + [user(290, "[System note: Your previous turn was interrupted mid-run]", kind: "auto_continue"),
                                     assistant(291, "继续：我先看一下文件", call: "call-A"), tool(292, call: "call-A")]
        let (session, transport, server, connection) = try await open(rows, inflight: nil)
        #expect(session.transcript.isRunning)
        send(transport, session, "message.delta", 1, ["text": "结果显示4"])
        server.store.append([assistant(293, "结果显示4")])
        send(transport, session, "message.complete", 2, complete("结果显示4", rows: [290, 291, 292, 293]))
        #expect(await eventually { settled(session) && occurrences(session.transcript, "结果显示4") == 1 })
        #expect(occurrences(session.transcript, "继续：我先看一下文件") == 1)
        expectAllStored(session.transcript)
        withExtendedLifetime(connection) {}
    }

    /// Longer than a page: the prompt is in an older page. The re-read reaches back to
    /// the loaded rows and replaces the turn's live copy.
    @Test func aTurnRunningAtOpenLongerThanAPageSettlesOnce() async throws {
        var rows = plain(1...99) + [user(100, "长任务")]
        var streamed = ""
        for step in 0..<120 {
            rows += [assistant(101 + 2 * step, "步骤\(step)；", call: "c\(step)"), tool(102 + 2 * step, call: "c\(step)")]
            streamed += "步骤\(step)；"
        }
        let (session, transport, server, connection) = try await open(
            rows, inflight: ["assistant": .string(streamed), "streaming": true, "user": "长任务"])
        #expect(occurrences(session.transcript, "步骤119；") == 2)
        server.store.append([assistant(341, "全部完成")])
        send(transport, session, "message.delta", 1, ["text": "全部完成"])
        send(transport, session, "message.complete", 2, complete("全部完成", rows: Array(100...341)))
        #expect(await eventually { settled(session) && occurrences(session.transcript, "步骤119；") == 1 })
        for step in 60..<120 { #expect(occurrences(session.transcript, "步骤\(step)；") == 1, "步骤\(step)") }
        #expect(occurrences(session.transcript, "全部完成") == 1)
        expectAllStored(session.transcript)
        withExtendedLifetime(connection) {}
    }

    /// More rows stored meanwhile than a re-read reads (4 pages): the re-read becomes the
    /// history, and older rows load again by scrolling, with no gap.
    @Test func moreNewRowsThanTheRereadCapReplaceTheHistory() async throws {
        let (session, transport, server, connection) = try await open(
            plain(1...300), inflight: ["assistant": "", "streaming": true, "user": "user 299"])
        server.store.append((301...900).map { storedRow(id: $0) })
        send(transport, session, "message.complete", 1, complete("assistant 900", rows: [299, 900]))
        #expect(await eventually { settled(session) && session.transcript.items.last?.rowID == 900 })
        #expect(session.transcript.items.compactMap(\.rowID) == Array(421...900))
        #expect(session.transcript.paging.hasOlder)
        await session.loadOlderMessages()
        // Offset 480 - 10 (the overlap margin): rows 311-430, cut at the first held one.
        #expect(session.transcript.items.compactMap(\.rowID) == Array(311...900))
        expectAllStored(session.transcript)
        withExtendedLifetime(connection) {}
    }

    // MARK: Turns after the page

    /// A bot DM repeats the previous reply: both stay, before and after the re-read.
    @Test func aTurnAfterThePageRepeatingTheLastReplyKeepsBoth() async throws {
        let (session, transport, server, connection) = try await open(
            plain(1...288) + [user(289, "ping"), assistant(290, "pong")], inflight: nil, running: false)
        send(transport, session, "message.start", 1)
        send(transport, session, "message.delta", 2, ["text": "pong"])
        #expect(await eventually { occurrences(session.transcript, "pong") == 2 })
        server.store.append([user(291, "[来自 小助手] ping"), assistant(292, "pong")])
        send(transport, session, "message.complete", 3, complete("pong", rows: [291, 292]))
        #expect(await eventually { settled(session) && occurrences(session.transcript, "[来自 小助手] ping") == 1 })
        #expect(occurrences(session.transcript, "pong") == 2)
        expectAllStored(session.transcript)
        withExtendedLifetime(connection) {}
    }

    /// The user's own turn: the prompt shows at once, and is shown from its stored row afterwards.
    @Test func anOwnTurnEndsShownFromStoredRows() async throws {
        let (session, transport, server, connection) = try await open(plain(1...300), inflight: nil, running: false)
        try await session.send("你好")
        #expect(occurrences(session.transcript, "你好") == 1)
        send(transport, session, "message.start", 1)
        send(transport, session, "message.delta", 2, ["text": "你好！有什么可以帮你？"])
        server.store.append([assistant(302, "你好！有什么可以帮你？")])
        send(transport, session, "message.complete", 3, complete("你好！有什么可以帮你？", rows: [301, 302]))
        #expect(await eventually { settled(session) && session.transcript.items.last?.rowID == 302 })
        #expect(occurrences(session.transcript, "你好") == 2)  // the prompt and the reply's 你好！
        #expect(session.transcript.items.suffix(2).map(\.rowID) == [301, 302])
        expectAllStored(session.transcript)
        withExtendedLifetime(connection) {}
    }

    // MARK: Prompts sent during a reply

    /// Whatever `prompt.submit` answers, the prompt shows at once and is never missing,
    /// and once the session is quiet only stored rows remain. What Hermes stores per
    /// status: `session_auto_continue.py:398-450` (queue: accept-time row :436-439,
    /// drained turn re-places it :348-395; steer: a user row after the tool batch,
    /// `agent/prompt_builder.py:595-601`; redirect: partial text plus the correction,
    /// `agent/interrupt_control.py:261-305`).
    @Test(arguments: ["streaming", "steered", "redirected", "queued"])
    func aPromptSentDuringAReplyIsNeverLost(_ status: String) async throws {
        let (session, transport, server, connection) = try await open(
            runningRows, inflight: ["assistant": "我先看一下文件", "streaming": true, "user": "查一下"])
        let prompt = "顺便看看日志"
        var seq = 0
        func event(_ type: String, _ payload: JSONValue? = nil) { seq += 1; send(transport, session, type, seq, payload) }
        func visible() -> Bool { occurrences(session.transcript, prompt) >= 1 }

        if status == "streaming" {
            // The running turn ended just before the submit: the prompt starts its own turn.
            server.store.append([assistant(293, "结果显示4")])
            event("message.delta", ["text": "结果显示4"])
            event("message.complete", complete("结果显示4", rows: [290, 291, 292, 293]))
            #expect(await eventually { settled(session) })
            try await session.send(prompt)  // the gateway stores row 294 at submit
            #expect(visible())
            event("message.start")
            event("message.delta", ["text": "日志正常"])
            #expect(await eventually { occurrences(session.transcript, "日志正常") == 1 })
            #expect(visible())
            server.store.append([assistant(295, "日志正常")])
            event("message.complete", complete("日志正常", rows: [294, 295]))
        } else {
            server.busyStatus.withLock { $0 = status }
            try await session.send(prompt)
            #expect(visible())
            switch status {
            case "steered": server.store.append([user(293, prompt, kind: "steer"), assistant(294, "结果显示4")])
            case "redirected": server.store.append([assistant(293, "部分"), user(294, prompt), assistant(295, "结果显示4")])
            default: server.store.append([user(293, prompt), assistant(294, "结果显示4")])  // accept-time row
            }
            event("message.delta", ["text": "结果显示4"])
            #expect(visible())
            let last = status == "redirected" ? 295 : 294
            event("message.complete", complete("结果显示4", rows: [290, 291, 292, last]))
            #expect(await eventually { settled(session) })
            #expect(visible())
            if status == "queued" {
                // The queued prompt runs: its accept row is re-placed at the end.
                server.store.remove(id: 293)
                server.store.append([user(295, prompt), assistant(296, "日志正常")])
                event("message.start")
                #expect(visible())
                event("message.delta", ["text": "日志正常"])
                event("message.complete", complete("日志正常", rows: [295, 296]))
            }
        }
        #expect(await eventually { settled(session) && session.transcript.historyCount == session.transcript.items.count })
        let transcript = session.transcript
        for text in ["查一下", "我先看一下文件", "结果显示4", prompt] { #expect(occurrences(transcript, text) == 1, "\(text)") }
        #expect(tools(transcript).count == 1)
        expectAllStored(transcript)
        withExtendedLifetime(connection) {}
    }

    /// Two prompts queued during one reply: Hermes merges them into one accept-time row
    /// and one turn (`session_auto_continue.py:160-176,308-335`). Neither is ever missing;
    /// the end state is what Hermes stored.
    @Test func twoQueuedPromptsMergedIntoOneTurn() async throws {
        let (session, transport, server, connection) = try await open(
            runningRows, inflight: ["assistant": "我先看一下文件", "streaming": true, "user": "查一下"])
        server.busyStatus.withLock { $0 = "queued" }
        try await session.send("先看日志")
        server.store.append([user(293, "先看日志")])
        try await session.send("再看配置")
        server.store.replace(user(293, "先看日志\n再看配置"))
        #expect(occurrences(session.transcript, "先看日志") >= 1 && occurrences(session.transcript, "再看配置") >= 1)

        server.store.append([assistant(294, "结果显示4")])
        send(transport, session, "message.delta", 1, ["text": "结果显示4"])
        send(transport, session, "message.complete", 2, complete("结果显示4", rows: [290, 291, 292, 294]))
        #expect(await eventually { settled(session) })
        #expect(occurrences(session.transcript, "先看日志") >= 1 && occurrences(session.transcript, "再看配置") >= 1)

        server.store.remove(id: 293)
        server.store.append([user(295, "先看日志\n再看配置"), assistant(296, "都看完了")])
        send(transport, session, "message.start", 3)
        send(transport, session, "message.delta", 4, ["text": "都看完了"])
        send(transport, session, "message.complete", 5, complete("都看完了", rows: [295, 296]))
        #expect(await eventually { settled(session) && occurrences(session.transcript, "都看完了") == 1
            && session.transcript.historyCount == session.transcript.items.count })
        for text in ["先看日志", "再看配置", "结果显示4", "都看完了"] { #expect(occurrences(session.transcript, text) == 1, "\(text)") }
        expectAllStored(session.transcript)
        withExtendedLifetime(connection) {}
    }

    /// Stop with a queued prompt. Stop during the model call stores the partial reply
    /// (`agent/turn_api_call.py:206-214`: an assistant row with the partial text and
    /// `display_metadata.interrupted`, persisted before `message.complete`), so the re-read
    /// shows it once; the queued prompt still runs.
    @Test func stopWithAQueuedPrompt() async throws {
        let (session, transport, server, connection) = try await open(
            runningRows, inflight: ["assistant": "我先看一下文件", "streaming": true, "user": "查一下"])
        send(transport, session, "tool.start", 1, ["tool_id": "call-B", "name": "terminal", "context": "cat log"])
        send(transport, session, "tool.complete", 2, ["tool_id": "call-B", "name": "terminal", "summary": "ok"])
        send(transport, session, "message.delta", 3, ["text": "我正在整理"])
        server.busyStatus.withLock { $0 = "queued" }
        try await session.send("等会再说")
        server.store.append([assistant(293, "", call: "call-B"), tool(294, call: "call-B"), user(295, "等会再说")])
        // Stop: Hermes stores the partial reply, then ends the turn interrupted.
        server.store.append([assistant(296, "我正在整理")])
        send(transport, session, "message.complete", 4,
             complete("我正在整理", rows: [290, 291, 292, 293, 294, 296], status: "interrupted"))
        #expect(await eventually { settled(session) })
        #expect(occurrences(session.transcript, "我正在整理") == 1)
        #expect(occurrences(session.transcript, "等会再说") >= 1)
        expectWellFormed(session.transcript)

        server.store.remove(id: 295)
        server.store.append([user(297, "等会再说"), assistant(298, "好的")])
        send(transport, session, "message.start", 5)
        send(transport, session, "message.delta", 6, ["text": "好的"])
        send(transport, session, "message.complete", 7, complete("好的", rows: [297, 298]))
        #expect(await eventually { settled(session) && occurrences(session.transcript, "好的") == 1 })
        let transcript = session.transcript
        for text in ["查一下", "我先看一下文件", "我正在整理", "等会再说", "好的"] { #expect(occurrences(transcript, text) == 1, "\(text)") }
        #expect(tools(transcript).count == 2)
        expectAllStored(transcript)
        withExtendedLifetime(connection) {}
    }

    /// Stop, and Hermes retires the queued prompt instead of running it (its accept-time
    /// row is marked to be retired, `session_auto_continue.py:336-341`, `methods_session.py:693-710`):
    /// once the session is quiet, the screen is what Hermes stored. The bubble shows until then.
    @Test func aQueuedPromptHermesDropsEndsAsStored() async throws {
        let (session, transport, server, connection) = try await open(
            runningRows, inflight: ["assistant": "我先看一下文件", "streaming": true, "user": "查一下"])
        server.busyStatus.withLock { $0 = "queued" }
        try await session.send("算了")
        #expect(occurrences(session.transcript, "算了") == 1)
        server.store.append([user(293, "算了")])
        send(transport, session, "message.complete", 1, complete("", rows: [290, 291, 292], status: "interrupted"))
        #expect(await eventually { settled(session) })
        #expect(occurrences(session.transcript, "算了") >= 1)  // still stored
        // Hermes retires the never-run row; the next re-read shows it gone.
        server.store.remove(id: 293)
        server.store.append([user(294, "在吗"), assistant(295, "在的")])
        send(transport, session, "message.start", 2)
        send(transport, session, "message.delta", 3, ["text": "在的"])
        send(transport, session, "message.complete", 4, complete("在的", rows: [294, 295]))
        #expect(await eventually { settled(session) && session.transcript.items.last?.rowID == 295 })
        #expect(occurrences(session.transcript, "算了") == 0)
        for text in ["查一下", "我先看一下文件", "在吗", "在的"] { #expect(occurrences(session.transcript, text) == 1, "\(text)") }
        expectAllStored(session.transcript)
        withExtendedLifetime(connection) {}
    }

    // MARK: Tools

    /// `deterministic_call_id` repeats an id for the same tool and arguments in every
    /// round (`agent/message_sanitization.py:492-495`): each round keeps its own row.
    @Test func repeatedCallIDsKeepEveryRound() async throws {
        let rows = plain(1...287) + [user(288, "盯着日志"), assistant(289, "第一轮", call: "call_X"), tool(290, call: "call_X")]
        let (session, transport, server, connection) = try await open(
            rows, inflight: ["assistant": "第一轮", "streaming": true, "user": "盯着日志"])
        send(transport, session, "message.delta", 1, ["text": "第二轮"])
        send(transport, session, "tool.start", 2, ["tool_id": "call_X", "name": "terminal", "context": "tail log"])
        send(transport, session, "tool.complete", 3, ["tool_id": "call_X", "name": "terminal", "summary": "第二次"])
        #expect(await eventually { tools(session.transcript).map(\.detail) == ["ls", "第二次"] })
        expectWellFormed(session.transcript)
        server.store.append([assistant(291, "第二轮", call: "call_X"), tool(292, call: "call_X"), assistant(293, "完了")])
        send(transport, session, "message.delta", 4, ["text": "完了"])
        send(transport, session, "message.complete", 5, complete("完了", rows: Array(288...293)))
        #expect(await eventually { settled(session) && session.transcript.items.last?.rowID == 293 })
        #expect(tools(session.transcript).count == 2)
        expectAllStored(session.transcript)
        withExtendedLifetime(connection) {}
    }

    // MARK: Connection and read races

    /// A backend restart mid-turn: the cold restore rebuilds the transcript (§7 step 4),
    /// and the turn settles on the new socket.
    @Test func aColdRestoreMidTurnSettlesOnTheNewSocket() async throws {
        let second = FakeTransport()
        let server = PagedServer(store: FakeMessageStore(rows: runningRows))
        server.runningTurn.withLock { $0 = ["assistant": "我先看一下文件", "streaming": true, "user": "查一下"] }
        second.serve(epoch: "E2", log: FrameLog(), server.handle)
        let (connection, first) = try await server.connect(log: FrameLog(), extra: [second])
        let session = try await connection.open(SessionSummary(id: "stored-1"))
        await settle(session)
        send(first, session, "message.delta", 1, ["text": "结果"])
        let oldSID = session.sessionID

        first.serverDrops()
        #expect(await eventually { connection.state == .connected && session.sessionID != oldSID })
        await settle(session)
        #expect(occurrences(session.transcript, "查一下") >= 1 && occurrences(session.transcript, "我先看一下文件") >= 1)
        server.store.append([assistant(293, "结果显示4")])
        send(second, session, "message.delta", 1, ["text": "显示4"])
        send(second, session, "message.complete", 2, complete("结果显示4", rows: [290, 291, 292, 293]))
        #expect(await eventually { settled(session) && session.transcript.items.last?.rowID == 293 })
        for text in ["查一下", "我先看一下文件", "结果显示4"] { #expect(occurrences(session.transcript, text) == 1, "\(text)") }
        expectAllStored(session.transcript)
        withExtendedLifetime(connection) {}
    }

    /// A re-read and an older-page read in flight together land in either order: rows
    /// stay in order, contiguous, each once.
    @Test(arguments: [true, false])
    func aRereadRacingAnOlderPageRead(_ olderLandsFirst: Bool) async throws {
        let (session, transport, server, connection) = try await open(plain(1...300), inflight: nil, running: false)
        server.store.hold()
        let older = Task { await session.loadOlderMessages() }
        #expect(await eventually { server.store.heldCount == 1 })
        server.store.append([user(301, "在吗"), assistant(302, "在的")])
        send(transport, session, "message.start", 1)
        send(transport, session, "message.delta", 2, ["text": "在的"])
        send(transport, session, "message.complete", 3, complete("在的", rows: [301, 302]))
        #expect(await eventually { server.store.heldCount == 2 })
        if olderLandsFirst { server.store.releaseOldest() } else { server.store.releaseNewest() }
        #expect(await eventually { server.store.heldCount == 1 })
        server.store.release()
        await older.value
        #expect(await eventually { settled(session) && session.historyLoad == .idle })
        // Contiguous from wherever the older page started (it was served after rows
        // 301-302 were stored, so it overlaps more), up to the newest row.
        let ids = session.transcript.items.compactMap(\.rowID)
        #expect(ids == Array((ids.first ?? 0)...302) && (ids.first ?? .max) <= 180)
        expectAllStored(session.transcript)
        withExtendedLifetime(connection) {}
    }

    /// A turn that finishes while a re-read is in flight is settled by the next one.
    @Test func aTurnFinishingWhileARereadIsInFlight() async throws {
        let (session, transport, server, connection) = try await open(plain(1...300), inflight: nil, running: false)
        server.store.hold()
        server.store.append([user(301, "在吗"), assistant(302, "在的")])
        send(transport, session, "message.start", 1)
        send(transport, session, "message.delta", 2, ["text": "在的"])
        send(transport, session, "message.complete", 3, complete("在的", rows: [301, 302]))
        #expect(await eventually { server.store.heldCount == 1 })
        send(transport, session, "message.start", 4)
        send(transport, session, "message.delta", 5, ["text": "还在"])
        send(transport, session, "message.complete", 6, complete("还在", rows: [303, 304]))
        #expect(await eventually { !session.transcript.isRunning && occurrences(session.transcript, "还在") == 1 })
        server.store.append([user(303, "第二个问题"), assistant(304, "还在")])
        server.store.release()
        #expect(await eventually { settled(session) && session.transcript.items.last?.rowID == 304 })
        for text in ["在吗", "第二个问题", "在的", "还在"] { #expect(occurrences(session.transcript, text) == 1, "\(text)") }
        #expect(session.transcript.items.suffix(4).map(\.rowID) == [301, 302, 303, 304])
        expectAllStored(session.transcript)
        withExtendedLifetime(connection) {}
    }

    /// A failed re-read leaves the screen as it is (a duplicate at worst, never a gap);
    /// the next successful one settles everything.
    @Test func aFailedRereadIsSettledByTheNextOne() async throws {
        let (session, transport, server, connection) = try await open(
            runningRows, inflight: ["assistant": "我先看一下文件", "streaming": true, "user": "查一下"])
        server.store.setMode(.offline)
        send(transport, session, "message.delta", 1, ["text": "结果显示4"])
        send(transport, session, "message.complete", 2, complete("结果显示4", rows: [290, 291, 292, 293]))
        #expect(await eventually { settled(session) && server.store.queries.count == 3 })
        for text in ["查一下", "我先看一下文件", "结果显示4"] { #expect(occurrences(session.transcript, text) >= 1, "\(text)") }
        expectWellFormed(session.transcript)

        server.store.setMode(.paged)
        server.store.append([assistant(293, "结果显示4"), user(294, "好了吗"), assistant(295, "好了")])
        send(transport, session, "message.start", 3)
        send(transport, session, "message.delta", 4, ["text": "好了"])
        send(transport, session, "message.complete", 5, complete("好了", rows: [294, 295]))
        #expect(await eventually { settled(session) && session.transcript.items.last?.rowID == 295 })
        for text in ["查一下", "我先看一下文件", "结果显示4", "好了吗"] { #expect(occurrences(session.transcript, text) == 1, "\(text)") }
        expectAllStored(session.transcript)
        withExtendedLifetime(connection) {}
    }

    /// A failed turn's partial reply is kept only in memory by Hermes
    /// (`session_auto_continue.py:524-552`): it stays after the re-read, once.
    @Test func aFailedTurnKeepsItsUnstoredPartialReply() async throws {
        let (session, transport, server, connection) = try await open(plain(1...300), inflight: nil, running: false)
        try await session.send("帮我算一下")
        send(transport, session, "message.start", 1)
        send(transport, session, "message.delta", 2, ["text": "正在计算"])
        server.store.append([assistant(302, "This turn did not complete.")])
        send(transport, session, "message.complete", 3, complete("", rows: [301, 302], status: "error"))
        #expect(await eventually { settled(session) && session.transcript.lastError != nil
            && session.transcript.items.contains { $0.rowID == 302 } })
        #expect(occurrences(session.transcript, "正在计算") == 1)
        #expect(occurrences(session.transcript, "帮我算一下") == 1)
        expectWellFormed(session.transcript)
        withExtendedLifetime(connection) {}
    }
}

/// The prompt-bubble rule on its own, through the reducer.
@Suite struct PromptBubbleTests {
    private func event(_ type: String, _ payload: JSONValue? = nil) -> GatewayEvent {
        GatewayEvent(type: type, sessionID: "sid-1", payload: payload)
    }

    private func idle() throws -> Transcript {
        var transcript = Transcript(snapshot: try deferredAck(sid: "sid-1", key: "s1", count: 300)
            .decode(LiveSessionSnapshot.self))
        transcript.installLatestPage(plain(181...300), hasOlder: true)
        return transcript
    }

    /// A queued prompt: a follow-up turn's `message.start` that arrives after the first
    /// quiet re-read (its HTTP answer beat the socket) keeps the bubble: it takes two.
    @Test func aLateStartKeepsThePromptBubble() throws {
        var transcript = try idle()
        let prompt = transcript.appendUserPrompt("稍后再问")
        transcript.promptAnswered(itemID: prompt, status: "queued")
        #expect(transcript.needsReread)
        // The first re-read is quiet but missed the prompt's row.
        let first = transcript.beginReread()
        transcript.installRereadPage(plain(181...300), ticket: first, reachesStart: false)
        #expect(transcript.items.last?.text == "稍后再问")
        #expect(transcript.needsReread)
        // The follow-up's start arrives late; the next re-read is not quiet.
        transcript.apply(event("message.start"))
        let second = transcript.beginReread()
        transcript.installRereadPage(plain(181...300), ticket: second, reachesStart: false)
        #expect(transcript.items.contains { $0.text == "稍后再问" })
        expectWellFormed(transcript)
    }

    /// Two quiet re-reads in a row settle a queued prompt: the stored rows show what Hermes kept.
    @Test func twoQuietRereadsSettleThePrompt() throws {
        var transcript = try idle()
        let prompt = transcript.appendUserPrompt("稍后再问")
        transcript.promptAnswered(itemID: prompt, status: "queued")
        let rows = plain(181...300) + [StoredMessage(id: 301, role: "user", content: "稍后再问")]
        transcript.installRereadPage(rows, ticket: transcript.beginReread(), reachesStart: false)
        #expect(transcript.items.filter { $0.text == "稍后再问" }.count == 2)  // twice, never zero
        transcript.installRereadPage(rows, ticket: transcript.beginReread(), reachesStart: false)
        #expect(transcript.items.filter { $0.text == "稍后再问" }.count == 1)
        #expect(transcript.historyCount == transcript.items.count)
        #expect(!transcript.needsReread)
        expectWellFormed(transcript)
    }

    /// A failed submit keeps its bubble: only it holds the text.
    @Test func aFailedSubmitKeepsItsBubble() throws {
        var transcript = try idle()
        let prompt = transcript.appendUserPrompt("发不出去")
        transcript.submitFailed("offline", itemID: prompt)
        #expect(!transcript.isRunning)
        transcript.installRereadPage(plain(181...300), ticket: transcript.beginReread(), reachesStart: false)
        transcript.installRereadPage(plain(181...300), ticket: transcript.beginReread(), reachesStart: false)
        #expect(transcript.items.last?.text == "发不出去")
        expectWellFormed(transcript)
    }
}
