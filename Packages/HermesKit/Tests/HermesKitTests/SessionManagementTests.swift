import Foundation
import HermesProtocol
import Synchronization
import Testing

@testable import HermesKit

/// A gateway with bots `coder` (has a Bot Chat `coder-chat`) and `finance`.
/// `listings` is each profile's plain `session.list`.
private func botGateway(listings: [String: JSONValue] = [:]) -> ScriptedGateway {
    let gateway = ScriptedGateway()
    let created = Mutex(0)
    gateway.on("profiles.list", result: [
        "profiles": [profileRowPayload("default", isDefault: true),
                     profileRowPayload("coder", canonical: canonicalPayload(id: "coder-chat")),
                     profileRowPayload("finance")],
        "bot_mode_protocol": true, "install_id": "test",
    ])
    gateway.on("session.list") { params in
        let profile = params["profile"]?.stringValue ?? "default"
        if params["title"]?.stringValue == "Bot Chat" {
            // Exact-title registry row (`methods_session.py:526-559`).
            return .result(["sessions": profile == "coder"
                ? [["id": "coder-chat", "resolved_id": "coder-chat", "title": "Bot Chat", "preview": "",
                    "started_at": 1_700_000_000, "message_count": 2, "source": "desktop"]]
                : []])
        }
        return .result(["sessions": listings[profile] ?? []])
    }
    gateway.on("session.create") { _ in
        let n = created.withLock { $0 += 1; return $0 }
        return .result(createdPayload(sid: "rt-side-\(n)", key: "side-\(n)"))
    }
    gateway.on("session.resume") { params in
        let key = params["session_id"]?.stringValue ?? ""
        return .result(resumedPayload(sid: "rt-\(key)", key: key))
    }
    gateway.on("session.title") { params in .result(["pending": false, "title": params["title"] ?? ""]) }
    gateway.on("session.archive") { params in .result(["archived": params["archived"] ?? true,
                                                       "session_key": params["session_id"] ?? ""]) }
    gateway.on("session.delete") { params in .result(["deleted": params["session_id"] ?? ""]) }
    gateway.on("session.close", result: ["closed": true])
    gateway.on("session.interrupt", result: ["status": "interrupted"])
    return gateway.withDefaults()
}

