import Foundation
import HermesProtocol
import Synchronization
import Testing

@testable import HermesKit

// Regression tests for the fourth review of the paged transcript (fix round 5).
// They use only API the previous round already had, so they also build against it.
// The user writes mostly in Chinese: CJK text is a first-class case here.

private func event(_ type: String, _ payload: JSONValue? = nil) -> GatewayEvent {
    GatewayEvent(type: type, sessionID: "sid-1", payload: payload)
}

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

/// A turn running at open: the live-reuse ack (`server.py:3146-3186`, `methods_session.py:880-895`).
private func running(user: String, assistant: String, count: Int = 292) throws -> Transcript {
    Transcript(snapshot: try liveAck(sid: "sid-1", key: "s1", count: count,
                                     inflight: ["assistant": .string(assistant), "streaming": true,
                                                "user": .string(user)]).decode(LiveSessionSnapshot.self))
}

/// `message.complete` with a receipt naming `rows`, the last one the final reply.
private func complete(_ text: String, rows: [Int]) -> JSONValue { completePayload(text, rows: rows) }

// MARK: - Pure reducer

@Suite struct PagingRound5ReducerTests {
    /// S3: `deterministic_call_id` (`agent/message_sanitization.py:492-495`) repeats an id for
    /// the same tool and arguments in every round. The stored round-1 row must not
    /// swallow round 2's call that finishes live.
    @Test func aRepeatedCallIDInTheRunningTurnKeepsBothToolRows() throws {
        var transcript = try running(user: "查一下", assistant: "第一轮第二轮")
        // Round 2's identical call finishes after the page was read, before it landed.
        transcript.apply(event("tool.complete", ["tool_id": "call_X", "name": "terminal", "summary": "第二次"]))
        transcript.installLatestPage(plain(175...289) + [
            user(290, "查一下"), assistant(291, "第一轮", call: "call_X"), tool(292, call: "call_X"),
            assistant(293, "第二轮", call: "call_X"),
        ], hasOlder: true)
        #expect(tools(transcript).map(\.detail) == ["ls", "第二次"])
        transcript.apply(event("message.delta", ["text": "好了"]))
        transcript.apply(event("message.complete", complete("好了", rows: [290, 291, 292, 293, 294, 295])))
        #expect(tools(transcript).map(\.detail) == ["ls", "第二次"])
        expectWellFormed(transcript)
    }

    /// S3, the round-3 race with the same call id in both turns: another client's turn
    /// whose prompt missed the page re-runs the unanswered previous turn's command.
    @Test func aRepeatedCallIDDoesNotTieATurnToTheUnansweredOneBeforeIt() throws {
        var transcript = Transcript(snapshot: try deferredAck(sid: "sid-1", key: "s1", count: 292)
            .decode(LiveSessionSnapshot.self))
        transcript.apply(event("message.start"))
        transcript.apply(event("message.delta", ["text": "Let me check."]))
        transcript.apply(event("tool.start", ["tool_id": "call_X", "name": "terminal", "context": "tail log"]))
        transcript.apply(event("tool.complete", ["tool_id": "call_X", "name": "terminal", "summary": "new run"]))
        transcript.installLatestPage(plain(173...289) + [
            user(290, "q"), assistant(291, "Let me check.", call: "call_X"), tool(292, call: "call_X"),
        ], hasOlder: true)
        #expect(occurrences(transcript, "Let me check.") == 2)
        #expect(tools(transcript).map(\.detail) == ["ls", "new run"])
        expectWellFormed(transcript)
    }
}

