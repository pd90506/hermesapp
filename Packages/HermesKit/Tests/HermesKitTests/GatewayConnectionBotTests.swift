import Foundation
import HermesProtocol
import Synchronization
import Testing

@testable import HermesKit

/// An exact-title `session.list` row: `_session_row_summary` with the tip's
/// `resolved_id` and `live_message_count` (`methods_session.py:118-126,526-550`).
private func botChatRow(id: String, tip: String? = nil) -> JSONValue {
    ["id": .string(id), "resolved_id": .string(tip ?? id), "title": "Bot Chat", "preview": "hello",
     "started_at": 1_700_000_000, "message_count": 2, "source": "desktop", "live_message_count": 2]
}

/// A plain listing row (`methods_session.py:575`: no `resolved_id`, no live count).
private func listRow(id: String, title: String = "", startedAt: Double = 1_700_000_000) -> JSONValue {
    ["id": .string(id), "title": .string(title), "preview": "", "started_at": .number(startedAt),
     "message_count": 2, "source": "desktop"]
}

/// Resume payload as Hermes sends it: the stored key is `session_key`, no
/// `stored_session_id` (`methods_session.py:908-911`).
private func resumed(sid: String, key: String, openRequests: JSONValue? = nil) -> JSONValue {
    var payload: [String: JSONValue] = [
        "session_id": .string(sid), "resumed": .string(key), "session_key": .string(key), "message_count": 1,
        "messages": [["role": "assistant", "text": "welcome back"]], "info": ["model": "test-model"],
        "running": false, "status": "idle", "inflight": nil,
    ]
    if let openRequests { payload["open_requests"] = openRequests }
    return .object(payload)
}

/// `session.create` result (`contracts/sessions.py:142-147`).
private func created(sid: String, key: String) -> JSONValue {
    ["session_id": .string(sid), "stored_session_id": .string(key), "message_count": 0, "messages": [],
     "info": ["model": "test-model"]]
}

/// Scripted gateway with a few profiles. `botChats` is the registry: the
/// exact-title lookup answers from it, per profile.
private final class BotServer: Sendable {
    let profiles: JSONValue
    let botChats: Mutex<[String: JSONValue]>
    let listings: [String: JSONValue]
    /// Methods the server leaves unanswered (the test answers them);
    /// `lookUpHold` stands for the exact-title Bot Chat lookup only.
    let hold: Set<String>
    /// `session.title` answers `pending: true`: the row was not written
    /// (`methods_session.py:1238-1241`).
    let titlePending: Bool
    private let counter = Mutex(0)

    init(profiles: JSONValue, botChats: [String: JSONValue] = [:], listings: [String: JSONValue] = [:],
         hold: Set<String> = [], titlePending: Bool = false) {
        self.profiles = profiles
        self.botChats = Mutex(botChats)
        self.listings = listings
        self.hold = hold
        self.titlePending = titlePending
    }

    func handle(_ method: String, _ params: JSONValue) -> JSONValue? {
        if hold.contains(method) { return nil }
        if hold.contains(lookUpHold), method == "session.list", params["title"]?.stringValue == "Bot Chat" { return nil }
        let profile = params["profile"]?.stringValue ?? "default"
        switch method {
        case "profiles.list":
            return ["profiles": profiles, "bot_mode_protocol": true, "install_id": "test"]
        case "session.list":
            if params["title"]?.stringValue == "Bot Chat" {
                let row = botChats.withLock { $0[profile] }
                return ["sessions": row.map { [$0] } ?? []]
            }
            return ["sessions": listings[profile] ?? []]
        case "session.create":
            let n = counter.withLock { $0 += 1; return $0 }
            return created(sid: "rt-new-\(n)", key: "stored-new-\(n)")
        case "session.title":
            return ["pending": .bool(titlePending), "title": params["title"] ?? ""]
        case "session.resume":
            let key = params["session_id"]?.stringValue ?? ""
            return resumed(sid: "rt-\(key)", key: key)
        case "prompt.submit":
            return ["status": "streaming"]
        default:
            return nil
        }
    }
}

private let lookUpHold = "bot-chat-lookup"

