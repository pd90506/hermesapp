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
    /// The rest of a turn whose prompt `prompt` was just sent: it starts, replies, stores the
    /// reply as `prompt + 1` and ends.
    private func reply(_ session: ChatSession, _ server: PagedServer, _ transport: FakeTransport,
                       to prompt: Int, seq: inout Int) {
        let text = "re: \(prompt)"
        transport.sendEvent("message.start", sessionID: session.sessionID, seq: seq)
        transport.sendEvent("message.delta", sessionID: session.sessionID, seq: seq + 1, payload: ["text": .string(text)])
        server.store.append([storedRow(id: prompt + 1, text: text)])
        transport.sendEvent("message.complete", sessionID: session.sessionID, seq: seq + 2,
                            payload: completePayload(text, rows: [prompt, prompt + 1]))
        seq += 3
    }

    /// Serves the read waiting in the store (it fails while offline).
    private func serveOne(_ server: PagedServer) async {
        #expect(await eventually(seconds: 20) { server.store.heldCount == 1 })
        server.store.releaseOldest()
    }

    /// The review's P-C: a long outage spends one turn's retries; the next turn's failed
    /// re-read gets its own, and settles once the gateway is back.
    ///
    /// No step races a retry timer: the store holds every read (`hold()`) and the test serves
    /// each one itself, so the retries' order is fixed whatever the runner's speed.
    @Test func aNewTurnsFailedRereadIsTriedAgainAfterALongOutage() async throws {
        let server = PagedServer(store: FakeMessageStore(rows: [storedRow(id: 1), storedRow(id: 2)]))
        let (connection, transport) = try await server.connect(log: FrameLog())
        let session = try await connection.open(SessionSummary(id: "stored-1"))
        await settle(session)
        var seq = 1
        session.rereadRetryDelays = [.milliseconds(20), .milliseconds(20), .milliseconds(20)]

        // Turn one: its prompt is answered before the outage; then every read fails.
        try await session.send("one")  // row 3
        await settle(session)
        server.store.setMode(.offline)
        server.store.hold()
        reply(session, server, transport, to: 3, seq: &seq)
        for _ in 0..<4 { await serveOne(server) }  // its turn-end read, then its three retries
        #expect(await eventually(seconds: 20) { session.rereadTask == nil && session.rereadRetry == nil },
                "turn one's retries are spent")

        // Turn two, still offline: the read its answer asks for, then its turn-end read, fail.
        try await session.send("two")  // row 5
        reply(session, server, transport, to: 5, seq: &seq)
        #expect(await eventually(seconds: 20) { server.store.heldCount == 1 && !session.transcript.isRunning })
        server.store.releaseOldest()
        await serveOne(server)
        // A new streak: its retry fires and waits, unserved.
        #expect(await eventually(seconds: 20) { server.store.heldCount == 1 && session.rereadRetry == nil },
                "turn two's failed read is never tried again")
        server.store.setMode(.paged)
        server.store.release()
        #expect(await eventually(seconds: 20) { session.transcript.historyCount == session.transcript.items.count },
                "the second turn never settles")
        #expect(session.transcript.items.filter { $0.text == "two" }.count == 1)
        withExtendedLifetime(connection) {}
    }
}
