import Foundation
import HermesProtocol
import Synchronization
import Testing

@testable import HermesKit

/// Broadcast frames carry an empty `session_id` (`server.py:738-754`).
private func reclaim(_ transport: FakeTransport, runtime: String, stored: String, reason: String = "idle_timeout") {
    transport.sendEvent("session.reclaimed", sessionID: "",
                        payload: ["session_id": .string(runtime), "stored_session_id": .string(stored),
                                  "reason": .string(reason)])
}

/// A chat whose runtime the backend reclaimed (`session.reclaimed`,
/// `session_lifecycle.py:465-480`; `docs/protocol.md` §11) next to reconnects,
/// warm chats and deletes.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct ReclaimedRuntimeTests {
    private let connections = ConnectionKeeper()

    /// N2: nothing will complete the turn of a reclaimed runtime; it stops spinning.
    @Test func aRunningTurnEndsWithItsRuntime() async throws {
        let gateway = ScriptedGateway()
        gateway.on("session.create", result: createdPayload(sid: "sid-1", key: "stored-1"))
        let connection = try await gateway.withDefaults().connect()
        connections.keep(connection)
        let session = try await connection.newSession()
        try await session.send("long job")
        gateway.transport.sendEvent("message.start")
        gateway.transport.sendEvent("message.delta", payload: ["text": "Working"])
        #expect(await eventually { session.transcript.items.last?.isActive == true })

        reclaim(gateway.transport, runtime: "sid-1", stored: "stored-1")

        #expect(await eventually { session.isRuntimeGone })
        #expect(!session.transcript.isRunning)
        #expect(session.transcript.items.allSatisfy { !$0.isActive })
        expectWellFormed(session.transcript)
    }

    /// N1: an action while a reconnect restores a reclaimed chat waits for that
    /// restore and does not resume the chat a second time.
    @Test func anActionDuringTheReconnectsRestoreDoesNotResumeAgain() async throws {
        let firstLog = FrameLog(), secondLog = FrameLog()
        let first = FakeTransport(), second = FakeTransport()
        first.serve(log: firstLog) { method, _ in
            switch method {
            case "session.create": createdPayload(sid: "sid-1", key: "stored-1")
            case "session.list": ["sessions": []]
            case "profiles.list": ["profiles": [], "bot_mode_protocol": true, "install_id": "test"]
            default: nil
            }
        }
        let connection = makeTestConnection()
        connections.keep(connection)
        try await connection.connect(using: FakeConnector([first, second]))
        let session = try await connection.newSession()
        reclaim(first, runtime: "sid-1", stored: "stored-1")
        #expect(await eventually { session.isRuntimeGone })

        // The socket drops; the new one holds the restore's resume until released below.
        second.serve(epoch: "epoch-1", log: secondLog) { method, _ in
            switch method {
            case "prompt.submit": ["status": "streaming"]
            case "session.list": ["sessions": []]
            case "profiles.list": ["profiles": [], "bot_mode_protocol": true, "install_id": "test"]
            default: nil
            }
        }
        first.serverDrops()
        #expect(await eventually { secondLog.requests("session.resume").count == 1 })
        let sending = Task { try await session.send("still there?") }
        try await Task.sleep(for: .milliseconds(100))
        #expect(secondLog.requests("session.resume").count == 1)
        #expect(secondLog.requests("prompt.submit").isEmpty)

        let resume = try #require(secondLog.requests("session.resume").first)
        // Resume payloads carry `session_key`, no `stored_session_id` (`methods_session.py:908-911`).
        second.respond(to: resume, result: resumedPayload(sid: "sid-2", key: "stored-1"))
        try await sending.value

        #expect(secondLog.requests("session.resume").count == 1)
        #expect(secondLog.requests("prompt.submit").map { $0["params"] } == [["session_id": "sid-2", "text": "still there?"]])
        #expect(!session.isRuntimeGone && session.sessionID == "sid-2")
        #expect(connection.state == .connected)
    }

    /// A warm chat reclaimed in the background is resumed when shown again,
    /// without trying to bind its dead runtime (`session.activate`).
    @Test func aReclaimedWarmChatResumesWhenShownAgain() async throws {
        let gateway = sideChatGateway(listing: [sessionRow(id: "s1", title: "One"), sessionRow(id: "s2", title: "Two")])
        let connection = try await gateway.connect()
        connections.keep(connection)
        try await connection.refreshBots()
        try await connection.refreshHistory()
        let one = try await connection.open(try #require(connection.history.first { $0.summary.id == "s1" }))
        try await connection.open(try #require(connection.history.first { $0.summary.id == "s2" }))
        #expect(connection.activeSession !== one)

        reclaim(gateway.transport, runtime: "rt-s1", stored: "s1")
        #expect(await eventually { one.isRuntimeGone })
        gateway.on("session.resume") { _ in .result(resumedPayload(sid: "rt-s1-again", key: "s1")) }
        let resumes = gateway.params("session.resume").count

        let shown = try await connection.open(try #require(connection.history.first { $0.summary.id == "s1" }))

        #expect(shown === one)
        #expect(await eventually { !one.isRuntimeGone && one.sessionID == "rt-s1-again" })
        #expect(gateway.params("session.resume").count == resumes + 1)
        #expect(gateway.params("session.activate").isEmpty)
    }

    /// Going back to a reclaimed Bot Chat whose eager revival is still in flight joins
    /// that revival: one `session.resume`, not two.
    @Test func goingBackDuringARevivalDoesNotResumeAgain() async throws {
        let gateway = sideChatGateway(listing: [])
        gateway.on("session.list") { params in
            if params["title"]?.stringValue == "Bot Chat" {
                return .result(["sessions": [["id": "coder-chat", "resolved_id": "coder-chat", "title": "Bot Chat",
                                              "preview": "", "started_at": 1_700_000_000, "message_count": 2,
                                              "source": "desktop"]]])
            }
            return .result(["sessions": []])
        }
        gateway.on("session.create", result: createdPayload(sid: "rt-side", key: "side-1"))
        let connection = try await gateway.connect()
        connections.keep(connection)
        try await connection.refreshBots()
        let botChat = try await connection.openBotChat(profile: "coder")
        gateway.on("session.resume") { _ in nil }  // the revival's resume waits below
        let resumes = gateway.params("session.resume").count

        reclaim(gateway.transport, runtime: "rt-coder-chat", stored: "coder-chat")
        #expect(await eventually { gateway.params("session.resume").count == resumes + 1 })
        try await connection.newSideChat(profile: "coder")
        let shown = try await connection.openBotChat(profile: "coder")
        #expect(botChat.isReconciling)
        // No signal says the revisit is past its Bot Chat lookup and waiting on the revival.
        try await Task.sleep(for: .milliseconds(100))
        #expect(gateway.params("session.resume").count == resumes + 1)

        // A second resume, if one were sent, gets an answer too, so the revisit can end.
        gateway.on("session.resume") { _ in .result(resumedPayload(sid: "rt-coder-chat-3", key: "coder-chat")) }
        let held = gateway.log.requests("session.resume")[resumes]  // the revival's
        gateway.transport.respond(to: held, result: resumedPayload(sid: "rt-coder-chat-2", key: "coder-chat"))

        #expect(shown === botChat)
        // The revisit has ended: nothing else can resume the chat now.
        #expect(await eventually { !botChat.isReconciling && botChat.revival == nil })
        #expect(!botChat.isRuntimeGone && botChat.sessionID == "rt-coder-chat-2")
        #expect(gateway.params("session.resume").count == resumes + 1)
        #expect(gateway.params("session.activate").isEmpty)
    }

    /// Deleting a History row whose chat is warm closes that runtime and forgets
    /// the chat (and its composer).
    @Test func deletingAWarmChatForgetsIt() async throws {
        let gateway = sideChatGateway(listing: [sessionRow(id: "old", title: "Old"), sessionRow(id: "new", title: "New")])
        let connection = try await gateway.connect()
        connections.keep(connection)
        try await connection.refreshBots()
        try await connection.refreshHistory()
        let old = try await connection.open(try #require(connection.history.first { $0.summary.id == "old" }))
        connection.composer(for: old).draft = "unsent"
        try await connection.open(try #require(connection.history.first { $0.summary.id == "new" }))

        try await connection.delete(try #require(connection.history.first { $0.summary.id == "old" }))

        #expect(gateway.params("session.close") == [["session_id": "rt-old"]])
        #expect(gateway.params("session.delete") == [["session_id": "old", "profile": "coder"]])
        #expect(!connection.warmChats.contains { $0 === old })
        #expect(connection.composer(for: old).draft.isEmpty)  // a fresh composer: the old one went
    }

    /// Bot `coder` whose History lists `listing`; every resume answers `rt-<key>`.
    private func sideChatGateway(listing: [JSONValue]) -> ScriptedGateway {
        let gateway = ScriptedGateway()
        gateway.on("profiles.list", result: [
            "profiles": [profileRowPayload("default", isDefault: true), profileRowPayload("coder")],
            "bot_mode_protocol": true, "install_id": "test",
        ])
        gateway.on("session.list") { params in
            if params["title"] != nil { return .result(["sessions": []]) }
            return .result(["sessions": params["profile"]?.stringValue == "coder" ? .array(listing) : []])
        }
        gateway.on("session.resume") { params in
            let key = params["session_id"]?.stringValue ?? ""
            return .result(resumedPayload(sid: "rt-\(key)", key: key))
        }
        gateway.on("session.close", result: ["closed": true])
        gateway.on("session.interrupt", result: ["status": "interrupted"])
        gateway.on("session.delete") { params in .result(["deleted": params["session_id"] ?? ""]) }
        return gateway.withDefaults()
    }
}