private let mutating: Set<String> = ["session.title", "session.archive", "session.delete", "session.close",
                                     "session.interrupt", "session.branch_stored"]

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct SessionManagementTests {
    private func connect(_ gateway: ScriptedGateway) async throws -> GatewayConnection {
        let connection = try await gateway.connect()
        try await connection.refreshBots()
        connection.selectListProfile("coder")
        await connection.refreshSessionList()
        return connection
    }

    // MARK: Bot Chat protection

    @Test func theBotChatCannotBeRenamedArchivedOrDeleted() async throws {
        let gateway = botGateway()
        let connection = try await connect(gateway)
        let botChat = try await connection.openBotChat(profile: "coder")
        #expect(connection.isProtected(botChat))

        await #expect(throws: SessionActionError.botChatProtected) { try await connection.rename(botChat, to: "Mine") }
        await #expect(throws: SessionActionError.botChatProtected) { try await connection.archive(botChat) }
        await #expect(throws: SessionActionError.botChatProtected) { try await connection.delete(botChat) }
        // `/title` goes through the same guard.
        await #expect(throws: SessionActionError.botChatProtected) { _ = try await botChat.runSlash("/title Mine") }

        #expect(gateway.log.all.allSatisfy { !mutating.contains($0["method"]?.stringValue ?? "") })
        #expect(connection.activeSession === botChat)
    }

    /// A Bot Chat row reached through History or the launch-profile list (by
    /// title, or by the roster's canonical id) is protected too.
    @Test func botChatRowsAreProtectedWhereverTheyShowUp() async throws {
        let gateway = botGateway()
        let connection = try await connect(gateway)
        let visible = HistoryEntry(profile: "finance", summary: SessionSummary(id: "f1", title: "Bot Chat"))
        let byID = HistoryEntry(profile: "coder", summary: SessionSummary(id: "coder-chat", title: "renamed?"))
        let otherBotsID = HistoryEntry(profile: "finance", summary: SessionSummary(id: "coder-chat"))

        #expect(connection.isProtected(visible) && connection.isProtected(byID))
        #expect(!connection.isProtected(otherBotsID))  // stored ids are per profile db
        await #expect(throws: SessionActionError.botChatProtected) { try await connection.delete(visible) }
        await #expect(throws: SessionActionError.botChatProtected) { try await connection.archive(byID) }
        await #expect(throws: SessionActionError.botChatProtected) { try await connection.unarchive(byID) }
        await #expect(throws: SessionActionError.botChatProtected) { try await connection.fork(visible) }

        let launch = try await connection.open(SessionSummary(id: "coder-chat", title: "Bot Chat"))
        #expect(connection.isProtected(launch))
        #expect(gateway.log.all.allSatisfy { !mutating.contains($0["method"]?.stringValue ?? "") })
    }

    /// "/new inside a bot's canonical forever-chat would fork the relationship":
    /// Desktop compacts instead (`plugins/hermes-bots/plugin.tsx:765-800`). A side
    /// chat keeps `/new` as a client action.
    @Test func newInABotChatCompressesInstead() async throws {
        let gateway = botGateway()
        // `_compress_live` result, no-op summary (`manual_compression_feedback.py:68-81`).
        gateway.on("session.compress", result: [
            "status": "compressed", "removed": 0, "before_messages": 2, "after_messages": 2,
            "summary": ["noop": true, "aborted": false, "headline": "No changes from compression: 2 messages",
                        "token_line": "Approx request size: ~800 tokens (unchanged)", "note": nil],
            "usage": [:], "info": ["model": "test-model"], "messages": [],
        ])
        let connection = try await connect(gateway)
        let botChat = try await connection.openBotChat(profile: "coder")

        for command in ["/new", "/reset", "/clear please"] {
            let outcome = try await botChat.runSlash(command)
            #expect(outcome == .output("No changes from compression: 2 messages\nApprox request size: ~800 tokens (unchanged)"))
        }
        #expect(gateway.params("session.compress").count == 3)
        #expect(gateway.params("session.create").isEmpty)
        #expect(connection.activeSession === botChat)

        let side = try await connection.newSideChat(profile: "coder")
        #expect(try await side.runSlash("/new") == .clientAction(name: "new", argument: ""))
    }

    @Test func noSessionMayTakeTheBotChatTitle() async throws {
        let gateway = botGateway()
        let connection = try await connect(gateway)
        let side = try await connection.newSideChat(profile: "finance")

        await #expect(throws: SessionActionError.reservedTitle) { try await connection.rename(side, to: " bot chat ") }
        await #expect(throws: SessionActionError.emptyTitle) { try await connection.rename(side, to: "  ") }
        #expect(gateway.params("session.title").isEmpty)
    }

    // MARK: Rename

    @Test func renamesTheOpenSideChat() async throws {
        let gateway = botGateway(listings: ["coder": [sessionRow(id: "side-1")]])
        let connection = try await connect(gateway)
        let side = try await connection.newSideChat(profile: "coder")
        connection.selectListProfile("coder")
        await connection.refreshSessionList()

        try await connection.rename(side, to: "Refactor plan")

        #expect(gateway.params("session.title") == [["session_id": "rt-side-1", "title": "Refactor plan"]])
        #expect(side.title == "Refactor plan")
        #expect(connection.history.first { $0.summary.id == "side-1" }?.summary.title == "Refactor plan")
    }

    @Test func aHistoryRowIsRenamedOnlyWhileOpen() async throws {
        let gateway = botGateway(listings: ["coder": [sessionRow(id: "old", title: "Old")]])
        let connection = try await connect(gateway)
        let entry = try #require(connection.history.first)

        await #expect(throws: SessionActionError.notOpen) { try await connection.rename(entry, to: "New") }

        try await connection.open(entry)
        try await connection.rename(entry, to: "New")
        #expect(gateway.params("session.title") == [["session_id": "rt-old", "title": "New"]])
        #expect(connection.history.first?.summary.title == "New")
    }

    // MARK: Archive

    @Test func archivesAHistoryRowByItsStoredIDOnItsProfile() async throws {
        let gateway = botGateway(listings: ["coder": [sessionRow(id: "old", title: "Old"), sessionRow(id: "keep")]])
        let connection = try await connect(gateway)
        let entry = try #require(connection.history.first { $0.summary.id == "old" })

        try await connection.archive(entry)

        #expect(gateway.params("session.archive") == [["session_id": "old", "archived": true, "profile": "coder"]])
        #expect(connection.history.map(\.summary.id) == ["keep"])

        try await connection.unarchive(entry)
        #expect(gateway.params("session.archive").last == ["session_id": "old", "archived": false, "profile": "coder"])
    }

    @Test func archivingTheOpenChatUsesItsRuntimeID() async throws {
        let gateway = botGateway()
        let connection = try await connect(gateway)
        let side = try await connection.newSideChat(profile: "finance")

        try await connection.archive(side)

        // Covers a chat with no stored row yet (`pending_archived`, `methods_session.py:1268-1271`).
        #expect(gateway.params("session.archive") == [["session_id": "rt-side-1", "archived": true, "profile": "finance"]])
        #expect(connection.activeSession === side)
    }

    // MARK: Delete

    @Test func deletingTheOpenChatClosesItFirst() async throws {
        let gateway = botGateway(listings: ["coder": [sessionRow(id: "side-1")]])
        let connection = try await connect(gateway)
        let side = try await connection.newSideChat(profile: "coder")
        try await side.send("hi")  // a running turn is interrupted first

        try await connection.delete(side)

        let order = gateway.log.all.compactMap { $0["method"]?.stringValue }.filter(mutating.contains)
        #expect(order == ["session.interrupt", "session.close", "session.delete"])
        #expect(gateway.params("session.close") == [["session_id": "rt-side-1"]])
        #expect(gateway.params("session.delete") == [["session_id": "side-1", "profile": "coder"]])
        #expect(connection.activeSession == nil)
        #expect(connection.history.isEmpty)
    }

    /// A chat this app opened earlier is still live on the gateway, which refuses
    /// to delete it (4023, `methods_session.py:1185-1186`): close it first.
    @Test func deletingAChatOpenedEarlierClosesItsRuntime() async throws {
        let gateway = botGateway(listings: ["coder": [sessionRow(id: "old", title: "Old")]])
        let connection = try await connect(gateway)
        let entry = try #require(connection.history.first)
        try await connection.open(entry)
        try await connection.openBotChat(profile: "coder")

        try await connection.delete(entry)

        #expect(gateway.params("session.close") == [["session_id": "rt-old"]])
        #expect(gateway.params("session.delete") == [["session_id": "old", "profile": "coder"]])
    }

    @Test func aChatWithoutARowIsDeletedQuietly() async throws {
        let gateway = botGateway()
        gateway.on("session.delete") { _ in .error(code: 4007, message: "session not found") }
        let connection = try await connect(gateway)
        let side = try await connection.newSideChat(profile: "finance")

        try await connection.delete(side)
        #expect(connection.activeSession == nil)
    }

    @Test func aChatLiveElsewhereIsNotDeleted() async throws {
        let gateway = botGateway(listings: ["coder": [sessionRow(id: "busy")]])
        gateway.on("session.delete") { _ in .error(code: 4023, message: "cannot delete an active session") }
        let connection = try await connect(gateway)

        await #expect(throws: RPCError.self) { try await connection.delete(try #require(connection.history.first)) }
        #expect(connection.history.map(\.summary.id) == ["busy"])
    }

    // MARK: Fork

    /// The gateway copies the row server-side and saves the copy under the parent's
    /// next lineage title; the app lists it and opens it.
    @Test func forkCopiesARowAndOpensTheCopy() async throws {
        let gateway = botGateway()
        let branched = Mutex(false)
        gateway.on("session.list") { params in
            guard params["title"] == nil, params["profile"]?.stringValue == "coder" else { return .result(["sessions": []]) }
            let copy = branched.withLock { $0 } ? [sessionRow(id: "fork-1", title: "Plan #2")] : []
            return .result(["sessions": .array(copy + [sessionRow(id: "old", title: "Plan")])])
        }
        gateway.on("session.branch_stored") { _ in
            branched.withLock { $0 = true }
            // `_create_session(copy_parent_history=True)`: no `messages` (`methods_session.py:474-481`).
            return .result(["session_id": "rt-fork-1", "stored_session_id": "fork-1", "message_count": 2,
                            "messages_omitted": true, "info": ["model": "test-model"]])
        }
        let connection = try await connect(gateway)
        connection.selectListProfile("coder")
        await connection.refreshSessionList()
        let entry = try #require(connection.history.first { $0.summary.id == "old" })

        let copy = try await connection.fork(entry)

        #expect(gateway.params("session.branch_stored") == [["parent_session_id": "old", "profile": "coder"]])
        #expect(gateway.params("session.resume").last?["session_id"] == "fork-1")
        #expect(copy.storedSessionID == "fork-1" && copy.title == "Plan #2")
        #expect(connection.activeSession === copy)
        #expect(connection.history.map(\.summary.id) == ["fork-1", "old"])
    }

    /// The copy is stored under the source new chats carry, as Desktop's (`desktop`).
    @Test func aForkCarriesTheChosenSource() async throws {
        let gateway = botGateway(listings: ["coder": [sessionRow(id: "old", title: "Plan")]])
        gateway.on("session.branch_stored") { _ in
            .result(["session_id": "rt-fork-1", "stored_session_id": "fork-1", "message_count": 2,
                     "messages_omitted": true, "info": ["model": "test-model"]])
        }
        let connection = try await connect(gateway)
        connection.sourceSettings.newSessionSource = "desktop"

        try await connection.fork(try #require(connection.history.first))

        #expect(gateway.params("session.branch_stored") == [["parent_session_id": "old", "profile": "coder",
                                                               "source": "desktop"]])
    }

    @Test func aChatWithNothingToCopyIsNotForked() async throws {
        let gateway = botGateway(listings: ["coder": [sessionRow(id: "empty")]])
        gateway.on("session.branch_stored") { _ in .error(code: 4008, message: "send a message first") }
        let connection = try await connect(gateway)

        await #expect(throws: RPCError.self) { try await connection.fork(try #require(connection.history.first)) }
        #expect(connection.activeSession == nil)
    }
}