// MARK: - Through the connection

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct PagingRound5ConnectionTests {
    /// A chat opened while `查一下` is running, its first tool round already stored.
    private func openWhileRunning(_ rows: [StoredMessage], inflight assistant: String, user prompt: String = "查一下")
        async throws -> (ChatSession, FakeTransport, PagedServer, GatewayConnection)
    {
        let server = PagedServer(store: FakeMessageStore(rows: rows))
        server.runningTurn.withLock {
            $0 = ["assistant": .string(assistant), "streaming": true, "user": .string(prompt)]
        }
        let (connection, transport) = try await server.connect(log: FrameLog())
        let session = try await connection.open(SessionSummary(id: "stored-1"))
        await session.historyTask?.value
        // The caller keeps the connection: a `ChatSession` only holds it weakly.
        return (session, transport, server, connection)
    }

    private static let runningRows = plain(1...289) + [
        user(290, "查一下"), assistant(291, "我先看一下文件", call: "call-A"), tool(292, call: "call-A"),
    ]

    /// The turn is over and its completion re-read has landed (or failed).
    private func settled(_ session: ChatSession) -> Bool {
        !session.transcript.isRunning && session.transcript.items.allSatisfy { !$0.isActive }
            && session.rereadTask == nil && !session.transcript.needsReread
    }

    /// M1: a prompt sent while a turn runs is steered into it or redirects it. The busy
    /// submit carries no `user_row_id` and starts no turn of its own, so the running
    /// turn's receipt must stay that turn's.
    @Test(arguments: ["steered", "redirected"])
    func aPromptSentWhileATurnRunsKeepsThatTurnsContent(_ status: String) async throws {
        let (session, transport, server, connection) = try await openWhileRunning(Self.runningRows, inflight: "我先看一下文件")
        server.busyStatus.withLock { $0 = status }
        try await session.send("顺便看看日志")

        server.store.append([user(293, "顺便看看日志", kind: status == "steered" ? "steer" : nil),
                             assistant(294, "结果显示4")])
        transport.sendEvent("message.delta", sessionID: session.sessionID, seq: 1, payload: ["text": "结果显示4"])
        transport.sendEvent("message.complete", sessionID: session.sessionID, seq: 2,
                            payload: complete("结果显示4", rows: [290, 291, 292, 293, 294]))

        #expect(await eventually {
            settled(session) && occurrences(session.transcript, "顺便看看日志") == 1
                && occurrences(session.transcript, "结果显示4") == 1
        })
        let transcript = session.transcript
        #expect(occurrences(transcript, "查一下") == 1)
        #expect(occurrences(transcript, "我先看一下文件") == 1)
        #expect(tools(transcript).count == 1)
        expectWellFormed(transcript)
        withExtendedLifetime(connection) {}
    }

    /// M1, queued: the prompt waits, then runs as its own turn once the running one ends.
    /// Hermes writes an accept-time row, deactivates it when the prompt runs, and
    /// stores the prompt again (`session_auto_continue.py:290-345,387-390,436-439`).
    @Test func aQueuedPromptRunsLaterAsItsOwnTurn() async throws {
        let (session, transport, server, connection) = try await openWhileRunning(Self.runningRows, inflight: "我先看一下文件")
        server.busyStatus.withLock { $0 = "queued" }
        try await session.send("顺便看看日志")
        server.store.append([user(293, "顺便看看日志"), assistant(294, "结果显示4")])
        transport.sendEvent("message.delta", sessionID: session.sessionID, seq: 1, payload: ["text": "结果显示4"])
        transport.sendEvent("message.complete", sessionID: session.sessionID, seq: 2,
                            payload: complete("结果显示4", rows: [290, 291, 292, 294]))
        #expect(await eventually { settled(session) && occurrences(session.transcript, "结果显示4") == 1 })
        #expect(occurrences(session.transcript, "查一下") == 1)
        #expect(occurrences(session.transcript, "我先看一下文件") == 1)

        // The queued prompt runs.
        server.store.remove(id: 293)
        server.store.append([user(295, "顺便看看日志"), assistant(296, "日志正常")])
        transport.sendEvent("message.start", sessionID: session.sessionID, seq: 3)
        transport.sendEvent("message.delta", sessionID: session.sessionID, seq: 4, payload: ["text": "日志正常"])
        transport.sendEvent("message.complete", sessionID: session.sessionID, seq: 5,
                            payload: complete("日志正常", rows: [295, 296]))

        #expect(await eventually {
            settled(session) && occurrences(session.transcript, "顺便看看日志") == 1
                && occurrences(session.transcript, "日志正常") == 1
        })
        let transcript = session.transcript
        let texts = transcript.items.map(\.text)
        #expect(occurrences(transcript, "查一下") == 1 && occurrences(transcript, "我先看一下文件") == 1)
        #expect(occurrences(transcript, "结果显示4") == 1)
        let order = ["结果显示4", "顺便看看日志", "日志正常"].compactMap { texts.firstIndex(of: $0) }
        #expect(order.count == 3 && order == order.sorted())
        expectWellFormed(transcript)
        withExtendedLifetime(connection) {}
    }

    /// S1: another client redirected the turn that was running at open. Hermes stores a
    /// placeholder with the partial text and the new prompt inside the same turn
    /// (`conversation_loop.py:320-353`).
    @Test func aRedirectInsideTheTurnRunningAtOpenEndsWithOneCopy() async throws {
        let rows = plain(1...289) + [
            user(290, "查一下"), assistant(291, "我先看一下", call: "call-A"), tool(292, call: "call-A"),
            assistant(293, "部分回答"), user(294, "改成X"), assistant(295, "好的改为X", call: "call-B"),
            tool(296, call: "call-B"),
        ]
        let (session, transport, server, connection) = try await openWhileRunning(rows, inflight: "我先看一下部分回答好的改为X")
        server.store.append([assistant(297, "完成")])
        transport.sendEvent("message.delta", sessionID: session.sessionID, seq: 1, payload: ["text": "完成"])
        transport.sendEvent("message.complete", sessionID: session.sessionID, seq: 2,
                            payload: complete("完成", rows: Array(290...297)))

        #expect(await eventually {
            settled(session) && occurrences(session.transcript, "部分回答") == 1
                && occurrences(session.transcript, "好的改为X") == 1
        })
        let transcript = session.transcript
        for segment in ["查一下", "我先看一下", "改成X", "完成"] { #expect(occurrences(transcript, segment) == 1, "\(segment)") }
        #expect(tools(transcript).count == 2)
        expectWellFormed(transcript)
        withExtendedLifetime(connection) {}
    }

    /// S2: the turn running at open is longer than a page: its prompt is in an older page.
    @Test func aTurnLongerThanAPageEndsWithOneCopy() async throws {
        var rows = plain(1...99) + [user(100, "长任务")]
        var streamed = ""
        for step in 0..<120 {
            rows += [assistant(101 + 2 * step, "步骤\(step)；", call: "call-\(step)"), tool(102 + 2 * step, call: "call-\(step)")]
            streamed += "步骤\(step)；"
        }
        let (session, transport, server, connection) = try await openWhileRunning(rows, inflight: streamed, user: "长任务")
        server.store.append([assistant(341, "全部完成")])
        transport.sendEvent("message.delta", sessionID: session.sessionID, seq: 1, payload: ["text": "全部完成"])
        transport.sendEvent("message.complete", sessionID: session.sessionID, seq: 2,
                            payload: complete("全部完成", rows: Array(100...341)))

        #expect(await eventually { settled(session) && occurrences(session.transcript, "步骤119；") == 1 })
        let transcript = session.transcript
        for step in 60..<120 { #expect(occurrences(transcript, "步骤\(step)；") == 1, "步骤\(step)") }
        #expect(occurrences(transcript, "全部完成") == 1)
        expectWellFormed(transcript)
        withExtendedLifetime(connection) {}
    }

    // MARK: Constraints on the completion re-read (guards)

    /// Older pages the user loaded stay; the re-read is one bounded read of the newest rows.
    @Test func theCompletionRereadKeepsLoadedOlderPages() async throws {
        let (session, transport, server, connection) = try await openWhileRunning(Self.runningRows, inflight: "我先看一下文件")
        await session.loadOlderMessages()
        let older = session.transcript.items.compactMap(\.rowID).prefix(5)
        let readsBefore = server.store.queries.count
        server.store.append([assistant(293, "结果显示4")])
        transport.sendEvent("message.delta", sessionID: session.sessionID, seq: 1, payload: ["text": "结果显示4"])
        transport.sendEvent("message.complete", sessionID: session.sessionID, seq: 2,
                            payload: complete("结果显示4", rows: [290, 291, 292, 293]))
        #expect(await eventually { settled(session) && occurrences(session.transcript, "结果显示4") == 1 })
        let transcript = session.transcript
        #expect(Array(transcript.items.compactMap(\.rowID).prefix(5)) == Array(older))
        #expect(server.store.queries.count == readsBefore + 1)
        #expect(server.store.queries.last?.offset == 0 && server.store.queries.last?.limit == 120)
        expectWellFormed(transcript)
        withExtendedLifetime(connection) {}
    }

    /// A re-read that fails changes nothing on screen: the turn running at open keeps
    /// its live copy beside the stored part (shown twice, nothing hidden), until the
    /// next successful re-read settles it. (Through round 5 the stored part was matched
    /// while the turn ran, so this test expected one copy.)
    @Test func aFailedCompletionRereadLeavesTheScreenAlone() async throws {
        let (session, transport, server, connection) = try await openWhileRunning(Self.runningRows, inflight: "我先看一下文件")
        server.store.setMode(.offline)
        transport.sendEvent("message.delta", sessionID: session.sessionID, seq: 1, payload: ["text": "结果显示4"])
        transport.sendEvent("message.complete", sessionID: session.sessionID, seq: 2,
                            payload: complete("结果显示4", rows: [290, 291, 292, 293]))
        #expect(await eventually { settled(session) && session.rereadTask == nil && server.store.queries.count == 3 })
        var transcript = session.transcript
        #expect(occurrences(transcript, "我先看一下文件") == 2)
        #expect(occurrences(transcript, "结果显示4") == 1)
        #expect(session.historyLoad == .idle)
        expectWellFormed(transcript)

        // The next turn's re-read succeeds and settles both turns.
        server.store.setMode(.paged)
        server.store.append([assistant(293, "结果显示4"), user(294, "在吗"), assistant(295, "在的")])
        transport.sendEvent("message.start", sessionID: session.sessionID, seq: 3)
        transport.sendEvent("message.delta", sessionID: session.sessionID, seq: 4, payload: ["text": "在的"])
        transport.sendEvent("message.complete", sessionID: session.sessionID, seq: 5,
                            payload: complete("在的", rows: [294, 295]))
        #expect(await eventually { occurrences(session.transcript, "我先看一下文件") == 1 })
        await settle(session)
        transcript = session.transcript
        for text in ["查一下", "我先看一下文件", "结果显示4", "在吗", "在的"] {
            #expect(occurrences(transcript, text) == 1, "\(text)")
        }
        expectWellFormed(transcript)
        withExtendedLifetime(connection) {}
    }

    /// A turn that started after the page (a bot DM) is settled by one bounded read of
    /// the newest rows, like every finished turn: the stored rows show it, including
    /// the prompt this chat never streamed. (Through round 5 such turns were not read
    /// again; the design is now that every finished turn is shown from stored rows.)
    @Test func aTurnAfterThePageIsSettledByOneBoundedRead() async throws {
        let server = PagedServer(store: FakeMessageStore(count: 300))
        let (connection, transport) = try await server.connect(log: FrameLog())
        let session = try await connection.openBotChat(profile: "coder")
        await settle(session)
        let reads = server.store.queries.count
        server.store.append([user(301, "在吗"), assistant(302, "在的")])
        transport.sendEvent("message.start", sessionID: session.sessionID, seq: 1)
        transport.sendEvent("message.delta", sessionID: session.sessionID, seq: 2, payload: ["text": "在的"])
        transport.sendEvent("message.complete", sessionID: session.sessionID, seq: 3,
                            payload: complete("在的", rows: [301, 302]))
        #expect(await eventually { settled(session) && occurrences(session.transcript, "在吗") == 1 })
        #expect(server.store.queries.count == reads + 1)
        #expect(server.store.queries.last?.offset == 0 && server.store.queries.last?.limit == 120)
        #expect(session.transcript.items.suffix(2).map(\.text) == ["在吗", "在的"])
        #expect(session.transcript.historyCount == session.transcript.items.count)
        expectWellFormed(session.transcript)
        withExtendedLifetime(connection) {}
    }

    /// S4: a row inside the loaded window leaves the display read (a queued prompt's
    /// accept row is deactivated when it runs), so the server's offsets shift back.
    @Test func aRowLeavingTheLoadedWindowDoesNotOpenAGap() async throws {
        let store = FakeMessageStore(count: 300)
        let server = PagedServer(store: store)
        let (connection, _) = try await server.connect(log: FrameLog())
        let session = try await connection.openBotChat(profile: "coder")
        await session.historyTask?.value
        store.remove(id: 250)
        await session.loadOlderMessages()
        let ids = session.transcript.items.compactMap(\.rowID)
        #expect(ids.contains(180))
        #expect(ids == Array((ids.first ?? 0)...300))
        expectWellFormed(session.transcript)
    }

    /// Nit: an older read cancelled because the header left the screen is no error.
    @Test func aCancelledOlderReadIsNotAnError() async throws {
        let store = FakeMessageStore(count: 300, honoursCancellation: true)
        let server = PagedServer(store: store)
        let (connection, _) = try await server.connect(log: FrameLog())
        let session = try await connection.openBotChat(profile: "coder")
        await session.historyTask?.value
        store.hold()
        let read = Task { await session.loadOlderMessages() }
        #expect(await eventually { store.heldCount == 1 })
        read.cancel()
        await read.value
        #expect(session.historyLoad == .idle)
        expectWellFormed(session.transcript)
    }
}
