import Foundation
import HermesProtocol
import Testing

@testable import HermesKit

// A rebuild (`ChatSession.reset`, after a cold resume or a reconnect, §7) shows only the
// snapshot and the stored rows, plus explicitly owned unresolved sends. Nothing typed
// is lost: a failed prompt's text goes back to the composer, and a row-less prompt is stored by
// its turn (docs/protocol.md §4.2).

private func occurrences(_ transcript: Transcript, _ segment: String) -> Int {
    transcript.items.reduce(0) { $0 + $1.text.components(separatedBy: segment).count - 1 }
}

private func uniqueIDs(_ transcript: Transcript) -> Bool {
    Set(transcript.items.map(\.id)).count == transcript.items.count
}

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct ChatSessionRebuildTests {
    private func open() async throws -> (ChatSession, GatewayConnection, FakeTransport, PagedServer, FrameLog) {
        let server = PagedServer(store: FakeMessageStore(count: 300))
        let log = FrameLog()
        let (connection, transport) = try await server.connect(log: log)
        let session = try await connection.open(SessionSummary(id: "stored-1"))
        await settle(session)
        return (session, connection, transport, server, log)
    }

    /// The cold restore's snapshot: idle (a deferred ack) or with a turn running.
    private func rebuild(_ session: ChatSession, server: PagedServer, sid: String = "rt-90",
                         running inflight: JSONValue? = nil) async throws {
        let ack = inflight.map { liveAck(sid: sid, key: "stored-1", count: server.store.rows.count, inflight: $0) }
            ?? deferredAck(sid: sid, key: "stored-1", count: server.store.rows.count)
        session.reset(to: try ack.decode(LiveSessionSnapshot.self), storedSessionID: "stored-1")
        session.loadHistory()
        await settle(session)
    }

    private func submit(in log: FrameLog, after count: Int) async -> JSONValue? {
        for _ in 0..<300 {
            let all = log.requests("prompt.submit")
            if all.count > count { return all[count] }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return nil
    }

    private func failSubmit(_ session: ChatSession, _ text: String, server: PagedServer, log: FrameLog,
                            transport: FakeTransport) async throws {
        server.holdSubmits.withLock { $0 = true }
        let count = log.requests("prompt.submit").count
        let sending = Task { try await session.send(text) }
        transport.respondError(to: try #require(await submit(in: log, after: count)), code: 4090,
                               message: "Hermes is at the active session limit (4/4). Try again when another session finishes.")
        await #expect(throws: RPCError.self) { try await sending.value }
        server.holdSubmits.withLock { $0 = false }
    }

    @Test func aFailedPromptGoesBackToTheDraftOnARebuild() async throws {
        let (session, connection, transport, server, log) = try await open()
        try await failSubmit(session, "没发出去", server: server, log: log, transport: transport)
        #expect(occurrences(session.transcript, "没发出去") == 1)  // the failed bubble, before the rebuild

        try await rebuild(session, server: server)

        #expect(connection.composer(for: session).draft == "没发出去")
        #expect(occurrences(session.transcript, "没发出去") == 0)
        #expect(session.transcript.lastError?.contains("active session limit") == true)
        #expect(session.transcript.historyCount == session.transcript.items.count)
        #expect(uniqueIDs(session.transcript))
    }

    @Test func aFailedPromptJoinsAnExistingDraft() async throws {
        let (session, connection, transport, server, log) = try await open()
        try await failSubmit(session, "没发出去", server: server, log: log, transport: transport)
        connection.composer(for: session).draft = "正在写的"

        try await rebuild(session, server: server)

        // The given-back text first: it was written before the draft.
        #expect(connection.composer(for: session).draft == "没发出去\n正在写的")
        #expect(occurrences(session.transcript, "没发出去") == 0)
    }

    @Test func severalFailedPromptsGoBackInTheOrderTheyWereSent() async throws {
        let (session, connection, transport, server, log) = try await open()
        try await failSubmit(session, "a", server: server, log: log, transport: transport)
        try await failSubmit(session, "b", server: server, log: log, transport: transport)

        try await rebuild(session, server: server)

        #expect(connection.composer(for: session).draft == "a\nb")
    }

    @Test func severalFailedPromptsGoBackAheadOfAnExistingDraft() async throws {
        let (session, connection, transport, server, log) = try await open()
        try await failSubmit(session, "a", server: server, log: log, transport: transport)
        try await failSubmit(session, "b", server: server, log: log, transport: transport)
        connection.composer(for: session).draft = "c"

        try await rebuild(session, server: server)

        #expect(connection.composer(for: session).draft == "a\nb\nc")
    }

    /// A retained failed turn in the snapshot (`inflight.error`,
    /// `server.py:3146-3186`) is newer than the failure the old transcript showed.
    @Test func theSnapshotsOwnFailureWinsOverTheOldOne() async throws {
        let (session, connection, transport, server, log) = try await open()
        try await failSubmit(session, "没发出去", server: server, log: log, transport: transport)
        let ack: JSONValue = [
            "session_id": "rt-90", "resumed": "stored-1", "session_key": "stored-1",
            "message_count": .number(Double(server.store.rows.count)), "messages": [], "messages_omitted": true,
            "hydrating": false, "info": ["model": "test-model"], "running": false, "status": "idle",
            "started_at": 1_700_000_000,
            "inflight": ["assistant": "partial", "streaming": false, "user": "do it",
                         "error": "provider timed out", "status": "error", "recoverable": true],
        ]

        session.reset(to: try ack.decode(LiveSessionSnapshot.self), storedSessionID: "stored-1")

        #expect(session.transcript.lastError == "provider timed out")
        #expect(connection.composer(for: session).draft == "没发出去")
    }

    @Test func aSendInFlightThatFailsAfterARebuildGoesBackToTheDraft() async throws {
        let (session, connection, transport, server, log) = try await open()
        server.holdSubmits.withLock { $0 = true }
        let count = log.requests("prompt.submit").count
        let sending = Task { try await session.send("在路上") }
        let request = try #require(await submit(in: log, after: count))

        try await rebuild(session, server: server)
        transport.respondError(to: request, code: 4001, message: "session not found")
        await #expect(throws: RPCError.self) { try await sending.value }

        #expect(connection.composer(for: session).draft == "在路上")
        #expect(!session.transcript.isRunning)
        #expect(session.transcript.lastError == "session not found")
        #expect(occurrences(session.transcript, "在路上") == 0)
    }

    @Test func aSendInFlightThatSucceedsAfterARebuildShowsItsRowOnce() async throws {
        let (session, connection, transport, server, log) = try await open()
        server.holdSubmits.withLock { $0 = true }
        let count = log.requests("prompt.submit").count
        let sending = Task { try await session.send("在路上") }
        let request = try #require(await submit(in: log, after: count))

        let other = try await connection.open(SessionSummary(id: "stored-2"))
        await settle(other)
        #expect(occurrences(other.transcript, "在路上") == 0)
        try await rebuild(session, server: server)
        #expect(occurrences(other.transcript, "在路上") == 0)
        #expect(occurrences(session.transcript, "在路上") == 1,
                "pending content must remain visible while acknowledgement is stalled")
        #expect(session.transcript.items.last?.outgoingStatus == "Sending…")
        // Hermes took it: the row is stored at submit (`methods_prompt.py:817-820`).
        server.store.append([storedRow(id: 301, role: "user", text: "在路上")])
        transport.respond(to: request, result: ["status": "streaming", "user_row_id": 301])
        try await sending.value
        await settle(session)

        #expect(await eventually { session.rereadTask == nil && !session.transcript.needsReread })
        #expect(occurrences(session.transcript, "在路上") == 1)
        #expect(session.transcript.items.last?.rowID == 301)
        #expect(connection.composer(for: session).draft.isEmpty)
        expectWellFormed(session.transcript)
    }

    /// Hermes took the submit and runs its turn, but the answer is still on the way when
    /// the chat is rebuilt: the snapshot echoes the prompt (`inflight.user`). The bubble
    /// is not carried as well: it would show the prompt again, after the turn's reply.
    @Test func aDispatchedSendTheRebuiltSnapshotRunsIsNotCarriedTwice() async throws {
        let (session, connection, transport, server, log) = try await open()
        server.holdSubmits.withLock { $0 = true }
        let count = log.requests("prompt.submit").count
        let sending = Task { try await session.send("在路上") }
        let request = try #require(await submit(in: log, after: count))
        server.store.append([storedRow(id: 301, role: "user", text: "在路上")])

        try await rebuild(session, server: server, running: ["user": "在路上", "assistant": "好", "streaming": true])
        let pending = session.transcript.items.filter { $0.text == "在路上" && $0.rowID == nil }
        #expect(pending.count == 1, "only the snapshot's echo, no carried bubble")
        #expect(pending.first?.outgoingStatus == nil)
        #expect(session.transcript.items.last?.role == .assistant)

        transport.respond(to: request, result: ["status": "streaming", "user_row_id": 301])
        try await sending.value
        server.store.append([storedRow(id: 302, role: "assistant", text: "好了")])
        transport.sendEvent("message.complete", sessionID: "rt-90", seq: 1, payload: completePayload("好了", rows: [301, 302]))
        #expect(await eventually {
            !session.transcript.isRunning && session.rereadTask == nil && !session.transcript.needsReread
                && session.transcript.items.last?.rowID == 302
        })
        #expect(occurrences(session.transcript, "在路上") == 1)
        #expect(connection.composer(for: session).draft.isEmpty)
        expectWellFormed(session.transcript)
    }

    /// The send is answered before the rebuilt transcript's newest page is in, and
    /// that page was read before the prompt's row was stored (its answer was still on
    /// the way). The re-read the answer asked for waits for the page, then shows the row.
    @Test func aSendAnsweredBeforeTheRebuiltPageIsInShowsItsRowOnce() async throws {
        let (session, connection, transport, server, log) = try await open()
        server.holdSubmits.withLock { $0 = true }
        let count = log.requests("prompt.submit").count
        let sending = Task { try await session.send("在路上") }
        let request = try #require(await submit(in: log, after: count))

        server.store.hold()
        let ack = deferredAck(sid: "rt-90", key: "stored-1", count: server.store.rows.count)
        session.reset(to: try ack.decode(LiveSessionSnapshot.self), storedSessionID: "stored-1")
        session.loadHistory()
        #expect(await eventually { server.store.heldCount == 1 })
        #expect(occurrences(session.transcript, "在路上") == 1,
                "cold rebuild must keep pending row even before the page arrives")

        transport.respond(to: request, result: ["status": "streaming", "user_row_id": 301])
        try await sending.value
        #expect(!session.transcript.paging.isLoaded)

        // The page, read before the row was stored.
        server.store.releaseOldest()
        #expect(await eventually { session.transcript.paging.isLoaded })
        #expect(occurrences(session.transcript, "在路上") == 1,
                "an obsolete initial page must not remove the accepted local row")
        // Hermes stored the row at submit (`methods_prompt.py:817-820`); the re-read finds it.
        server.store.append([storedRow(id: 301, role: "user", text: "在路上")])
        server.store.release()
        await settle(session)

        #expect(await eventually { occurrences(session.transcript, "在路上") == 1 })
        #expect(session.rereadTask == nil && !session.transcript.needsReread)
        #expect(occurrences(session.transcript, "在路上") == 1)
        #expect(session.transcript.items.last?.rowID == 301)
        #expect(connection.composer(for: session).draft.isEmpty)
        expectWellFormed(session.transcript)
    }

    /// MF-A: an image-only prompt (row-less `streaming`) whose turn runs across a cold
    /// restore shows once: its turn stores the row, and nothing waits for another turn.
    @Test func anImageOnlyPromptWhoseTurnRunsAcrossARebuildShowsOnce() async throws {
        let (session, connection, transport, server, log) = try await open()
        defer { withExtendedLifetime(connection) {} }  // a session holds its connection weakly
        try await session.send("", images: [ComposerAttachment(filename: "a.png", data: Data([0x89, 0x50, 0x4E, 0x47]))])
        #expect(log.requests("prompt.submit").last?["params"]?["text"] == "")
        transport.sendEvent("message.start", sessionID: session.sessionID, seq: 1)
        #expect(await eventually { session.transcript.isRunning })

        try await rebuild(session, server: server, running: ["assistant": "looking", "streaming": true])
        server.store.append([storedRow(id: 301, role: "user", text: "@image:/p/a.png"),
                             storedRow(id: 302, role: "assistant", text: "一只猫")])
        transport.sendEvent("message.delta", sessionID: "rt-90", seq: 1, payload: ["text": " at a cat"])
        transport.sendEvent("message.complete", sessionID: "rt-90", seq: 2,
                            payload: completePayload("一只猫", rows: [301, 302]))

        #expect(await eventually {
            !session.transcript.isRunning && session.rereadTask == nil && !session.transcript.needsReread
                && session.transcript.items.last?.rowID == 302
        })
        #expect(session.transcript.items.filter { !$0.images.isEmpty }.count == 1)
        #expect(session.transcript.historyCount == session.transcript.items.count)
        expectWellFormed(session.transcript)
    }

    /// The same, when the turn ended while the socket was down: the newest page
    /// already holds the row.
    @Test func anImageOnlyPromptWhoseTurnEndedDuringTheOutageShowsOnce() async throws {
        let (session, connection, transport, server, _) = try await open()
        defer { withExtendedLifetime(connection) {} }
        try await session.send("", images: [ComposerAttachment(filename: "a.png", data: Data([0x89, 0x50, 0x4E, 0x47]))])
        transport.sendEvent("message.start", sessionID: session.sessionID, seq: 1)
        #expect(await eventually { session.transcript.isRunning })
        server.store.append([storedRow(id: 301, role: "user", text: "@image:/p/a.png"),
                             storedRow(id: 302, role: "assistant", text: "一只猫")])

        try await rebuild(session, server: server)

        #expect(session.transcript.items.filter { !$0.images.isEmpty }.count == 1,
                "\(session.transcript.items.suffix(4).map { "\($0.id) \($0.role) [\($0.text)] \($0.images.map(\.name))" })")
        #expect(session.transcript.historyCount == session.transcript.items.count)
        #expect(!session.transcript.isRunning)
        expectWellFormed(session.transcript)
    }
}