@Suite struct SessionPinsTests {
    private let server = UUID()
    private func row(_ id: String, _ profile: String = "coder") -> HistoryEntry {
        HistoryEntry(profile: profile, summary: SessionSummary(id: id))
    }

    @Test func pinnedRowsComeFirstInListOrder() {
        var pins = SessionPins()
        pins.setPinned(true, row("c"), on: server)
        pins.setPinned(true, row("a"), on: server)
        let split = pins.split([row("a"), row("b"), row("c")], on: server)
        #expect(split.pinned.map(\.summary.id) == ["a", "c"])
        #expect(split.others.map(\.summary.id) == ["b"])

        pins.setPinned(false, row("a"), on: server)
        #expect(!pins.isPinned(row("a"), on: server) && pins.isPinned(row("c"), on: server))
    }

    /// Stored ids are per profile db, profile names per server.
    @Test func aPinBelongsToOneServerAndProfile() throws {
        var pins = SessionPins()
        let other = UUID()
        pins.setPinned(true, row("x"), on: server)
        #expect(!pins.isPinned(row("x", "finance"), on: server))
        #expect(!pins.isPinned(row("x"), on: other))

        let decoded = try JSONDecoder().decode(SessionPins.self, from: JSONEncoder().encode(pins))
        #expect(decoded.isPinned(row("x"), on: server))

        pins.forgetServer(server)
        #expect(!pins.isPinned(row("x"), on: server))
    }
}

