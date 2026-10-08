import Foundation
import HermesProtocol
import Testing

@testable import HermesKit

// Issue #5, round 5: the fourth review's follow-ups (S1-S3, N-a). The review's repros,
// on API that 44ebc72 has too; tests of new API are in Round5ApiTests.swift.

private func event(_ type: String, _ payload: JSONValue? = nil) -> GatewayEvent {
    GatewayEvent(type: type, sessionID: "sid-1", payload: payload)
}

/// An idle chat whose history is rows 1...2 (prompt, reply), every row read.
private func idle() -> Transcript {
    var transcript = Transcript()
    transcript.installLatestPage([storedRow(id: 1), storedRow(id: 2)], hasOlder: false)
    return transcript
}

@MainActor
private func request(_ method: String, in log: FrameLog, after count: Int = 0) async -> JSONValue? {
    for _ in 0..<300 {
        let requests = log.requests(method)
        if requests.count > count { return requests[count] }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return nil
}

/// S1: an `error` at turn start that the turn goes on past (a pending model switch,
/// `session_compression.py:209,211`; a configured-model adopt, `model_switch.py:495`)
/// closes the empty turn. With show-reasoning off, the agent's first API call sends only a
/// `thinking.delta` spinner frame (`turn_iteration_prep.py:319-324`) until the first token.
@Suite struct TurnStartErrorTests {
    /// The review's P-A.
    @Test func theAgentsFirstSpinnerFrameReopensTheTurn() {
        var transcript = idle()
        let prompt = transcript.appendUserPrompt("hello")
        transcript.promptAnswered(itemID: prompt, status: "streaming", userRowID: 3)
        transcript.apply(event("message.start"))
        transcript.apply(event("error", ["message": "Could not switch model: boom"]))
        transcript.apply(event("thinking.delta", ["text": "(｡•́︿•̀｡) pondering..."]))
        transcript.apply(event("status.update", ["kind": "status", "text": "Recalling memory"]))
        #expect(transcript.isRunning, "no Stop button")
        #expect(transcript.waiting != nil)
        #expect(transcript.waiting?.hint == "Recalling memory")
    }

    /// The review's P-D: a chat shown again while its turn runs (B), then an unrelated
    /// `error`; the turn's next spinner frame shows it running again.
    @Test func aChatShownAgainRunsAgainAfterAnUnrelatedError() {
        var transcript = idle()
        transcript.reconcileRunning(true)
        transcript.apply(event("error", ["message": "Could not switch to configured model x: boom"]))
        transcript.apply(event("thinking.delta", ["text": "(◕‿◕) thinking..."]))
        #expect(transcript.isRunning)
        #expect(transcript.waiting != nil)
    }

    /// R3 still holds: a follow-up refused after its `message.start` never reaches the agent,
    /// and what Hermes sends between turns (`status.update`, `session_notifications.py:178,254`)
    /// starts nothing.
    @Test func aRefusedFollowUpStaysEndedThroughStatusUpdates() {
        var transcript = idle()
        transcript.apply(event("message.start"))
        transcript.apply(event("error", ["message": "session is owned by another backend"]))
        transcript.apply(event("status.update", ["kind": "heartbeat", "text": "♥ heartbeat #3 firing…"]))
        transcript.apply(event("notification.show", ["text": "process done", "key": "proc-1"]))
        #expect(!transcript.isRunning)
        #expect(transcript.waiting == nil)
    }
}

/// S3: Stop while an image prompt's submit is still unanswered. Hermes queues it, then the
/// Stop clears the queue (both handled inline in arrival order, `rpc_dispatch.py:62`), but
/// the `queued` answer can reach the chat after the Stop's.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct StopBeforeTheQueuedAnswerSessionTests {
    /// The review's repro through the session: the submit's `queued` answer is held until
    /// the Stop is answered, and every re-read fails.
    @Test func stopWhileAQueuedSubmitIsUnanswered() async throws {
        let server = PagedServer(store: FakeMessageStore(rows: [storedRow(id: 1), storedRow(id: 2)]))
        let log = FrameLog()
        let (connection, transport) = try await server.connect(log: log)
        let session = try await connection.open(SessionSummary(id: "stored-1"))
        await settle(session)
        try await session.send("first")  // streaming, row 3 written at submit
        transport.sendEvent("message.start", sessionID: session.sessionID, seq: 1)
        transport.sendEvent("message.delta", sessionID: session.sessionID, seq: 2, payload: ["text": "partial"])
        #expect(await eventually { session.transcript.items.contains { $0.text == "partial" } })

        server.busyStatus.withLock { $0 = "queued" }
        _ = server.held.withLock { $0.insert("prompt.submit") }
        let sending = Task { try await session.send("with image") }
        let submit = try #require(await request("prompt.submit", in: log, after: 1))
        server.store.append([storedRow(id: 4, role: "user", text: "with image")])  // stored at accept
        server.store.setMode(.offline)

        try await session.interrupt()
        transport.respond(to: submit, result: ["status": "queued"])
        try await sending.value
        transport.sendEvent("message.complete", sessionID: session.sessionID, seq: 3,
                            payload: ["text": "partial", "status": "interrupted"])
        transport.sendEvent("session.info", sessionID: session.sessionID, seq: 4, payload: ["running": false])
        #expect(await eventually { !session.transcript.isRunning })
        #expect(session.transcript.waiting == nil)
        #expect(session.transcript.items.filter { $0.text == "with image" }.count == 1)
        withExtendedLifetime(connection) {}
    }
}

