import Foundation
import HermesProtocol
import Testing

@testable import HermesKit

// Switching chats (docs/protocol.md §4.2): a chat shown before comes back at once and
// reconciles in the background; a first open shows its frame at once; nothing that can
// run in parallel waits for something else.

private func occurrences(_ transcript: Transcript, _ segment: String) -> Int {
    transcript.items.reduce(0) { $0 + $1.text.components(separatedBy: segment).count - 1 }
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

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct ChatRevisitTests {
    private func connect() async throws -> (GatewayConnection, FakeTransport, PagedServer, FrameLog) {
        let server = PagedServer(store: FakeMessageStore(count: 300))
        let log = FrameLog()
        let (connection, transport) = try await server.connect(log: log)
        return (connection, transport, server, log)
    }

    /// Opens `stored-1`, then the coder bot's chat, each settled.
    private func openTwo(_ connection: GatewayConnection) async throws -> (ChatSession, ChatSession) {
        let first = try await connection.open(SessionSummary(id: "stored-1"))
        await settle(first)
        let bot = try await connection.openBotChat(profile: "coder")
        await settle(bot)
        return (first, bot)
    }

    @Test func goingBackToAChatShowsItAtOnceThenReconciles() async throws {
        let (connection, transport, server, log) = try await connect()
        let (first, bot) = try await openTwo(connection)
        #expect(connection.activeSession === bot)
        let shownBefore = first.transcript.items.map(\.id)
        let resumes = log.requests("session.resume").count
        // Meanwhile another client ran a turn on it; its events went to that client.
        server.store.append([storedRow(id: 301, role: "user", text: "从桌面问的"),
                             storedRow(id: 302, role: "assistant", text: "桌面的回答")])
        _ = server.held.withLock { $0.insert("session.activate") }

        let back = try await connection.open(SessionSummary(id: "stored-1"))

        // On screen at once, as it was left: no resume, no wait for the gateway.
        #expect(back === first)
        #expect(connection.activeSession === first)
        #expect(connection.opening == nil)
        #expect(first.transcript.items.map(\.id) == shownBefore)
        #expect(log.requests("session.resume").count == resumes)

        // Then: the socket binds the runtime session again, and the newest rows are read again.
        let activate = try #require(await request("session.activate", in: log))
        #expect(activate["params"] == ["session_id": .string(first.sessionID), "omit_messages": true])
        transport.respond(to: activate, result: try #require(server.answer("session.activate", activate["params"] ?? nil)))
        await first.revisitTask?.value
        await settle(first)
        #expect(await eventually { first.rereadTask == nil && occurrences(first.transcript, "桌面的回答") == 1 })
        #expect(occurrences(first.transcript, "从桌面问的") == 1)
        #expect(first.transcript.historyCount == first.transcript.items.count)
        expectWellFormed(first.transcript)
    }

    /// A local row (a `/btw` answer) keeps its place through the revisit's re-read:
    /// after the stored row it followed, above what another client stored meanwhile, once.
    @Test func aLocalRowKeepsItsPlaceThroughARevisitReread() async throws {
        let (connection, transport, server, _) = try await connect()
        let (first, _) = try await openTwo(connection)
        // A side question answered while the chat is warm (`events.py:443-452`).
        transport.sendEvent("btw.complete", sessionID: first.sessionID,
                            payload: ["task_id": "btw_1", "text": "Yes, green.", "question": "is CI green?"])
        #expect(await eventually { first.transcript.items.last?.sideQuestion?.answer == "Yes, green." })
        let localID = try #require(first.transcript.items.last?.id)
        server.store.append([storedRow(id: 301, role: "user", text: "从桌面问的"),
                             storedRow(id: 302, role: "assistant", text: "桌面的回答")])

        let back = try await connection.open(SessionSummary(id: "stored-1"))
        await back.revisitTask?.value
        await settle(back)

        #expect(await eventually { back.rereadTask == nil && occurrences(back.transcript, "桌面的回答") == 1 })
        let items = back.transcript.items
        #expect(items.filter { $0.id == localID }.count == 1)
        let local = try #require(items.firstIndex { $0.id == localID })
        #expect(items[local - 1].rowID == 300)
        #expect(items[local + 1].rowID == 301)
        #expect(back.transcript.historyCount == items.count)
        expectWellFormed(back.transcript)
    }

    @Test func aWarmChatKeepsReceivingItsEvents() async throws {
        let (connection, transport, server, _) = try await connect()
        let (first, bot) = try await openTwo(connection)

        // A turn on the chat left behind; this socket still serves its runtime session.
        server.store.append([storedRow(id: 301, role: "user", text: "后台的问题"),
                             storedRow(id: 302, role: "assistant", text: "后台的回答")])
        transport.sendEvent("message.start", sessionID: first.sessionID, seq: 1)
        transport.sendEvent("message.delta", sessionID: first.sessionID, seq: 2, payload: ["text": "后台的回答"])
        transport.sendEvent("message.complete", sessionID: first.sessionID, seq: 3,
                            payload: completePayload("后台的回答", rows: [301, 302]))

        #expect(await eventually {
            !first.transcript.isRunning && first.rereadTask == nil && !first.transcript.needsReread
                && occurrences(first.transcript, "后台的回答") == 1
        })
        #expect(first.transcript.historyCount == first.transcript.items.count)
        #expect(occurrences(bot.transcript, "后台的回答") == 0)
        #expect(connection.activeSession === bot)
    }

    @Test func aGoneRuntimeSessionFallsBackToAResume() async throws {
        let (connection, transport, server, log) = try await connect()
        let (first, _) = try await openTwo(connection)
        let oldSID = first.sessionID
        let resumes = log.requests("session.resume").count
        _ = server.held.withLock { $0.insert("session.activate") }

        let back = try await connection.open(SessionSummary(id: "stored-1"))
        let activate = try #require(await request("session.activate", in: log))
        transport.respondError(to: activate, code: 4007, message: "session no longer live; retry resume")
        await back.revisitTask?.value
        await settle(back)

        #expect(back === first)  // the same chat on screen, composer and all
        #expect(connection.activeSession === first)
        #expect(log.requests("session.resume").count == resumes + 1)
        #expect(log.requests("session.resume").last?["params"]?["session_id"] == "stored-1")
        #expect(first.sessionID != oldSID)
        #expect(first.transcript.paging.isLoaded && !first.transcript.items.isEmpty)
        expectWellFormed(first.transcript)
    }

    @Test func onlyTheMostRecentChatsStayWarm() async throws {
        let (connection, _, _, log) = try await connect()
        for index in 0...GatewayConnection.warmChatLimit {
            await settle(try await connection.open(SessionSummary(id: "s-\(index)")))
        }
        #expect(connection.warmChats.count == GatewayConnection.warmChatLimit)
        #expect(!connection.warmChats.contains { $0.storedSessionID == "s-0" })

        let resumes = log.requests("session.resume").count
        _ = try await connection.open(SessionSummary(id: "s-1"))  // still warm
        #expect(log.requests("session.resume").count == resumes)
        _ = try await connection.open(SessionSummary(id: "s-0"))  // evicted: opened cold
        #expect(log.requests("session.resume").count == resumes + 1)
    }

    @Test func aFirstOpenShowsItsFrameAtOnce() async throws {
        let (connection, transport, server, log) = try await connect()
        let first = try await connection.open(SessionSummary(id: "stored-1"))
        await settle(first)
        let resumes = log.requests("session.resume").count
        _ = server.held.withLock { $0.insert("session.resume") }

        let opening = Task { try await connection.open(SessionSummary(id: "stored-2", title: "Earlier")) }
        let resume = try #require(await request("session.resume", in: log, after: resumes))
        #expect(connection.opening == PendingChat(profile: nil, kind: .session, title: "Earlier"))
        #expect(connection.activeSession === first)

        transport.respond(to: resume, result: try #require(server.answer("session.resume", resume["params"] ?? nil)))
        let second = try await opening.value
        #expect(connection.opening == nil)
        #expect(connection.activeSession === second)

        // A failed first open clears the frame; the chat shown before stays.
        let failing = Task { try await connection.open(SessionSummary(id: "stored-3", title: "Gone")) }
        let gone = try #require(await request("session.resume", in: log, after: resumes + 1))
        #expect(connection.opening?.title == "Gone")
        transport.respondError(to: gone, code: 4007, message: "session not found")
        await #expect(throws: RPCError.self) { try await failing.value }
        #expect(connection.opening == nil)
        #expect(connection.activeSession === second)
    }

    @Test func aBotChatsNewestPageIsReadAlongsideItsLookup() async throws {
        let (connection, transport, server, log) = try await connect()
        _ = server.held.withLock { $0.insert("session.list") }

        let opening = Task { try await connection.openBotChat(profile: "coder") }
        // History refreshes list sessions too; the registry lookup is the one by title.
        var found: JSONValue?
        for _ in 0..<300 where found == nil {
            found = log.requests("session.list").first { $0["params"]?["title"] == "Bot Chat" }
            if found == nil { try await Task.sleep(for: .milliseconds(10)) }
        }
        let lookup = try #require(found)
        _ = server.held.withLock { $0.remove("session.list") }
        for other in log.requests("session.list") where other["params"]?["title"] != "Bot Chat" {
            transport.respond(to: other, result: try #require(server.answer("session.list", other["params"] ?? nil)))
        }
        // The roster names the chat's tip, so its page is already being read.
        #expect(await eventually { server.store.queries.contains { $0.sessionID == "coder-chat" } })
        #expect(log.requests("session.resume").isEmpty)
        #expect(connection.opening == PendingChat(profile: "coder", kind: .botChat, title: nil))

        transport.respond(to: lookup, result: try #require(server.answer("session.list", lookup["params"] ?? nil)))
        let bot = try await opening.value
        await settle(bot)
        #expect(bot.transcript.paging.isLoaded && !bot.transcript.items.isEmpty)
        // The page read alongside the lookup is the one shown: not read twice.
        #expect(server.store.queries.filter { $0.sessionID == "coder-chat" }.count == 1)
    }

    // MARK: Drafts survive other chats' opens (M1)

    private func png(_ name: String) -> ComposerAttachment {
        ComposerAttachment(filename: name, data: Data([0x89, 0x50, 0x4E, 0x47]))
    }

    @Test func aFailedOpenKeepsTheShownChatsDraftAndImages() async throws {
        let (connection, transport, server, log) = try await connect()
        let first = try await connection.open(SessionSummary(id: "stored-1"))
        await settle(first)
        let composer = connection.composer(for: first)
        composer.draft = "还没写完"
        composer.attach(png("a.png"))
        composer.attach(png("b.png"))

        _ = server.held.withLock { $0.insert("session.list") }
        let opening = Task { try await connection.openBotChat(profile: "coder") }
        var lookup: JSONValue?
        for _ in 0..<300 where lookup == nil {
            lookup = log.requests("session.list").first { $0["params"]?["title"] == "Bot Chat" }
            if lookup == nil { try await Task.sleep(for: .milliseconds(10)) }
        }
        #expect(connection.opening != nil)
        transport.respondError(to: try #require(lookup), code: 5000, message: "state.db is locked")
        await #expect(throws: BotChatError.self) { try await opening.value }

        #expect(connection.opening == nil)
        #expect(connection.activeSession === first)
        #expect(connection.composer(for: first) === composer)
        #expect(composer.draft == "还没写完")
        #expect(composer.attachments.map(\.filename) == ["a.png", "b.png"])
    }

    @Test func aSupersededOrCancelledOpenKeepsTheDraft() async throws {
        let (connection, _, server, log) = try await connect()
        let first = try await connection.open(SessionSummary(id: "stored-1"))
        await settle(first)
        let composer = connection.composer(for: first)
        composer.draft = "draft"
        composer.attach(png("a.png"))
        let resumes = log.requests("session.resume").count
        _ = server.held.withLock { $0.insert("session.resume") }

        let cancelled = Task { try await connection.open(SessionSummary(id: "stored-2", title: "Two")) }
        _ = try #require(await request("session.resume", in: log, after: resumes))
        cancelled.cancel()
        _ = try? await cancelled.value

        #expect(connection.opening == nil)
        #expect(connection.activeSession === first)
        #expect(connection.composer(for: first) === composer)
        #expect(composer.draft == "draft" && composer.attachments.map(\.filename) == ["a.png"])
    }

    @Test func goingBackToAWarmChatKeepsItsDraft() async throws {
        let (connection, _, _, _) = try await connect()
        let (first, bot) = try await openTwo(connection)
        connection.composer(for: bot).draft = "bot draft"
        _ = try await connection.open(SessionSummary(id: "stored-1"))
        let composer = connection.composer(for: first)
        composer.draft = "first draft"
        composer.attach(png("a.png"))

        _ = try await connection.openBotChat(profile: "coder")
        #expect(connection.composer(for: bot).draft == "bot draft")
        _ = try await connection.open(SessionSummary(id: "stored-1"))
        #expect(connection.composer(for: first) === composer)
        #expect(composer.draft == "first draft" && composer.attachments.map(\.filename) == ["a.png"])
    }

    // MARK: Sends wait for the chat's identity (M2)

    @Test func aSendWhileAGoneRuntimeSessionIsResumedGoesToTheNewOne() async throws {
        let (connection, transport, server, log) = try await connect()
        let (first, _) = try await openTwo(connection)
        let oldSID = first.sessionID
        let resumes = log.requests("session.resume").count
        server.held.withLock { $0.formUnion(["session.activate", "session.resume"]) }

        _ = try await connection.open(SessionSummary(id: "stored-1"))
        let activate = try #require(await request("session.activate", in: log))
        transport.respondError(to: activate, code: 4001, message: "session not found")
        let resume = try #require(await request("session.resume", in: log, after: resumes))

        let submits = log.requests("prompt.submit").count
        let sending = Task { try await first.send("hi") }
        try await Task.sleep(for: .milliseconds(100))
        #expect(log.requests("prompt.submit").count == submits)  // held until the chat is resumed
        #expect(occurrences(first.transcript, "hi") == 0)

        _ = server.held.withLock { $0.remove("session.resume") }
        transport.respond(to: resume, result: try #require(server.answer("session.resume", resume["params"] ?? nil)))
        try await sending.value

        let submit = try #require(log.requests("prompt.submit").last)
        #expect(submit["params"]?["session_id"] == .string(first.sessionID))
        #expect(first.sessionID != oldSID)
        await settle(first)
        #expect(await eventually { first.rereadTask == nil && !first.transcript.needsReread })
        #expect(occurrences(first.transcript, "hi") == 1)
        expectWellFormed(first.transcript)
    }

    @Test func aSendWhileABotChatFollowsItsNewTipGoesThere() async throws {
        let (connection, transport, server, log) = try await connect()
        let (_, bot) = try await openTwo(connection)
        let oldSID = bot.sessionID
        _ = try await connection.open(SessionSummary(id: "stored-1"))
        // Desktop replaced the Bot Chat meanwhile.
        server.botTip.withLock { $0 = "coder-chat-2" }
        _ = server.held.withLock { $0.insert("session.list") }
        let isLookup: (JSONValue) -> Bool = { $0["params"]?["title"] == "Bot Chat" }
        let lookups = log.requests("session.list").filter(isLookup).count

        _ = try await connection.openBotChat(profile: "coder")
        var lookup: JSONValue?
        for _ in 0..<300 where lookup == nil {
            let all = log.requests("session.list").filter(isLookup)
            lookup = all.count > lookups ? all.last : nil
            if lookup == nil { try await Task.sleep(for: .milliseconds(10)) }
        }
        let submits = log.requests("prompt.submit").count
        let sending = Task { try await bot.send("hi") }
        try await Task.sleep(for: .milliseconds(100))
        #expect(log.requests("prompt.submit").count == submits)

        _ = server.held.withLock { $0.remove("session.list") }
        for other in log.requests("session.list") where other["params"]?["title"] != "Bot Chat" {
            transport.respond(to: other, result: try #require(server.answer("session.list", other["params"] ?? nil)))
        }
        transport.respond(to: try #require(lookup), result: try #require(server.answer("session.list", lookup?["params"] ?? nil)))
        try await sending.value

        #expect(log.requests("session.resume").last?["params"]?["session_id"] == "coder-chat-2")
        #expect(bot.storedSessionID == "coder-chat-2")
        #expect(bot.sessionID != oldSID)
        #expect(log.requests("prompt.submit").last?["params"]?["session_id"] == .string(bot.sessionID))
        await settle(bot)
        #expect(await eventually { bot.rereadTask == nil && !bot.transcript.needsReread })
        #expect(occurrences(bot.transcript, "hi") == 1)
    }

    // MARK: One reconcile at a time, on the current socket

    @Test func goingBackAgainWhileTheReconcileRunsJoinsIt() async throws {
        let (connection, transport, server, log) = try await connect()
        let (first, _) = try await openTwo(connection)
        let resumes = log.requests("session.resume").count
        _ = server.held.withLock { $0.insert("session.activate") }

        _ = try await connection.open(SessionSummary(id: "stored-1"))
        let reconcile = first.revisitTask
        _ = try await connection.openBotChat(profile: "coder")
        _ = try await connection.open(SessionSummary(id: "stored-1"))
        #expect(first.revisitTask == reconcile)

        let activate = try #require(await request("session.activate", in: log))
        transport.respondError(to: activate, code: 4001, message: "session not found")
        await first.revisitTask?.value
        #expect(log.requests("session.activate").filter { $0["params"]?["session_id"] == .string(activate["params"]?["session_id"]?.stringValue ?? "") }.count == 1)
        #expect(log.requests("session.resume").count == resumes + 1)
        _ = server
    }

    @Test func aReconcileOnAReplacedSocketChangesNothing() async throws {
        let (connection, _, server, _) = try await connect()
        let (first, _) = try await openTwo(connection)
        let sid = first.sessionID
        // A socket that is not (any longer) the connection's own, answering normally.
        let stale = FakeTransport()
        let staleLog = FrameLog()
        stale.serve(log: staleLog) { method, params in server.answer(method, params) }
        var configuration = GatewayClient.Configuration()
        configuration.heartbeatInterval = nil
        let staleClient = GatewayClient(transport: stale, configuration: configuration)
        _ = try await staleClient.connect()
        let reads = server.store.queries.count

        _ = connection.revisit(first, token: connection.beginSelection(), client: staleClient)
        await first.revisitTask?.value
        await settle(first)

        #expect(staleLog.requests("session.activate").count == 1)
        #expect(server.store.queries.count == reads)  // no re-read started from its answer
        #expect(first.sessionID == sid)
        await staleClient.close()
    }

    // MARK: Picking the chat on screen

    @Test func pickingTheShownChatDuringAnotherOpenShowsItAgain() async throws {
        let (connection, transport, server, log) = try await connect()
        let first = try await connection.open(SessionSummary(id: "stored-1"))
        await settle(first)
        let resumes = log.requests("session.resume").count
        _ = server.held.withLock { $0.insert("session.resume") }

        let slow = Task { try await connection.open(SessionSummary(id: "stored-2", title: "Slow")) }
        let resume = try #require(await request("session.resume", in: log, after: resumes))
        #expect(connection.opening != nil)

        #expect(try await connection.open(SessionSummary(id: "stored-1")) === first)
        #expect(connection.opening == nil)
        #expect(connection.activeSession === first)

        transport.respond(to: resume, result: try #require(server.answer("session.resume", resume["params"] ?? nil)))
        _ = try await slow.value
        #expect(connection.activeSession === first)  // the superseded open does not take the screen
        #expect(connection.opening == nil)
    }
}
