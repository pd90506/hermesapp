import Foundation
import HermesProtocol
import Synchronization
import Testing

@testable import HermesKit

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct PagedHistoryTests {
    private func connect(_ server: PagedServer, log: FrameLog, epoch: String = "E1",
                         extra: [FakeTransport] = []) async throws -> (GatewayConnection, FakeTransport) {
        try await server.connect(log: log, epoch: epoch, extra: extra)
    }

    private func loaded(_ session: ChatSession) async {
        await session.historyTask?.value
    }

    // MARK: 1. Opening is bounded

    /// Thousands of stored rows: no resume path asks for the transcript, and each
    /// open reads and builds one page of 120.
    @Test func everyResumePathReadsOnlyTheNewestPage() async throws {
        let store = FakeMessageStore(count: 5000)
        let server = PagedServer(store: store)
        let log = FrameLog()
        let secondLog = FrameLog()
        let second = FakeTransport()
        second.serve(epoch: "E2", log: secondLog, server.handle)
        let (connection, first) = try await connect(server, log: log, extra: [second])

        var sessions: [ChatSession] = []
        sessions.append(try await connection.openBotChat(profile: "coder"))
        sessions.append(try await connection.open(HistoryEntry(profile: "coder", summary: SessionSummary(id: "coder-side"))))
        sessions.append(try await connection.open(SessionSummary(id: "stored-1")))
        for session in sessions {
            await loaded(session)
            #expect(session.transcript.items.compactMap(\.rowID) == Array(4881...5000))
            #expect(session.transcript.paging.hasOlder)
        }

        // Cold restore after a backend restart (`docs/protocol.md` §7 step 4).
        let active = try #require(connection.activeSession)
        first.serverDrops()
        #expect(await eventually { connection.state == .connected && !secondLog.requests("session.resume").isEmpty })
        #expect(await eventually { active.transcript.paging.isLoaded && active.historyLoad == .idle })
        #expect(active.transcript.items.count == 120)

        let resumes = log.requests("session.resume") + secondLog.requests("session.resume")
        #expect(resumes.count == 4)
        for resume in resumes {
            #expect(resume["params"]?["omit_messages"] == true && resume["params"]?["defer_history"] == true)
        }
        #expect((log.requests("session.history") + secondLog.requests("session.history")).isEmpty)
        #expect(store.queries.count == 4)
        #expect(store.queries.allSatisfy { $0.order == .latest && $0.limit == 120 && $0.offset == 0 })
        #expect(store.queries.first?.profile == "coder" && store.queries.last?.profile == nil)
    }

    /// The page read alongside the resume is kept only while the session is still
    /// hydrating; a session that was live already is read again after the ack.
    /// The running turn's prompt is stored and echoed (`inflight.user`): it shows twice
    /// until the turn's completion re-read, then once. (Through round 5 the echo was
    /// matched to the stored row while the turn ran; stored and live are no longer matched.)
    @Test func aConcurrentReadIsTrustedOnlyWhileTheSessionHydrates() async throws {
        // The last stored row is the prompt of the turn still running.
        let store = FakeMessageStore(count: 299)
        let server = PagedServer(store: store)
        let (connection, transport) = try await connect(server, log: FrameLog())
        let cold = try await connection.openBotChat(profile: "coder")
        await loaded(cold)
        #expect(store.queries.count == 1)

        server.runningTurn.withLock {
            $0 = ["assistant": "Work", "streaming": true, "user": "user 299", "started_at": 1.0, "updated_at": 2.0]
        }
        let live = try await connection.open(SessionSummary(id: "stored-1"))
        await loaded(live)
        #expect(store.queries.count == 3)
        #expect(live.transcript.items.suffix(4).map(\.text) == ["assistant 298", "user 299", "user 299", "Work"])
        #expect(live.transcript.isRunning)

        // The running turn keeps streaming into its one reply.
        transport.sendEvent("message.delta", sessionID: live.sessionID, seq: 1, payload: ["text": "ing"])
        store.append([storedRow(id: 300, text: "Working")])
        transport.sendEvent("message.complete", sessionID: live.sessionID, seq: 2,
                            payload: completePayload("Working", rows: [299, 300]))
        #expect(await eventually { !live.transcript.isRunning })
        await settle(live)
        let texts = live.transcript.items.map(\.text)
        #expect(texts.suffix(3) == ["assistant 298", "user 299", "Working"])
        #expect(Set(texts).count == texts.count)
        expectWellFormed(live.transcript)
    }

    // MARK: 2. Scrolling up

    @Test func olderPagesArriveInOrderUntilTheBeginning() async throws {
        let store = FakeMessageStore(count: 300)
        let (connection, _) = try await connect(PagedServer(store: store), log: FrameLog())
        let session = try await connection.openBotChat(profile: "coder")
        await loaded(session)
        #expect(!session.reachedBeginning)

        await session.loadOlderMessages()
        // Offset 110: the page re-reads 10 held rows (S4 overlap), cut at the first held one.
        #expect(session.transcript.items.compactMap(\.rowID) == Array(71...300))
        await session.loadOlderMessages()
        #expect(session.transcript.items.compactMap(\.rowID) == Array(1...300))
        #expect(session.reachedBeginning)
        #expect(Set(session.transcript.items.map(\.id)).count == 300)

        await session.loadOlderMessages()  // at the beginning: no request
        #expect(store.queries.map(\.offset) == [0, 110, 230])
        expectWellFormed(session.transcript)
    }

    @Test func onlyOneOlderPageIsInFlight() async throws {
        let store = FakeMessageStore(count: 400)
        let (connection, _) = try await connect(PagedServer(store: store), log: FrameLog())
        let session = try await connection.openBotChat(profile: "coder")
        await loaded(session)

        store.hold()
        let first = Task { await session.loadOlderMessages() }
        #expect(await eventually { store.heldCount == 1 })
        #expect(session.historyLoad == .loadingOlder)
        await session.loadOlderMessages()  // returns at once
        await session.loadOlderMessages()
        store.release()
        await first.value

        #expect(store.queries.count == 2)
        #expect(store.maxInFlight == 1)
        #expect(session.transcript.items.compactMap(\.rowID) == Array(171...400))
        expectWellFormed(session.transcript)
    }

    // MARK: 3. Seams

    /// A turn prompted here streams and is stored while the newest page is held:
    /// the page lands with that turn's rows in it.
    @Test func aTurnDuringTheFirstReadIsShownOnce() async throws {
        let store = FakeMessageStore(count: 300)
        let server = PagedServer(store: store)
        let (connection, transport) = try await connect(server, log: FrameLog())
        store.hold()
        let session = try await connection.openBotChat(profile: "coder")
        #expect(session.historyLoad == .loadingLatest)

        try await session.send("user 301")
        transport.sendEvent("message.start", sessionID: session.sessionID, seq: 1)
        transport.sendEvent("message.delta", sessionID: session.sessionID, seq: 2, payload: ["text": "assistant 302"])
        store.append([storedRow(id: 302)])
        transport.sendEvent("message.complete", sessionID: session.sessionID, seq: 3,
                            payload: completePayload("assistant 302", rows: [301, 302]))
        #expect(await eventually { !session.transcript.isRunning })
        store.release()
        // The page holds the finished turn; its re-read replaces the live copy.
        await settle(session)

        let texts = session.transcript.items.map(\.text)
        #expect(texts.suffix(3) == ["assistant 300", "user 301", "assistant 302"])
        #expect(Set(texts).count == texts.count)

        // The next page starts right before the oldest row held: no gap, no overlap.
        await session.loadOlderMessages()
        // The finished turn is shown from its stored rows 301-302 now (its last row is in
        // the page); the older page starts 10 rows early (S4 overlap).
        #expect(session.transcript.items.compactMap(\.rowID) == Array(73...302))
        expectWellFormed(session.transcript)
    }

    /// A cold restore while the newest page is in flight: the page read for the
    /// replaced transcript is dropped, the one read after the restore lands.
    @Test func aRestoreMidLoadDropsTheStalePage() async throws {
        let store = FakeMessageStore(count: 300)
        let server = PagedServer(store: store)
        let second = FakeTransport()
        second.serve(epoch: "E2", log: FrameLog(), server.handle)
        let (connection, first) = try await connect(server, log: FrameLog(), extra: [second])
        store.hold()
        let session = try await connection.openBotChat(profile: "coder")
        #expect(await eventually { store.heldCount == 1 })

        first.serverDrops()
        #expect(await eventually { store.heldCount == 2 && connection.state == .connected })
        store.releaseOldest()  // the stale read, served first
        #expect(await eventually { store.served == 1 })
        #expect(session.historyLoad == .loadingLatest)
        #expect(session.transcript.items.isEmpty)

        store.append((301...310).map { storedRow(id: $0) })
        store.release()
        #expect(await eventually { session.historyLoad == .idle })
        #expect(session.transcript.items.compactMap(\.rowID) == Array(191...310))
        expectWellFormed(session.transcript)
    }

    // MARK: 4. Old gateways

    @Test func aGatewayWithoutPagingSendsTheWholeHistory() async throws {
        let store = FakeMessageStore(count: 150, mode: .noPagination)
        let (connection, _) = try await connect(PagedServer(store: store), log: FrameLog())
        let session = try await connection.openBotChat(profile: "coder")
        await loaded(session)
        #expect(session.transcript.items.compactMap(\.rowID) == Array(1...150))
        #expect(session.reachedBeginning)
        await session.loadOlderMessages()
        #expect(store.queries.count == 1)
        expectWellFormed(session.transcript)
    }

    /// A gateway that pages but ignores `order` returns the OLDEST rows; Desktop
    /// then reads the rest oldest first (`api/sessions.ts:579-592`).
    @Test func aGatewayIgnoringOrderIsReadToTheEnd() async throws {
        let rows = (1...700).map { storedRow(id: $0) }
        let source = OrderlessSource(rows: rows)
        let latest = try await ChatSession.fetchLatest(
            SessionMessagesQuery(sessionID: "s", profile: nil, limit: 120), from: source)
        #expect(latest.rows.compactMap(\.id) == Array(1...700))
        #expect(!latest.hasOlder)
    }

    // MARK: 5. Errors

    @Test(arguments: [FakeMessageStore.Mode.failing(.http(status: 404, body: #"{"detail":"Session not found"}"#)),
                      .failing(.http(status: 403, body: nil)),
                      .failing(.unauthenticated(reason: "invalid_or_expired_session")),
                      .offline])
    func aFailedPageLeavesTheChatUsableAndRetryable(_ failure: FakeMessageStore.Mode) async throws {
        let store = FakeMessageStore(count: 300, mode: failure)
        let log = FrameLog()
        let (connection, transport) = try await connect(PagedServer(store: store), log: log)
        let session = try await connection.openBotChat(profile: "coder")
        await loaded(session)
        guard case .latestFailed(let message) = session.historyLoad else {
            Issue.record("expected a failed history, got \(session.historyLoad)"); return
        }
        #expect(!message.isEmpty)
        #expect(connection.activeSession === session)

        // The chat still sends.
        try await session.send("still here")
        #expect(log.requests("prompt.submit").count == 1)
        transport.sendEvent("message.complete", sessionID: session.sessionID, seq: 1,
                            payload: completePayload("ok", rows: [301, 302]))
        store.append([storedRow(id: 302, text: "ok")])
        #expect(await eventually { !session.transcript.isRunning })

        store.setMode(.paged)
        await session.retryHistory()
        #expect(session.historyLoad == .idle)
        // The turn finished before the page was read: its re-read settles it.
        await settle(session)
        let texts = session.transcript.items.map(\.text)
        #expect(texts.suffix(3) == ["assistant 300", "still here", "ok"])
        #expect(Set(texts).count == texts.count)

        // An older page that fails can be retried as well.
        store.setMode(failure)
        await session.loadOlderMessages()
        guard case .olderFailed = session.historyLoad else {
            Issue.record("expected a failed older page, got \(session.historyLoad)"); return
        }
        store.setMode(.paged)
        await session.retryHistory()
        #expect(session.historyLoad == .idle)
        // The finished turn is shown from its stored rows 301-302 now (its last row is in
        // the page); the older page starts 10 rows early (S4 overlap).
        #expect(session.transcript.items.compactMap(\.rowID) == Array(73...302))
    }

    /// No REST access at all: the chat opens and says its history is unavailable,
    /// with no retry that could only fail again.
    @Test func aConnectorWithoutRESTStillOpensTheChat() async throws {
        let transport = FakeTransport()
        let server = PagedServer(store: FakeMessageStore(count: 10))
        transport.serve(log: FrameLog(), server.handle)
        var configuration = GatewayClient.Configuration()
        configuration.heartbeatInterval = nil
        let connection = GatewayConnection(configuration: configuration)
        try await connection.connect(using: FakeConnector([transport]))
        let session = try await connection.open(SessionSummary(id: "stored-1"))
        guard case .unavailable = session.historyLoad else {
            Issue.record("expected an unavailable history, got \(session.historyLoad)"); return
        }
        #expect(connection.activeSession === session)
        await session.retryHistory()
        guard case .unavailable = session.historyLoad else {
            Issue.record("retry changed the state to \(session.historyLoad)"); return
        }
        expectWellFormed(session.transcript)
    }
}

/// Pages like a gateway that predates `order` (pagination echoes no order and
/// every read starts at the oldest row).
private struct OrderlessSource: SessionMessagesSource {
    let rows: [StoredMessage]

    func messagesPage(_ query: SessionMessagesQuery) async throws -> SessionMessagesPage {
        let page = Array(rows.dropFirst(query.offset).prefix(query.limit))
        return SessionMessagesPage(messages: page, pagination: SessionMessagesPagination(
            limit: query.limit, offset: query.offset, order: nil, returned: page.count))
    }
}
