import Foundation
import HermesProtocol
import Synchronization
import Testing

@testable import HermesKit

// Fixes after review 7 (round 8): an interrupted partial that no runtime stored stays,
// a `streaming` answer without a row id waits for two quiet re-reads, and a page that
// repeats a row still yields unique ids.

private func user(_ id: Int, _ text: String) -> StoredMessage {
    StoredMessage(id: id, role: "user", content: .string(text))
}

private func plain(_ range: ClosedRange<Int>) -> [StoredMessage] { range.map { storedRow(id: $0) } }

private func occurrences(_ transcript: Transcript, _ segment: String) -> Int {
    transcript.items.reduce(0) { $0 + $1.text.components(separatedBy: segment).count - 1 }
}

private func event(_ type: String, _ payload: JSONValue? = nil) -> GatewayEvent {
    GatewayEvent(type: type, sessionID: "sid-1", payload: payload)
}

private func interrupted(_ text: String, rows: [Int]) -> JSONValue {
    var payload = completePayload(text, rows: rows).objectValue ?? [:]
    payload["status"] = "interrupted"
    return .object(payload)
}

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct UnstoredInterruptTests {
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

    /// A runtime that leaves the loop without storing the in-flight message (the Codex
    /// app-server, `agent/transports/codex_app_server_session.py:583-586`) and sends no text: the partial
    /// stays live, shown once.
    @Test func aPartialNoRuntimeStoredStays() async throws {
        let (session, transport, _, connection) = try await open(plain(1...300))
        try await session.send("继续")  // stored as row 301 at submit
        transport.sendEvent("message.start", sessionID: session.sessionID, seq: 1)
        transport.sendEvent("message.delta", sessionID: session.sessionID, seq: 2, payload: ["text": "部分"])
        #expect(await eventually { occurrences(session.transcript, "部分") == 1 })
        transport.sendEvent("message.complete", sessionID: session.sessionID, seq: 3,
                            payload: interrupted("", rows: [301]))
        #expect(await eventually { settled(session) && session.transcript.items.contains { $0.rowID == 301 } })
        #expect(occurrences(session.transcript, "部分") == 1)
        #expect(occurrences(session.transcript, "继续") == 1)
        expectWellFormed(session.transcript)
        withExtendedLifetime(connection) {}
    }

    /// The same for a turn that was running at open.
    @Test func aPartialNoRuntimeStoredStaysWhenRunningAtOpen() async throws {
        let (session, transport, _, connection) = try await open(
            plain(1...299) + [user(300, "查一下")], inflight: ["assistant": "", "streaming": true, "user": "查一下"])
        transport.sendEvent("message.delta", sessionID: session.sessionID, seq: 1, payload: ["text": "部分"])
        #expect(await eventually { occurrences(session.transcript, "部分") == 1 })
        transport.sendEvent("message.complete", sessionID: session.sessionID, seq: 2,
                            payload: interrupted("", rows: [300]))
        #expect(await eventually { settled(session) })
        #expect(occurrences(session.transcript, "部分") == 1)
        expectWellFormed(session.transcript)
        withExtendedLifetime(connection) {}
    }
}

@Suite struct Round8TranscriptTests {
    private func idle() throws -> Transcript {
        var transcript = Transcript(snapshot: try deferredAck(sid: "sid-1", key: "s1", count: 300)
            .decode(LiveSessionSnapshot.self))
        transcript.installLatestPage(plain(181...300), hasOlder: true)
        return transcript
    }

    /// A repetition loop is stored hidden and sent as the sentinel
    /// (`agent/turn_api_call.py:197-205`): the looped text goes with the re-read.
    @Test func aRepetitionLoopIsStillDropped() throws {
        var transcript = try idle()
        transcript.apply(event("message.start"))
        transcript.apply(event("message.delta", ["text": "again again again"]))
        transcript.apply(event("message.complete", interrupted(Transcript.repetitionLoopSentinel, rows: [301, 302])))
        var hidden = StoredMessage(id: 302, role: "assistant", content: "")
        hidden.displayKind = "hidden"
        let rows = plain(182...300) + [user(301, "q"), hidden]
        transcript.installRereadPage(rows, ticket: transcript.beginReread(), reachesStart: false)
        #expect(occurrences(transcript, "again") == 0)
        #expect(transcript.historyCount == transcript.items.count)
        expectWellFormed(transcript)
    }

    /// `streaming` without `user_row_id`: compute-host isolation, or a failed
    /// submit-time write, answers before any row exists (`methods_prompt.py:798-819`).
    /// One quiet re-read must not drop the bubble; the turn's re-read settles it.
    @Test func aStreamingAnswerWithoutARowKeepsTheBubble() throws {
        var transcript = try idle()
        let prompt = transcript.appendUserPrompt("你好")
        transcript.promptAnswered(itemID: prompt, status: "streaming")
        #expect(transcript.needsReread)
        transcript.installRereadPage(plain(181...300), ticket: transcript.beginReread(), reachesStart: false)
        #expect(transcript.items.contains { $0.id == prompt })

        transcript.apply(event("message.start"))
        #expect(transcript.items.contains { $0.id == prompt })
        transcript.apply(event("message.delta", ["text": "在的"]))
        transcript.apply(event("message.complete", completePayload("在的", rows: [301, 302])))
        #expect(transcript.items.contains { $0.id == prompt })
        let rows = plain(183...300) + [user(301, "你好"), StoredMessage(id: 302, role: "assistant", content: "在的")]
        transcript.installRereadPage(rows, ticket: transcript.beginReread(), reachesStart: false)
        transcript.installRereadPage(rows, ticket: transcript.beginReread(), reachesStart: false)
        #expect(occurrences(transcript, "你好") == 1)
        #expect(transcript.historyCount == transcript.items.count)
        expectWellFormed(transcript)
    }

    /// A missing status is conservative too.
    @Test func noStatusWaitsForTwoQuietRereads() throws {
        var transcript = try idle()
        let prompt = transcript.appendUserPrompt("你好")
        transcript.promptAnswered(itemID: prompt)
        transcript.installRereadPage(plain(181...300), ticket: transcript.beginReread(), reachesStart: false)
        #expect(transcript.items.contains { $0.id == prompt })
        #expect(transcript.needsReread)
    }

    /// A page that repeats a row still yields unique ids.
    @Test func aRepeatedRowGetsASuffix() {
        var transcript = Transcript()
        transcript.installLatestPage(plain(1...3) + [storedRow(id: 2)] + plain(4...5), hasOlder: false)
        // Not `expectWellFormed`: its stored-rows-in-order check rejects the repeat itself.
        #expect(transcript.items.count == 6)
        #expect(Set(transcript.items.map(\.id)).count == transcript.items.count)
    }
}
