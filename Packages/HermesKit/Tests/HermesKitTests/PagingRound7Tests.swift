import Foundation
import HermesProtocol
import Synchronization
import Testing

@testable import HermesKit

// Fixes after the review of the simplified design (round 7): interrupted turns are
// stored like complete ones, a `streaming` prompt settles after one quiet re-read, and
// stored items keep a stable id.

private func user(_ id: Int, _ text: String) -> StoredMessage {
    StoredMessage(id: id, role: "user", content: .string(text))
}

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

private func event(_ type: String, _ payload: JSONValue? = nil) -> GatewayEvent {
    GatewayEvent(type: type, sessionID: "sid-1", payload: payload)
}

/// `message.complete` as Hermes sends it after Stop: `text` is the partial reply.
private func interrupted(_ text: String, rows: [Int]) -> JSONValue {
    var payload = completePayload(text, rows: rows).objectValue ?? [:]
    payload["status"] = "interrupted"
    return .object(payload)
}

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct InterruptedTurnTests {
    private func open(_ rows: [StoredMessage], inflight: JSONValue? = nil)
        async throws -> (ChatSession, FakeTransport, PagedServer, GatewayConnection)
    {
        let server = PagedServer(store: FakeMessageStore(rows: rows))
        if let inflight { server.runningTurn.withLock { $0 = inflight } }
        let (connection, transport) = try await server.connect(log: FrameLog())
        let session = try await connection.open(SessionSummary(id: "stored-1"))
        await settle(session)
        return (session, transport, server, connection)
    }

    private func settled(_ session: ChatSession) -> Bool {
        !session.transcript.isRunning && session.rereadTask == nil && !session.transcript.needsReread
    }

    private func expectAllStored(_ transcript: Transcript, sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(transcript.historyCount == transcript.items.count,
                "live items left: \(transcript.items[transcript.historyCount...].map(\.text))", sourceLocation: sourceLocation)
        expectWellFormed(transcript, sourceLocation: sourceLocation)
    }

    /// The reviewer's case: Stop during the model call. Hermes stores the partial reply
    /// (`agent/turn_api_call.py:206-214`) before `message.complete`; it shows once.
    @Test func anInterruptedOwnTurnShowsItsPartialOnce() async throws {
        let (session, transport, server, connection) = try await open(plain(1...300))
        try await session.send("整理一下")  // stored as row 301 at submit
        transport.sendEvent("message.start", sessionID: session.sessionID, seq: 1)
        transport.sendEvent("message.delta", sessionID: session.sessionID, seq: 2, payload: ["text": "我正在整理"])
        #expect(await eventually { occurrences(session.transcript, "我正在整理") == 1 })
        server.store.append([assistant(302, "我正在整理")])
        transport.sendEvent("message.complete", sessionID: session.sessionID, seq: 3,
                            payload: interrupted("我正在整理", rows: [301, 302]))
        #expect(await eventually { settled(session) && session.transcript.items.last?.rowID == 302 })
        #expect(occurrences(session.transcript, "我正在整理") == 1)
        #expect(occurrences(session.transcript, "整理一下") == 1)
        expectAllStored(session.transcript)
        withExtendedLifetime(connection) {}
    }

    /// Stop during a tool round: the tool-call round was stored before the tool ran
    /// (`agent/turn_tool_round.py:127-130`), and the turn gets a closing row
    /// (`agent/message_sanitization.py:287-299`). Stopped while retrying the next model
    /// call, that row and `message.complete`'s text are the same `interrupt_text`
    /// (`agent/turn_recovery.py:1339-1358`, `agent/turn_api_error.py:410`).
    @Test func aStopDuringAToolLeavesNoDuplicate() async throws {
        let closing = "Operation interrupted: retrying API call after error (retry 1/3)."
        let (session, transport, server, connection) = try await open(plain(1...300))
        try await session.send("跑一下测试")
        transport.sendEvent("message.start", sessionID: session.sessionID, seq: 1)
        transport.sendEvent("message.delta", sessionID: session.sessionID, seq: 2, payload: ["text": "我先跑测试"])
        transport.sendEvent("tool.start", sessionID: session.sessionID, seq: 3,
                            payload: ["tool_id": "call-T", "name": "terminal", "context": "swift test"])
        #expect(await eventually { session.transcript.items.contains { $0.role == .tool && $0.isActive } })
        server.store.append([assistant(302, "我先跑测试", call: "call-T"), tool(303, call: "call-T"),
                             assistant(304, closing)])
        transport.sendEvent("tool.complete", sessionID: session.sessionID, seq: 4,
                            payload: ["tool_id": "call-T", "name": "terminal"])
        transport.sendEvent("message.complete", sessionID: session.sessionID, seq: 5,
                            payload: interrupted(closing, rows: [301, 302, 303, 304]))
        #expect(await eventually { settled(session) && session.transcript.items.last?.rowID == 304 })
        #expect(occurrences(session.transcript, "我先跑测试") == 1)
        #expect(occurrences(session.transcript, closing) == 1)
        #expect(session.transcript.items.filter { $0.role == .tool }.count == 1)
        expectAllStored(session.transcript)
        withExtendedLifetime(connection) {}
    }

    /// A turn that was running at open and is stopped settles the same way.
    @Test func anInterruptedTurnRunningAtOpenSettlesOnce() async throws {
        let rows = plain(1...289) + [user(290, "查一下"), assistant(291, "我先看一下文件", call: "call-A"),
                                     tool(292, call: "call-A")]
        let (session, transport, server, connection) = try await open(
            rows, inflight: ["assistant": "我先看一下文件", "streaming": true, "user": "查一下"])
        transport.sendEvent("message.delta", sessionID: session.sessionID, seq: 1, payload: ["text": "结果是"])
        #expect(await eventually { occurrences(session.transcript, "结果是") == 1 })
        server.store.append([assistant(293, "结果是")])
        transport.sendEvent("message.complete", sessionID: session.sessionID, seq: 2,
                            payload: interrupted("结果是", rows: [290, 291, 292, 293]))
        #expect(await eventually { settled(session) && session.transcript.items.last?.rowID == 293 })
        for text in ["查一下", "我先看一下文件", "结果是"] { #expect(occurrences(session.transcript, text) == 1, "\(text)") }
        expectAllStored(session.transcript)
        withExtendedLifetime(connection) {}
    }
}

@Suite struct StreamingPromptAndIDTests {
    private func idle() throws -> Transcript {
        var transcript = Transcript(snapshot: try deferredAck(sid: "sid-1", key: "s1", count: 300)
            .decode(LiveSessionSnapshot.self))
        transcript.installLatestPage(plain(181...300), hasOlder: true)
        return transcript
    }

    /// A prompt answered `streaming` was stored at submit (`methods_prompt.py:817-820`):
    /// the first quiet re-read settles it, so it never sits below its own reply.
    @Test func aStreamingPromptSettlesAfterOneQuietReread() throws {
        var transcript = try idle()
        let prompt = transcript.appendUserPrompt("你好")
        transcript.promptAnswered(itemID: prompt, status: "streaming", userRowID: 301)
        transcript.apply(event("message.start"))
        transcript.apply(event("message.delta", ["text": "在的"]))
        transcript.apply(event("message.complete", completePayload("在的", rows: [301, 302])))
        let rows = plain(181...300) + [user(301, "你好"), assistant(302, "在的")]
        transcript.installRereadPage(rows, ticket: transcript.beginReread(), reachesStart: false)
        #expect(transcript.items.suffix(2).map(\.text) == ["你好", "在的"])
        #expect(occurrences(transcript, "你好") == 1)
        #expect(transcript.historyCount == transcript.items.count)
        #expect(!transcript.needsReread)
        expectWellFormed(transcript)
    }

    /// A stored tool row is keyed by its row, whether or not a live row shares its call
    /// id: its identity does not change between re-reads.
    @Test func aStoredToolRowKeepsItsID() throws {
        var transcript = try idle()
        transcript.apply(event("message.start"))
        transcript.apply(event("tool.start", ["tool_id": "call-A", "name": "terminal"]))
        let rows = plain(181...289) + [user(290, "q"), assistant(291, "看看", call: "call-A"), tool(292, call: "call-A")]
        transcript.installRereadPage(rows, ticket: transcript.beginReread(), reachesStart: false)
        let withLive = transcript.items.first { $0.rowID == 292 }?.id
        transcript.apply(event("tool.complete", ["tool_id": "call-A", "name": "terminal"]))
        transcript.apply(event("message.complete", completePayload("", rows: [290, 291, 292])))
        transcript.installRereadPage(rows, ticket: transcript.beginReread(), reachesStart: false)
        #expect(!transcript.items.contains { $0.rowID == nil && $0.role == .tool })  // the live row is gone
        transcript.installRereadPage(rows, ticket: transcript.beginReread(), reachesStart: false)
        let withoutLive = transcript.items.first { $0.rowID == 292 }?.id
        #expect(withLive == "row-292" && withoutLive == "row-292")
        expectWellFormed(transcript)
    }
}
