import Foundation
import HermesProtocol
import Synchronization
import Testing

@testable import HermesKit

/// coder's History listing, changeable while the gateway runs.
private final class Listing: Sendable {
    private let rows: Mutex<[JSONValue]>
    init(_ rows: [JSONValue] = []) { self.rows = Mutex(rows) }

    var value: [JSONValue] {
        get { rows.withLock { $0 } }
        set { rows.withLock { $0 = newValue } }
    }
}

/// A gateway serving bot `coder` whose History listing the test can change.
private func liveGateway(listing: Listing) -> ScriptedGateway {
    let gateway = ScriptedGateway()
    gateway.on("profiles.list", result: [
        "profiles": [profileRowPayload("default", isDefault: true), profileRowPayload("coder")],
        "bot_mode_protocol": true, "install_id": "test",
    ])
    gateway.on("session.list") { params in
        if params["title"] != nil { return .result(["sessions": []]) }
        if params["profile"]?.stringValue == "coder" { return .result(["sessions": .array(listing.value)]) }
        return .result(["sessions": []])
    }
    gateway.on("session.resume") { params in
        let key = params["session_id"]?.stringValue ?? ""
        return .result(resumedPayload(sid: "rt-\(key)", key: key))
    }
    return gateway.withDefaults()
}

/// Broadcast frames carry an empty `session_id` (`server.py:738-754`).
private func broadcast(_ gateway: ScriptedGateway, _ type: String, _ payload: JSONValue = [:]) {
    gateway.transport.sendEvent(type, sessionID: "", payload: payload)
}

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct LiveSidebarTests {
    private func connect(_ gateway: ScriptedGateway, interval: Duration = .milliseconds(1)) async throws
        -> GatewayConnection
    {
        let connection = try await gateway.connect()
        connection.pushedRefreshInterval = interval
        try await connection.refreshBots()
        connection.navigationPage = .sessions
        connection.selectListProfile("coder")
        await connection.refreshSessionList()
        // Let the refresh `connect()` started settle, so counts below are the pushes' own.
        _ = await eventually { connection.listsRefreshTask == nil }
        return connection
    }

    private func historyListings(_ gateway: ScriptedGateway) -> Int {
        gateway.params("session.list").filter { $0["profile"] == "coder" && $0["title"] == nil }.count
    }

    /// `sessions.changed` (`change_watcher.py:285-331`) replaces waiting for the poll.
    @Test func sessionsChangedRefreshesTheRosterAndHistory() async throws {
        let listing = Listing()
        let gateway = liveGateway(listing: listing)
        let connection = try await connect(gateway)
        #expect(connection.history.isEmpty)

        // Desktop started a side chat with coder.
        listing.value = [sessionRow(id: "from-desktop", title: "Plan")]
        broadcast(gateway, "sessions.changed")

        #expect(await eventually { connection.history.map(\.summary.id) == ["from-desktop"] })
        #expect(gateway.params("session.list").contains { $0 == ["limit": 50] })  // the launch profile's list too
    }

    @Test func aBurstOfChangesIsThrottled() async throws {
        let gateway = liveGateway(listing: Listing())
        let connection = try await connect(gateway, interval: .milliseconds(300))
        let before = historyListings(gateway)

        for _ in 0..<6 { broadcast(gateway, "sessions.changed") }

        // One refresh right away, one trailing refresh after the interval.
        #expect(await eventually { historyListings(gateway) == before + 2 })
        // Nothing pending or queued: no refresh can follow without a new event.
        #expect(await eventually {
            connection.pushedRefreshTask == nil && connection.listsRefreshTask == nil && !connection.listsRefreshQueued
        })
        #expect(historyListings(gateway) == before + 2)
    }

    /// A finished turn refreshes the bot's preview at once, even right after a
    /// `sessions.changed` refresh, and the turn's late `sessions.changed` collapse behind it.
    @Test func aFinishedTurnRefreshesAtOnce() async throws {
        let gateway = liveGateway(listing: Listing([sessionRow(id: "s1", title: "Plan")]))
        let connection = try await connect(gateway, interval: .seconds(30))
        let session = try await connection.open(try #require(connection.history.first))
        #expect(await eventually { connection.listsRefreshTask == nil && !connection.listsRefreshQueued })
        let start = historyListings(gateway)
        broadcast(gateway, "sessions.changed")  // the turn's first change: refreshes, opens the window
        #expect(await eventually { historyListings(gateway) == start + 1 })
        broadcast(gateway, "sessions.changed")  // inside the window: becomes the trailing refresh
        #expect(await eventually { connection.pushedRefreshTask != nil })

        gateway.transport.sendEvent("message.complete", sessionID: session.sessionID,
                                    payload: ["text": "done", "status": "complete"])

        #expect(await eventually { historyListings(gateway) == start + 2 })
        #expect(connection.pushedRefreshTask == nil)  // the trailing one was replaced
        broadcast(gateway, "sessions.changed")  // a late change of the same turn
        #expect(await eventually { connection.pushedRefreshTask != nil })  // waits for the window
        #expect(await eventually { connection.listsRefreshTask == nil && !connection.listsRefreshQueued })
        #expect(historyListings(gateway) == start + 2)
    }

    /// `session.info` carries the stored key and the title (`contracts/common.py:63-98`, `server.py:2442-2455`).
    @Test func sessionInfoRenamesTheRow() async throws {
        let gateway = liveGateway(listing: Listing([sessionRow(id: "s1", title: "Untitled")]))
        let connection = try await connect(gateway)
        try await connection.open(try #require(connection.history.first))

        gateway.transport.sendEvent("session.info", sessionID: "rt-s1",
                                    payload: ["stored_session_id": "s1", "title": "Quarterly numbers", "running": false])

        #expect(await eventually { connection.history.first?.summary.title == "Quarterly numbers" })
        #expect(connection.activeSession?.title == "Quarterly numbers")
    }

    /// `notification.show` / `.clear` (`contracts/events.py:332-349`).
    @Test func notificationsAreKeyedAndExpire() async throws {
        let gateway = liveGateway(listing: Listing())
        let connection = try await connect(gateway)

        broadcast(gateway, "notification.show", ["text": "Credits low", "level": "warn", "kind": "sticky", "key": "credits"])
        broadcast(gateway, "notification.show", ["text": "Credits very low", "level": "error", "kind": "sticky",
                                                 "key": "credits"])
        broadcast(gateway, "notification.show", ["text": "Agent ready", "level": "info", "kind": "ttl", "ttl_ms": 50,
                                                 "id": "n1"])
        #expect(await eventually { connection.notifications.map(\.id) == ["credits", "n1"] })
        #expect(connection.notifications.first?.notice.text == "Credits very low")

        #expect(await eventually { connection.notifications.map(\.id) == ["credits"] })  // the ttl one expired
        broadcast(gateway, "notification.clear", ["key": "credits"])
        #expect(await eventually { connection.notifications.isEmpty })
    }

    /// `ttl_ms` counts only for `kind: "ttl"` (`agent/credits_tracker.py:111-112`,
    /// `apps/desktop/src/store/agent-notices.ts:118-134`).
    @Test func onlyTtlNoticesExpire() async throws {
        let gateway = liveGateway(listing: Listing())
        let connection = try await connect(gateway)

        broadcast(gateway, "notification.show", ["text": "Agent note", "kind": "agent", "ttl_ms": 20, "id": "a"])
        broadcast(gateway, "notification.show", ["text": "Low credit", "kind": "sticky", "ttl_ms": 20, "id": "s"])
        broadcast(gateway, "notification.show", ["text": "Done", "kind": "ttl", "ttl_ms": 20, "id": "t"])
        #expect(await eventually { connection.notifications.map(\.id) == ["a", "s", "t"] })

        // The ttl one leaving proves its timer ran; the others' would have run as long.
        #expect(await eventually { connection.notifications.map(\.id) == ["a", "s"] })
        try await Task.sleep(for: .milliseconds(60))
        #expect(connection.notifications.map(\.id) == ["a", "s"])
    }

    /// `session.reclaimed` (`session_lifecycle.py:465-480`): like Desktop
    /// (`gateway-event/lifecycle.ts:123-165`) the chat stays, its dead runtime's
    /// requests go, and it is resumed only by its next action, not right away
    /// (which would undo an idle reclaim every TTL).
    @Test func aReclaimedChatResumesOnItsNextAction() async throws {
        let gateway = liveGateway(listing: Listing([sessionRow(id: "s1", title: "Plan")]))
        let connection = try await connect(gateway)
        let session = try await connection.open(try #require(connection.history.first))
        // The reclaimed runtime had an approval open, shown in the transcript and badged elsewhere.
        gateway.transport.serverSends(["jsonrpc": "2.0", "id": "srq-1", "method": "approval",
                                       "params": ["session_id": "rt-s1", "request_id": "a1", "command": "ls"]])
        #expect(await eventually { session.transcript.pendingRequests.count == 1 })
        gateway.on("session.resume") { _ in .result(resumedPayload(sid: "rt-s1-again", key: "s1")) }
        let resumesBefore = gateway.params("session.resume").count

        broadcast(gateway, "session.reclaimed", ["session_id": "rt-s1", "stored_session_id": "s1",
                                                 "reason": "idle_timeout"])

        #expect(await eventually { session.isRuntimeGone })
        #expect(session.transcript.pendingRequests.isEmpty)
        try await Task.sleep(for: .milliseconds(50))
        #expect(gateway.params("session.resume").count == resumesBefore)  // not resumed eagerly
        #expect(connection.activeSession === session)

        try await session.send("still there?")

        #expect(gateway.params("session.resume").last == ["session_id": "s1", "profile": "coder", "omit_messages": true,
                                                          "defer_history": true])
        #expect(gateway.params("prompt.submit") == [["session_id": "rt-s1-again", "text": "still there?"]])
        #expect(!session.isRuntimeGone && session.sessionID == "rt-s1-again")
        #expect(session.transcript.items.last?.text == "still there?")
    }

    /// A background chat's requests die with its runtime (`lifecycle.ts:143-149`).
    @Test func aReclaimedRuntimesRequestsLeaveTheBadge() async throws {
        let gateway = liveGateway(listing: Listing())
        let connection = try await connect(gateway)
        gateway.transport.serverSends(["jsonrpc": "2.0", "id": "srq-2", "method": "approval",
                                       "params": ["session_id": "rt-elsewhere", "request_id": "a2", "command": "ls"]])
        #expect(await eventually { connection.otherSessionRequests.count == 1 })

        broadcast(gateway, "session.reclaimed", ["session_id": "rt-elsewhere", "stored_session_id": "x",
                                                 "reason": "lru_evict"])

        #expect(await eventually { connection.otherSessionRequests.isEmpty })
    }

    /// A Bot Chat on screen is re-resolved by name at once, as Desktop's bots
    /// plugin does (`plugins/hermes-bots/plugin.tsx:653-701`), except after an
    /// `lru_evict`, where resuming would evict another session in turn.
    @Test(arguments: [("idle_timeout", true), ("lru_evict", false)])
    func aReclaimedBotChatIsReResolved(reason: String, eager: Bool) async throws {
        let gateway = liveGateway(listing: Listing())
        gateway.on("session.list") { params in
            if params["title"]?.stringValue == "Bot Chat" {
                return .result(["sessions": [["id": "coder-chat", "resolved_id": "coder-chat", "title": "Bot Chat",
                                              "preview": "", "started_at": 1_700_000_000, "message_count": 2,
                                              "source": "desktop"]]])
            }
            return .result(["sessions": []])
        }
        let connection = try await connect(gateway)
        let botChat = try await connection.openBotChat(profile: "coder")
        let lookups = gateway.params("session.list").filter { $0["title"] == "Bot Chat" }.count

        broadcast(gateway, "session.reclaimed", ["session_id": "rt-coder-chat", "stored_session_id": "coder-chat",
                                                 "reason": .string(reason)])

        if eager {
            #expect(await eventually {
                gateway.params("session.list").filter { $0["title"] == "Bot Chat" }.count == lookups + 1
                    && !botChat.isRuntimeGone
            })
        } else {
            #expect(await eventually { botChat.isRuntimeGone })
            try await Task.sleep(for: .milliseconds(50))
            #expect(gateway.params("session.list").filter { $0["title"] == "Bot Chat" }.count == lookups)
        }
        #expect(connection.activeSession === botChat)
    }

    @Test func selectionsAnswerOnlyAClarifyRequest() async throws {
        let gateway = liveGateway(listing: Listing([sessionRow(id: "s1")]))
        let connection = try await connect(gateway)
        let session = try await connection.open(try #require(connection.history.first))
        let approval = ServerRequest(id: "srq-9", method: "approval", params: ["session_id": "rt-s1", "request_id": "a9"])

        await #expect(throws: ComposerError.notAClarifyRequest) { try await session.answer(approval, selections: [:]) }
    }

    @Test func multiSelectClarifyAnswerGoesOutAsAJSONList() async throws {
        let gateway = liveGateway(listing: Listing([sessionRow(id: "s1")]))
        let connection = try await connect(gateway)
        let session = try await connection.open(try #require(connection.history.first))
        // `server.py:1410-1419`.
        gateway.transport.serverSends(["jsonrpc": "2.0", "id": "srq-c1", "method": "clarify", "params": [
            "session_id": "rt-s1",
            "questions": [["qid": "q0", "question": "Which?", "choices": ["a (Recommended)", "b", "c"],
                           "multi_select": true]],
        ]])
        #expect(await eventually { !session.transcript.pendingRequests.isEmpty })
        let request = try #require(session.transcript.pendingRequests.first)

        try await session.answer(request, selections: ["q0": ClarifySelection(choices: ["a (Recommended)", "c"])])

        #expect(await eventually {
            gateway.log.all.contains { $0["id"] == "srq-c1" && $0["result"] == ["answers": ["q0": #"["a","c"]"#]] }
        })
        #expect(session.transcript.pendingRequests.isEmpty)
    }
}