private let roster: JSONValue = [
    profileRowPayload("coder", canonical: canonicalPayload(id: "coder-chat", tip: "coder-chat-tip")),
    profileRowPayload("default", isDefault: true),
    profileRowPayload("finance"),
]

private func isBotChatLookup(_ frame: JSONValue) -> Bool { frame["params"]?["title"] == "Bot Chat" }

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct GatewayConnectionBotTests {
    private func connect(_ server: BotServer, log: FrameLog, epoch: String = "E1",
                         extra: [FakeTransport] = []) async throws -> (GatewayConnection, FakeTransport) {
        let transport = FakeTransport()
        transport.serve(epoch: epoch, log: log, server.handle)
        var configuration = GatewayClient.Configuration()
        configuration.heartbeatInterval = nil
        let connection = GatewayConnection(configuration: configuration, backoff: { _ in .milliseconds(1) })
        try await connection.connect(using: FakeConnector([transport] + extra))
        try await connection.refreshBots()
        return (connection, transport)
    }

    @Test func rosterListsEveryProfileDefaultFirst() async throws {
        let (connection, _) = try await connect(BotServer(profiles: roster), log: FrameLog())
        #expect(connection.bots.map(\.name) == ["default", "coder", "finance"])
    }

    @Test func botRowOpensTheChatFoundByTitleOnItsProfile() async throws {
        let log = FrameLog()
        let server = BotServer(profiles: roster, botChats: ["coder": botChatRow(id: "coder-chat", tip: "coder-chat-tip")])
        let (connection, _) = try await connect(server, log: log)

        let session = try await connection.openBotChat(profile: "coder")

        #expect(log.requests("session.list").filter(isBotChatLookup).first?["params"] ==
                ["profile": "coder", "title": "Bot Chat", "include_hidden": true, "limit": 200])
        // The lineage tip is opened, on the bot's profile.
        #expect(log.requests("session.resume").first?["params"] == ["session_id": "coder-chat-tip", "profile": "coder",
                                                                       "omit_messages": true, "defer_history": true])
        #expect(log.requests("session.create").isEmpty)
        #expect(connection.activeSession === session)
        #expect(session.kind == .botChat && session.profile == "coder")
        #expect(session.storedSessionID == "coder-chat-tip")
        #expect(session.transcript.items.map(\.text) == ["welcome back"])
    }

    @Test func everyOpenResolvesTheRegistryAgain() async throws {
        let log = FrameLog()
        let server = BotServer(profiles: roster, botChats: ["coder": botChatRow(id: "coder-chat"),
                                                            "finance": botChatRow(id: "fin-chat")])
        let (connection, _) = try await connect(server, log: log)

        try await connection.openBotChat(profile: "coder")
        try await connection.openBotChat(profile: "finance")
        // The registry moved (e.g. Desktop compressed the chat): the next open follows it.
        server.botChats.withLock { $0["coder"] = botChatRow(id: "coder-chat", tip: "coder-chat-2") }
        let again = try await connection.openBotChat(profile: "coder")
        // Shown before, so it is back on screen at once; the lookup by name runs in
        // the background reconcile (`GatewayConnection+Revisit`) and follows the tip.
        await again.revisitTask?.value

        let lookups = log.requests("session.list").filter(isBotChatLookup).map { $0["params"]?["profile"] }
        #expect(lookups == ["coder", "finance", "coder"])
        #expect(again.storedSessionID == "coder-chat-2")
    }

    @Test func createsTheBotChatOnlyWhenTheRegistryConfirmsThereIsNone() async throws {
        let log = FrameLog()
        let (connection, _) = try await connect(BotServer(profiles: roster), log: log)

        let session = try await connection.openBotChat(profile: "finance")

        #expect(log.requests("session.create").map { $0["params"] } ==
                [["profile": "finance", "title": "Bot Chat", "hidden": true, "follow_profile_config": true]])
        // Titled eagerly on the runtime id, so the row exists under its name right away.
        #expect(log.requests("session.title").first?["params"] == ["session_id": "rt-new-1", "title": "Bot Chat"])
        #expect(log.requests("prompt.submit").isEmpty)  // no intro is sent on the user's behalf
        #expect(session.kind == .botChat && session.storedSessionID == "stored-new-1")
        #expect(connection.activeSession === session)
    }

    @Test func doubleClickCreatesOneBotChat() async throws {
        let log = FrameLog()
        let (connection, _) = try await connect(BotServer(profiles: roster), log: log)

        async let first = connection.openBotChat(profile: "finance")
        async let second = connection.openBotChat(profile: "finance")
        let (a, b) = try await (first, second)

        #expect(a === b)
        #expect(log.requests("session.create").count == 1)
        #expect(log.requests("session.list").filter(isBotChatLookup).count == 1)
    }

    @Test func failedLookupNeverCreates() async throws {
        let log = FrameLog()
        let (connection, transport) = try await connect(BotServer(profiles: roster, hold: [lookUpHold]), log: log)

        let open = Task { try await connection.openBotChat(profile: "finance") }
        #expect(await eventually { log.requests("session.list").contains(where: isBotChatLookup) })
        let lookup = try #require(log.requests("session.list").first(where: isBotChatLookup))
        transport.respondError(to: lookup, code: 5006, message: "database is locked")

        await #expect(throws: BotChatError.registryUnavailable(profile: "finance", detail: "database is locked")) {
            try await open.value
        }
        #expect(log.requests("session.create").isEmpty)
        #expect(connection.activeSession == nil)
    }

    @Test func emptyLookupForABotKnownToHaveAChatNeverCreates() async throws {
        let log = FrameLog()
        // The roster reports coder's canonical_session, but the lookup answers empty.
        let (connection, _) = try await connect(BotServer(profiles: roster), log: log)

        await #expect(throws: BotChatError.registryUnconfirmed(profile: "coder")) {
            try await connection.openBotChat(profile: "coder")
        }
        #expect(log.requests("session.create").isEmpty)
    }

    @Test func titleConflictAdoptsTheExistingBotChat() async throws {
        let log = FrameLog()
        let server = BotServer(profiles: roster, hold: ["session.title"])
        let (connection, transport) = try await connect(server, log: log)

        let open = Task { try await connection.openBotChat(profile: "finance") }
        #expect(await eventually { !log.requests("session.title").isEmpty })
        // Another client (Desktop) created finance's Bot Chat since our lookup.
        server.botChats.withLock { $0["finance"] = botChatRow(id: "fin-desktop") }
        transport.respondError(to: try #require(log.requests("session.title").first), code: 4022,
                               message: "Title 'Bot Chat' is already in use by session fin-desktop")

        let session = try await open.value
        #expect(session.storedSessionID == "fin-desktop")
        #expect(log.requests("session.resume").first?["params"] == ["session_id": "fin-desktop", "profile": "finance",
                                                                       "omit_messages": true, "defer_history": true])
        #expect(log.requests("session.create").count == 1)
        #expect(log.requests("prompt.submit").isEmpty)
    }

    @Test func unknownProfileSurfacesTheGatewayError() async throws {
        let log = FrameLog()
        let (connection, transport) = try await connect(BotServer(profiles: roster, hold: [lookUpHold]), log: log)

        let open = Task { try await connection.openBotChat(profile: "ghost") }
        #expect(await eventually { log.requests("session.list").contains(where: isBotChatLookup) })
        // `rpc_dispatch.py:35-36` / `server.py:561-577`.
        transport.respondError(to: try #require(log.requests("session.list").first(where: isBotChatLookup)),
                               code: 4064, message: "Profile 'ghost' does not exist.")
        await #expect(throws: BotChatError.registryUnavailable(profile: "ghost", detail: "Profile 'ghost' does not exist.")) {
            try await open.value
        }
    }

    @Test func theLatestOpenTakesTheScreen() async throws {
        let log = FrameLog()
        let server = BotServer(profiles: roster, botChats: ["coder": botChatRow(id: "coder-chat"),
                                                            "finance": botChatRow(id: "fin-chat")],
                               hold: ["session.resume"])
        let (connection, transport) = try await connect(server, log: log)

        let slow = Task { try await connection.openBotChat(profile: "coder") }
        #expect(await eventually { log.requests("session.resume").count == 1 })
        let fast = Task { try await connection.openBotChat(profile: "finance") }
        #expect(await eventually { log.requests("session.resume").count == 2 })
        let resumes = log.requests("session.resume")
        transport.respond(to: resumes[1], result: resumed(sid: "rt-fin", key: "fin-chat"))
        let finance = try await fast.value
        // The losing open's chat has an approval waiting (`open_requests`, `server_requests.py:15-18`).
        transport.respond(to: resumes[0], result: resumed(sid: "rt-coder", key: "coder-chat", openRequests: [
            ["id": "srq-9", "method": "approval",
             "params": ["session_id": "rt-coder", "request_id": "a9", "command": "ls"]],
        ]))
        _ = try await slow.value

        #expect(connection.activeSession === finance)
        // Not on screen, but its request is still delivered and shows on coder's row.
        #expect(await eventually { connection.otherSessionRequests.map(\.id) == ["srq-9"] })
        let coder = try #require(connection.bots.first { $0.name == "coder" })
        #expect(connection.activity(for: coder) == .waitingForYou)
    }

    @Test func titleFailureOtherThanAConflictFailsClosed() async throws {
        let log = FrameLog()
        let (connection, transport) = try await connect(BotServer(profiles: roster, hold: ["session.title"]), log: log)

        let open = Task { try await connection.openBotChat(profile: "finance") }
        #expect(await eventually { !log.requests("session.title").isEmpty })
        // `methods_session.py:1244-1245`: any other storage error is 5007.
        transport.respondError(to: try #require(log.requests("session.title").first), code: 5007,
                               message: "database is locked")

        await #expect(throws: BotChatError.notRegistered(profile: "finance", detail: "database is locked")) {
            try await open.value
        }
        // The unregistered lazy session is never used as the Bot Chat.
        #expect(connection.activeSession == nil)
        #expect(log.requests("session.resume").isEmpty && log.requests("prompt.submit").isEmpty)
    }

    @Test func pendingTitleFailsClosed() async throws {
        let log = FrameLog()
        let (connection, _) = try await connect(BotServer(profiles: roster, titlePending: true), log: log)

        await #expect(throws: BotChatError.notRegistered(profile: "finance",
                                                         detail: "the gateway did not save the chat yet")) {
            try await connection.openBotChat(profile: "finance")
        }
        #expect(connection.activeSession == nil)
    }

    // MARK: Side chats and History

    @Test func sideChatIsAPlainSessionOnTheProfile() async throws {
        let log = FrameLog()
        let (connection, _) = try await connect(BotServer(profiles: roster), log: log)

        let side = try await connection.newSideChat(profile: "coder")

        #expect(log.requests("session.create").first?["params"] == ["profile": "coder"])
        #expect(log.requests("session.title").isEmpty)
        #expect(side.kind == .sideChat && side.profile == "coder")
        #expect(connection.activeSession === side)
    }

    /// New chat has no Sessions row until its first message, so New chat again goes
    /// back to it, with what was typed, instead of starting a blank one.
    @Test func newChatComesBackWithItsDraftUntilSent() async throws {
        let log = FrameLog()
        let (connection, _) = try await connect(BotServer(profiles: roster), log: log)

        let side = try await connection.newSideChat(profile: "coder")
        connection.composer(for: side).draft = "half typed"
        _ = try await connection.newSideChat(profile: "finance")  // another chat on screen
        let again = try await connection.newSideChat(profile: "coder")

        #expect(again === side && connection.activeSession === side)
        #expect(connection.composer(for: again).draft == "half typed")
        #expect(log.requests("session.create").count == 2)
        // On screen already: New chat leaves it there.
        #expect(try await connection.newSideChat(profile: "coder") === side)
        #expect(log.requests("session.create").count == 2)
    }

    @Test func newChatKeepsItsDraftPastTheWarmCache() async throws {
        let (connection, _) = try await connect(BotServer(profiles: roster), log: FrameLog())

        let side = try await connection.newSideChat(profile: "coder")
        connection.composer(for: side).draft = "still here"
        for _ in 0..<GatewayConnection.warmChatLimit {
            // Each a sent chat, so the next New chat on finance is a new one.
            let other = try await connection.newSideChat(profile: "finance")
            try await other.send("hi")
        }
        #expect(!connection.warmSessions.contains { $0 === side })

        let again = try await connection.newSideChat(profile: "coder")
        #expect(again === side)
        #expect(connection.composer(for: again).draft == "still here")
    }

    @Test func newChatAfterASendStartsAnother() async throws {
        let log = FrameLog()
        let (connection, _) = try await connect(BotServer(profiles: roster), log: log)

        let side = try await connection.newSideChat(profile: "coder")
        try await side.send("hello")
        let next = try await connection.newSideChat(profile: "coder")

        #expect(next !== side && connection.activeSession === next)
        #expect(log.requests("session.create").count == 2)
    }

    @Test func newChatWhoseRuntimeWasReclaimedIsReplacedWithItsDraft() async throws {
        let log = FrameLog()
        let (connection, _) = try await connect(BotServer(profiles: roster), log: log)

        let side = try await connection.newSideChat(profile: "coder")
        connection.composer(for: side).draft = "keep me"
        side.markRuntimeGone()
        let next = try await connection.newSideChat(profile: "coder")

        #expect(next !== side && connection.activeSession === next)
        #expect(connection.composer(for: next).draft == "keep me")
        #expect(log.requests("session.create").count == 2)
    }

    @Test func newSessionsCarryTheChosenSource() async throws {
        let log = FrameLog()
        let (connection, _) = try await connect(BotServer(profiles: roster), log: log)
        connection.sourceSettings.newSessionSource = "desktop"

        try await connection.newSideChat(profile: "coder")
        try await connection.openBotChat(profile: "finance")

        #expect(log.requests("session.create").map { $0["params"]?["source"] } == ["desktop", "desktop"])
    }

    @Test func listLeavesOutRowsOfHiddenSources() async throws {
        let rows: JSONValue = [
            listRow(id: "from-desktop"),
            ["id": "from-telegram", "title": "", "preview": "", "started_at": 1_700_000_000,
             "message_count": 2, "source": "telegram"],
            ["id": "no-source", "title": "", "preview": "", "started_at": 1_700_000_000, "message_count": 2],
        ]
        let (connection, _) = try await connect(BotServer(profiles: roster, listings: ["coder": rows]), log: FrameLog())
        connection.selectListProfile("coder")
        await connection.refreshSessionList()
        connection.sourceSettings.setHidden(true, "Telegram")

        #expect(connection.history.map(\.summary.id) == ["from-desktop", "from-telegram", "no-source"])
        #expect(connection.visibleHistory.map(\.summary.id) == ["from-desktop", "no-source"])
        #expect(connection.historySources == ["desktop", "telegram"])
    }

    @Test func titleEventRenamesTheHistoryRow() async throws {
        let server = BotServer(profiles: roster, listings: ["coder": [listRow(id: "coder-side", title: "Refactor")]])
        let (connection, transport) = try await connect(server, log: FrameLog())
        connection.selectListProfile("coder")
        await connection.refreshSessionList()
        try await connection.open(try #require(connection.history.first))

        // `session.title` carries the STORED id in its payload (`prompt_turn.py:795-797`).
        transport.sendEvent("session.title", sessionID: "rt-coder-side",
                            payload: ["session_id": "coder-side", "title": "Big refactor"])

        #expect(await eventually { connection.history.first?.summary.title == "Big refactor" })
    }

    // MARK: Reconnect and activity

    @Test func coldReconnectResumesTheBotChatOnItsProfile() async throws {
        let log = FrameLog()
        let secondLog = FrameLog()
        let server = BotServer(profiles: roster, botChats: ["coder": botChatRow(id: "coder-chat")])
        let second = FakeTransport()
        second.serve(epoch: "E2", log: secondLog, server.handle)
        let (connection, first) = try await connect(server, log: log, extra: [second])
        let session = try await connection.openBotChat(profile: "coder")

        first.serverDrops()

        #expect(await eventually { connection.state == .connected && !secondLog.requests("session.resume").isEmpty })
        // Looked up by name on the new socket first, then resumed.
        #expect(secondLog.requests("session.list").contains(where: isBotChatLookup))
        #expect(secondLog.requests("session.resume").first?["params"] == ["session_id": "coder-chat", "profile": "coder",
                                                                             "omit_messages": true, "defer_history": true])
        #expect(connection.activeSession === session)
    }

    @Test func coldReconnectFollowsABotChatReplacedMeanwhile() async throws {
        let secondLog = FrameLog()
        let server = BotServer(profiles: roster, botChats: ["coder": botChatRow(id: "coder-chat")])
        let second = FakeTransport()
        second.serve(epoch: "E2", log: secondLog, server.handle)
        let (connection, first) = try await connect(server, log: FrameLog(), extra: [second])
        let session = try await connection.openBotChat(profile: "coder")

        // While offline, Desktop retired the chat and made a new one.
        server.botChats.withLock { $0["coder"] = botChatRow(id: "coder-chat-v2") }
        first.serverDrops()

        #expect(await eventually { connection.state == .connected && !secondLog.requests("session.resume").isEmpty })
        #expect(secondLog.requests("session.resume").first?["params"] == ["session_id": "coder-chat-v2", "profile": "coder",
                                                                             "omit_messages": true, "defer_history": true])
        #expect(connection.activeSession === session && session.storedSessionID == "coder-chat-v2")
    }

    @Test func coldReconnectDropsABotChatThatIsGone() async throws {
        let secondLog = FrameLog()
        let server = BotServer(profiles: roster, botChats: ["coder": botChatRow(id: "coder-chat")])
        let second = FakeTransport()
        second.serve(epoch: "E2", log: secondLog, server.handle)
        let (connection, first) = try await connect(server, log: FrameLog(), extra: [second])
        try await connection.openBotChat(profile: "coder")

        server.botChats.withLock { $0["coder"] = nil }
        first.serverDrops()

        #expect(await eventually { connection.state == .connected && connection.activeSession == nil })
        #expect(secondLog.requests("session.resume").isEmpty)
        #expect(secondLog.requests("session.create").isEmpty)
    }

    /// The profile was deleted (4064, `server.py:561-577`) or the row is gone
    /// (4007, `methods_session.py:833`): one attempt, then stay connected without it.
    @Test(arguments: [4007, 4064])
    func reconnectDropsASessionTheServerCannotResume(code: Int) async throws {
        let secondLog = FrameLog()
        let server = BotServer(profiles: roster)
        let second = FakeTransport()
        second.serve(epoch: "E2", log: secondLog) { method, params in
            method == "session.resume" ? nil : server.handle(method, params)
        }
        let (connection, first) = try await connect(server, log: FrameLog(), extra: [second])
        try await connection.newSideChat(profile: "coder")

        first.serverDrops()
        #expect(await eventually { !secondLog.requests("session.resume").isEmpty })
        second.respondError(to: try #require(secondLog.requests("session.resume").first), code: code,
                            message: "gone")

        #expect(await eventually { connection.state == .connected && connection.activeSession == nil })
        #expect(secondLog.requests("session.resume").count == 1)
    }

    /// Only the chat on screen reports a live turn: events of background
    /// sessions are not tracked (Desktop's busy state follows focus too,
    /// `row-helpers.ts` `botWorkingMood`). Background chats show their requests.
    @Test func activityShowsTheOnScreenTurnAndBackgroundRequests() async throws {
        let log = FrameLog()
        let server = BotServer(profiles: roster, botChats: ["coder": botChatRow(id: "coder-chat"),
                                                            "finance": botChatRow(id: "fin-chat")])
        let (connection, transport) = try await connect(server, log: log)
        let coder = try #require(connection.bots.first { $0.name == "coder" })
        let finance = try #require(connection.bots.first { $0.name == "finance" })

        try await connection.openBotChat(profile: "coder")
        try await connection.openBotChat(profile: "finance")
        #expect(connection.activity(for: coder) == .idle)

        // coder's chat (runtime rt-coder-chat) is in the background and asks for approval.
        transport.serverSends(["jsonrpc": "2.0", "id": "srq-1", "method": "approval",
                               "params": ["session_id": "rt-coder-chat", "request_id": "a1", "command": "ls"]])
        #expect(await eventually { connection.activity(for: coder) == .waitingForYou })

        let active = try #require(connection.activeSession)
        try await active.send("go")
        #expect(connection.activity(for: finance) == .working)
    }
}