/// S2 and N-a: the re-read retries.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct RereadRetryStreakTests {
    /// One turn whose re-read the gateway answers or fails: `text` sent, replied to.
    private func turn(_ session: ChatSession, _ server: PagedServer, _ transport: FakeTransport,
                      _ text: String, seq: inout Int) async throws {
        try await session.send(text)
        let prompt = try #require(server.store.rows.last?.id)
        transport.sendEvent("message.start", sessionID: session.sessionID, seq: seq)
        transport.sendEvent("message.delta", sessionID: session.sessionID, seq: seq + 1, payload: ["text": .string("re: " + text)])
        server.store.append([storedRow(id: prompt + 1, text: "re: " + text)])
        transport.sendEvent("message.complete", sessionID: session.sessionID, seq: seq + 2,
                            payload: completePayload("re: " + text, rows: [prompt, prompt + 1]))
        seq += 3
    }

    /// Waits until no re-read runs and none is tried again for a while.
    private func quiet(_ session: ChatSession, _ server: PagedServer) async {
        var count = -1
        while count != server.store.queries.count {
            count = server.store.queries.count
            _ = await eventually { session.rereadTask == nil }
            try? await Task.sleep(for: .milliseconds(150))
        }
    }

    /// The review's P-C: a long outage spends one turn's retries; the next turn's failed
    /// re-read gets its own, and settles once the gateway is back.
    @Test func aNewTurnsFailedRereadIsTriedAgainAfterALongOutage() async throws {
        let server = PagedServer(store: FakeMessageStore(rows: [storedRow(id: 1), storedRow(id: 2)]))
        let (connection, transport) = try await server.connect(log: FrameLog())
        let session = try await connection.open(SessionSummary(id: "stored-1"))
        await settle(session)
        var seq = 1
        session.rereadRetryDelays = [.milliseconds(20), .milliseconds(20), .milliseconds(20)]
        server.store.setMode(.offline)
        try await turn(session, server, transport, "one", seq: &seq)
        await quiet(session, server)  // its re-read and all three retries failed

        session.rereadRetryDelays = [.milliseconds(400), .milliseconds(400), .milliseconds(400)]
        let before = server.store.queries.count
        try await turn(session, server, transport, "two", seq: &seq)
        #expect(await eventually { server.store.queries.count > before && session.rereadTask == nil })
        server.store.setMode(.paged)
        #expect(await eventually { session.transcript.historyCount == session.transcript.items.count },
                "the second turn never settles")
        #expect(session.transcript.items.filter { $0.text == "two" }.count == 1)
        withExtendedLifetime(connection) {}
    }
}