@Suite struct ProfileChatsTests {
    private let server = UUID()
    private func row(_ id: String, _ profile: String = "coder", resolved: String? = nil) -> HistoryEntry {
        var summary = SessionSummary(id: id)
        summary.resolvedID = resolved
        return HistoryEntry(profile: profile, summary: summary)
    }

    @Test func noRecordShowsTheBotChat() {
        let chats = ProfileChats()
        #expect(chats.restore("coder", on: server, history: nil) == .botChat)
        #expect(chats.restore("coder", on: server, history: [row("a")]) == .botChat)
    }

    @Test func aRememberedBotChatNeedsNoList() {
        var chats = ProfileChats()
        chats.record(.session("a"), of: "coder", on: server)
        chats.record(.botChat, of: "coder", on: server)
        #expect(chats.restore("coder", on: server, history: nil) == .botChat)
    }

    @Test func aRememberedSessionWaitsForTheListThenShowsIt() {
        var chats = ProfileChats()
        chats.record(.session("b"), of: "coder", on: server)
        #expect(chats.restore("coder", on: server, history: nil) == .waitForList)
        #expect(chats.restore("coder", on: server, history: [row("a"), row("b")]) == .session(row("b")))
        // Known by the id it resolved to.
        #expect(chats.restore("coder", on: server, history: [row("x", resolved: "b")]) == .session(row("x", resolved: "b")))
    }

    @Test func aSessionThatIsGoneShowsTheBotChat() {
        var chats = ProfileChats()
        chats.record(.session("b"), of: "coder", on: server)
        #expect(chats.restore("coder", on: server, history: []) == .botChat)
        #expect(chats.restore("coder", on: server, history: [row("b", "finance")]) == .botChat)
    }

    /// A list read before the profile was picked can be out of date.
    @Test func anOlderListCanOnlyConfirmTheSession() {
        var chats = ProfileChats()
        chats.record(.session("b"), of: "coder", on: server)
        #expect(chats.restore("coder", on: server, history: [row("b")], isCurrent: false) == .session(row("b")))
        #expect(chats.restore("coder", on: server, history: [row("a")], isCurrent: false) == .waitForList)
    }

    /// Profile names are per server; records survive a relaunch and go with their server.
    @Test func aRecordBelongsToOneServerAndProfile() throws {
        var chats = ProfileChats()
        let other = UUID()
        chats.record(.session("b"), of: "coder", on: server)
        #expect(chats.chat(of: "finance", on: server) == nil)
        #expect(chats.chat(of: "coder", on: other) == nil)

        let decoded = try JSONDecoder().decode(ProfileChats.self, from: JSONEncoder().encode(chats))
        #expect(decoded.chat(of: "coder", on: server) == .session("b"))

        chats.forgetServer(server)
        #expect(chats.chat(of: "coder", on: server) == nil)
    }
}
