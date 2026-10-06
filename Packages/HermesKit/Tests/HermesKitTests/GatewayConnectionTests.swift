import Foundation
import HermesProtocol
import Testing

@testable import HermesKit

/// Resume payload as Hermes sends it: the stored key is `session_key`;
/// there is NO `stored_session_id` (`methods_session.py:908-911`).
private func resumePayload(sid: String, key: String = "stored-1",
                                              messages: JSONValue = [["role": "user", "text": "hi"],
                                                                     ["role": "assistant", "text": "hello"]],
                                              extra: [String: JSONValue] = [:]) -> JSONValue {
    var payload: [String: JSONValue] = [
        "session_id": .string(sid), "resumed": .string(key), "session_key": .string(key),
        "message_count": .number(Double(messages.arrayValue?.count ?? 0)), "messages": messages,
        "info": ["model": "test-model"], "running": false, "status": "idle", "inflight": nil,
    ]
    payload.merge(extra) { _, new in new }
    return .object(payload)
}

private func sinceResult(epoch: String, latestSeq: Int, events: JSONValue = []) -> JSONValue {
    ["events": events, "latest_seq": .number(Double(latestSeq)), "truncated": false,
     "count": .number(Double(events.arrayValue?.count ?? 0)), "epoch": .string(epoch), "open_requests": []]
}

/// Default scripted server for a fresh backend.
private func standardServer(_ method: String, _ params: JSONValue) -> JSONValue? {
    switch method {
    case "session.list":
        return ["sessions": [["id": "stored-1", "title": "Earlier chat", "message_count": 2]]]
    case "session.create":
        return ["session_id": "sid-1", "stored_session_id": "stored-new", "message_count": 0,
                "messages": [], "info": ["model": "test-model"]]
    case "session.resume":
        return resumePayload(sid: "sid-1")
    case "prompt.submit":
        return ["status": "streaming"]
    default:
        return nil
    }
}

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct GatewayConnectionTests {
    private func makeConnection() -> GatewayConnection {
        var configuration = GatewayClient.Configuration()
        configuration.heartbeatInterval = nil
        return GatewayConnection(configuration: configuration, backoff: { _ in .milliseconds(1) })
    }

    private func isFailed(_ connection: GatewayConnection) -> Bool {
        if case .failed = connection.state { return true }
        return false
    }

    // MARK: - Basics

    @Test func connectListsSessionsAndStreamsATurn() async throws {
        let transport = FakeTransport()
        let log = FrameLog()
        transport.serve(log: log, standardServer)
        let connection = makeConnection()

        try await connection.connect(using: FakeConnector([transport]))
        #expect(connection.state == .connected)
        #expect(connection.sessions.map(\.id) == ["stored-1"])

        let session = try await connection.newSession()
        #expect(session.storedSessionID == "stored-new")
        try await session.send("hello there")
        #expect(log.requests("prompt.submit").first?["params"] == ["session_id": "sid-1", "text": "hello there"])

        transport.sendEvent("message.start", seq: 1)
        transport.sendEvent("message.delta", seq: 2, payload: ["text": "Hi!"])
        transport.sendEvent("message.delta", sessionID: "other-sid", seq: 1, payload: ["text": "not mine"])
        transport.sendEvent("message.complete", seq: 3, payload: ["text": "Hi!", "status": "complete"])

        #expect(await eventually { !session.transcript.isRunning && session.lastSeq == 3 })
        #expect(session.transcript.items.map(\.text) == ["hello there", "Hi!"])
    }

    @Test func routesServerRequestsAndAnswersThem() async throws {
        let transport = FakeTransport()
        let log = FrameLog()
        transport.serve(log: log, standardServer)
        let connection = makeConnection()
        try await connection.connect(using: FakeConnector([transport]))
        let session = try await connection.open(SessionSummary(id: "stored-1"))
        #expect(session.transcript.items.map(\.text) == ["hi", "hello"])

        transport.serverSends(["jsonrpc": "2.0", "id": "srq-1", "method": "approval",
                               "params": ["session_id": "sid-1", "request_id": "ap-1", "command": "rm x"]])
        transport.serverSends(["jsonrpc": "2.0", "id": "srq-2", "method": "sudo",
                               "params": ["session_id": "elsewhere"]])
        #expect(await eventually { session.transcript.pendingRequests.count == 1 })
        #expect(await eventually { connection.otherSessionRequests.map(\.id) == ["srq-2"] })

        let request = try #require(session.transcript.pendingRequests.first)
        try await session.answer(request, approval: .session)
        #expect(session.transcript.pendingRequests.isEmpty)
        #expect(await eventually {
            log.all.contains { $0["id"] == "srq-1" && $0["result"] == ["choice": "session"] }
        })
    }

    // MARK: - B2: stored key

    @Test func openedSessionKnowsItsStoredKeyAndFollowsTitleEvents() async throws {
        let transport = FakeTransport()
        let log = FrameLog()
        transport.serve(log: log, standardServer)
        let connection = makeConnection()
        try await connection.connect(using: FakeConnector([transport]))

        let session = try await connection.open(SessionSummary(id: "stored-1", title: "Earlier chat"))
        #expect(session.storedSessionID == "stored-1")

        // session.title carries the STORED key (prompt_turn.py:795-797).
        transport.sendEvent("session.title", sessionID: "sid-1", payload: ["session_id": "stored-1", "title": "Renamed"])
        #expect(await eventually { session.title == "Renamed" && connection.sessions.first?.title == "Renamed" })

        // Compression rotates the key: session.info carries the new one.
        transport.sendEvent("session.info", sessionID: "sid-1", payload: ["stored_session_id": "stored-1b"])
        #expect(await eventually { session.storedSessionID == "stored-1b" })

        // Re-selecting the active row does not resume it again.
        _ = try await connection.open(SessionSummary(id: "stored-1b"))
        #expect(log.requests("session.resume").count == 1)
    }

    // MARK: - B1: same-backend reconnect must reattach

    @Test func reconnectOnSameBackendReattachesBeforeReplaying() async throws {
        let first = FakeTransport()
        let second = FakeTransport()
        let secondLog = FrameLog()
        first.serve(epoch: "E1", log: FrameLog(), standardServer)
        second.serve(epoch: "E1", log: secondLog) { method, params in
            switch method {
            case "session.activate":
                return resumePayload(sid: "sid-1", messages: [], extra: ["running": true])
            case "session.events.since":
                return sinceResult(epoch: "E1", latestSeq: 6, events: [
                    ["type": "message.delta", "session_id": "sid-1", "seq": 6, "payload": ["text": " world"]],
                ])
            default:
                return standardServer(method, params)
            }
        }
        let connection = makeConnection()
        try await connection.connect(using: FakeConnector([first, second]))
        let session = try await connection.open(SessionSummary(id: "stored-1"))

        first.sendEvent("message.start", seq: 4)
        first.sendEvent("message.delta", seq: 5, payload: ["text": "hello"])
        #expect(await eventually { session.lastSeq == 5 })

        first.serverDrops()
        #expect(await eventually { connection.state == .connected && session.lastSeq == 6 })
        let methods = secondLog.all.compactMap { $0["method"]?.stringValue }
        let activateIndex = try #require(methods.firstIndex(of: "session.activate"))
        let sinceIndex = try #require(methods.firstIndex(of: "session.events.since"))
        #expect(activateIndex < sinceIndex)
        #expect(secondLog.requests("session.activate").first?["params"] == ["session_id": "sid-1", "omit_messages": true])
        #expect(secondLog.requests("session.events.since").first?["params"] == ["session_id": "sid-1", "last_seen": 5])
        #expect(secondLog.requests("session.resume").isEmpty)
        #expect(session.transcript.items.last?.text == "hello world")

        // Live events after the reattach keep arriving on the new socket.
        second.sendEvent("message.delta", seq: 7, payload: ["text": "!"])
        #expect(await eventually { session.transcript.items.last?.text == "hello world!" })
    }

    /// B1/S1: the runtime session was reaped during the outage. `events.since`
    /// would answer with an empty success; `activate` says 4007 → resume.
    @Test func reconnectResumesWhenRuntimeSessionWasReaped() async throws {
        let first = FakeTransport()
        let second = FakeTransport()
        let secondLog = FrameLog()
        first.serve(epoch: "E1", log: FrameLog(), standardServer)
        second.serve(epoch: "E1", log: secondLog) { method, params in
            switch method {
            case "session.activate": return nil  // answered below with an error
            case "session.events.since": return sinceResult(epoch: "E1", latestSeq: 0)
            case "session.resume": return resumePayload(sid: "sid-9")
            default: return standardServer(method, params)
            }
        }
        let connection = makeConnection()
        try await connection.connect(using: FakeConnector([first, second]))
        let session = try await connection.open(SessionSummary(id: "stored-1"))
        first.sendEvent("message.delta", seq: 3, payload: ["text": "x"])
        #expect(await eventually { session.lastSeq == 3 })

        first.serverDrops()
        #expect(await eventually { !secondLog.requests("session.activate").isEmpty })
        second.respondError(to: try #require(secondLog.requests("session.activate").first),
                            code: 4007, message: "session no longer live; retry resume")
        #expect(await eventually { connection.state == .connected && session.sessionID == "sid-9" })
        #expect(secondLog.requests("session.resume").first?["params"] == ["session_id": "stored-1", "omit_messages": true, "defer_history": true])
    }

    // MARK: - B2/S1: backend restart

    @Test func reconnectResumesByStoredKeyWhenBackendRestarted() async throws {
        let first = FakeTransport()
        let second = FakeTransport()
        let secondLog = FrameLog()
        first.serve(epoch: "E1", log: FrameLog(), standardServer)
        second.serve(epoch: "E2", log: secondLog) { method, params in
            if method == "session.resume" {
                guard params["session_id"] == "stored-1" else { return nil }  // runtime id would 4007
                return resumePayload(
                    sid: "sid-2",
                    messages: [["role": "user", "text": "hi"], ["role": "assistant", "text": "hello"],
                               ["role": "user", "text": "again"]],
                    extra: ["open_requests": [["id": "srq-9", "method": "clarify",
                                               "params": ["session_id": "sid-2",
                                                          "questions": [["qid": "q1", "question": "Which?"]]]]]])
            }
            return standardServer(method, params)
        }
        let connection = makeConnection()
        try await connection.connect(using: FakeConnector([first, second]))
        let session = try await connection.open(SessionSummary(id: "stored-1"))
        first.sendEvent("message.delta", seq: 1, payload: ["text": "x"])
        #expect(await eventually { session.lastSeq == 1 })

        first.serverDrops()
        #expect(await eventually { connection.state == .connected && session.sessionID == "sid-2" })
        #expect(secondLog.requests("session.events.since").isEmpty)
        #expect(secondLog.requests("session.activate").isEmpty)
        #expect(secondLog.requests("session.resume").first?["params"] == ["session_id": "stored-1", "omit_messages": true, "defer_history": true])
        #expect(session.transcript.items.map(\.text) == ["hi", "hello", "again"])
        #expect(await eventually { session.transcript.pendingRequests.map(\.id) == ["srq-9"] })
    }

    /// S1: attempt 1 on the restarted backend fails mid-restore; attempt 2
    /// sees the same NEW epoch and must still resume, not "replay".
    @Test func epochIsCommittedOnlyAfterASuccessfulRestore() async throws {
        let first = FakeTransport()
        let second = FakeTransport()
        let third = FakeTransport()
        let secondLog = FrameLog()
        let thirdLog = FrameLog()
        first.serve(epoch: "E1", log: FrameLog(), standardServer)
        second.serve(epoch: "E2", log: secondLog) { method, params in
            method == "session.resume" ? nil : standardServer(method, params)  // fails below
        }
        third.serve(epoch: "E2", log: thirdLog) { method, params in
            if method == "session.events.since" { return sinceResult(epoch: "E2", latestSeq: 0) }
            if method == "session.activate" { return resumePayload(sid: "sid-1") }
            return method == "session.resume" ? resumePayload(sid: "sid-3") : standardServer(method, params)
        }
        let connection = makeConnection()
        try await connection.connect(using: FakeConnector([first, second, third]))
        let session = try await connection.open(SessionSummary(id: "stored-1"))
        first.sendEvent("message.delta", seq: 2, payload: ["text": "x"])
        #expect(await eventually { session.lastSeq == 2 })

        first.serverDrops()
        #expect(await eventually { !secondLog.requests("session.resume").isEmpty })
        second.respondError(to: try #require(secondLog.requests("session.resume").first),
                            code: 5032, message: "agent still starting")

        #expect(await eventually { connection.state == .connected && session.sessionID == "sid-3" })
        #expect(thirdLog.requests("session.events.since").isEmpty)
        #expect(thirdLog.requests("session.resume").first?["params"] == ["session_id": "stored-1", "omit_messages": true, "defer_history": true])
    }

    // MARK: - S2: re-entrancy and leaks

    @Test func failedRestoreClosesTheNewSocket() async throws {
        let first = FakeTransport()
        let second = FakeTransport()
        let third = FakeTransport()
        let secondLog = FrameLog()
        first.serve(epoch: "E1", log: FrameLog(), standardServer)
        second.serve(epoch: "E2", log: secondLog) { method, params in
            method == "session.resume" ? nil : standardServer(method, params)
        }
        third.serve(epoch: "E2", log: FrameLog()) { method, params in
            method == "session.resume" ? resumePayload(sid: "sid-3") : standardServer(method, params)
        }
        let connection = makeConnection()
        try await connection.connect(using: FakeConnector([first, second, third]))
        _ = try await connection.open(SessionSummary(id: "stored-1"))

        first.serverDrops()
        #expect(await eventually { !secondLog.requests("session.resume").isEmpty })
        second.respondError(to: try #require(secondLog.requests("session.resume").first),
                            code: 5035, message: "backend retiring")
        #expect(await eventually { connection.state == .connected })
        #expect(second.isClosed)
        #expect(!third.isClosed)
    }

    @Test func disconnectDuringAnInFlightConnectWins() async throws {
        let slow = FakeTransport(connectDelay: .milliseconds(150))
        slow.serve(log: FrameLog(), standardServer)
        let connection = makeConnection()

        let attempt = Task { try await connection.connect(using: FakeConnector([slow])) }
        try await Task.sleep(for: .milliseconds(30))
        await connection.disconnect()

        await #expect(throws: CancellationError.self) { try await attempt.value }
        #expect(connection.state == .disconnected)
        #expect(connection.client == nil)
        #expect(await eventually { slow.isClosed })
    }

    @Test func reconnectGivesUpAfterMaxAttempts() async throws {
        let first = FakeTransport()
        first.serve(log: FrameLog(), standardServer)
        let connection = makeConnection()
        connection.maxReconnectAttempts = 2
        try await connection.connect(using: FakeConnector([first]))  // no transports left for retries
        first.serverDrops()
        #expect(await eventually { isFailed(connection) })
    }

    // MARK: - S3: fresh connect with an active session

    @Test func freshConnectRestoresTheActiveSession() async throws {
        let first = FakeTransport()
        let second = FakeTransport()
        let secondLog = FrameLog()
        first.serve(epoch: "E1", log: FrameLog(), standardServer)
        second.serve(epoch: "E2", log: secondLog) { method, params in
            method == "session.resume" ? resumePayload(sid: "sid-5") : standardServer(method, params)
        }
        let connection = makeConnection()
        connection.maxReconnectAttempts = 1
        try await connection.connect(using: FakeConnector([first]))
        let session = try await connection.open(SessionSummary(id: "stored-1"))
        first.serverDrops()
        #expect(await eventually { isFailed(connection) })

        // e.g. the iOS app returning to the foreground after `.failed`.
        try await connection.connect(using: FakeConnector([second]))
        #expect(connection.activeSession === session)
        #expect(session.sessionID == "sid-5")
        #expect(secondLog.requests("session.resume").first?["params"] == ["session_id": "stored-1", "omit_messages": true, "defer_history": true])
    }

    @Test func freshConnectDropsASessionTheServerNoLongerHas() async throws {
        let first = FakeTransport()
        let second = FakeTransport()
        let secondLog = FrameLog()
        first.serve(epoch: "E1", log: FrameLog(), standardServer)
        second.serve(epoch: "E2", log: secondLog) { method, params in
            method == "session.resume" ? nil : standardServer(method, params)
        }
        let connection = makeConnection()
        try await connection.connect(using: FakeConnector([first]))
        _ = try await connection.open(SessionSummary(id: "stored-1"))

        let reconnect = Task { try await connection.connect(using: FakeConnector([second])) }
        #expect(await eventually { !secondLog.requests("session.resume").isEmpty })
        // Resume of an unknown stored id: 4007 "session not found" (methods_session.py:833).
        second.respondError(to: try #require(secondLog.requests("session.resume").first),
                            code: 4007, message: "session not found")
        try await reconnect.value
        #expect(connection.state == .connected)
        #expect(connection.activeSession == nil)
    }

    /// N1: 4009 "session disconnect interrupt settling" (session_lifecycle.py:821-822) is
    /// transient. A foreground connect that hits it must fail and KEEP the session, and
    /// the next connect must restore it.
    @Test func freshConnectKeepsTheSessionOnTransientRestoreError() async throws {
        let first = FakeTransport()
        let second = FakeTransport()
        let third = FakeTransport()
        let secondLog = FrameLog()
        first.serve(epoch: "E1", log: FrameLog(), standardServer)
        second.serve(epoch: "E2", log: secondLog) { method, params in
            method == "session.resume" ? nil : standardServer(method, params)
        }
        third.serve(epoch: "E2", log: FrameLog()) { method, params in
            method == "session.resume" ? resumePayload(sid: "sid-7") : standardServer(method, params)
        }
        let connection = makeConnection()
        connection.maxReconnectAttempts = 1
        try await connection.connect(using: FakeConnector([first]))
        let session = try await connection.open(SessionSummary(id: "stored-1"))
        first.serverDrops()
        #expect(await eventually { isFailed(connection) })

        let foreground = Task { try await connection.connect(using: FakeConnector([second])) }
        #expect(await eventually { !secondLog.requests("session.resume").isEmpty })
        second.respondError(to: try #require(secondLog.requests("session.resume").first),
                            code: 4009, message: "session disconnect interrupt settling")
        await #expect(throws: RPCError.self) { try await foreground.value }
        #expect(isFailed(connection))
        #expect(connection.activeSession === session)
        #expect(connection.client == nil)
        #expect(second.isClosed)

        try await connection.connect(using: FakeConnector([third]))
        #expect(connection.state == .connected)
        #expect(connection.activeSession === session)
        #expect(session.sessionID == "sid-7")
    }

    /// N2: two overlapping connect() calls (foreground reconnect + a user tap) must
    /// leave exactly one live client — the later call wins, the earlier one cancels.
    @Test func overlappingConnectsLeaveASingleLiveClient() async throws {
        let initial = FakeTransport()
        initial.serve(log: FrameLog(), standardServer)
        let a = FakeTransport(connectDelay: .milliseconds(40))
        let b = FakeTransport(connectDelay: .milliseconds(40))
        a.serve(log: FrameLog(), standardServer)
        b.serve(log: FrameLog(), standardServer)
        let connection = makeConnection()
        // An existing client makes each call suspend while closing it.
        try await connection.connect(using: FakeConnector([initial]))

        let first = Task { try await connection.connect(using: FakeConnector([a])) }
        let second = Task { try await connection.connect(using: FakeConnector([b])) }
        let firstResult = await first.result
        let secondResult = await second.result

        #expect(throws: CancellationError.self) { try firstResult.get() }
        #expect(throws: Never.self) { try secondResult.get() }
        #expect(connection.state == .connected)
        #expect(connection.client != nil)
        #expect(initial.isClosed)
        // The superseded call either never opened `a` or closed it.
        #expect(await eventually { [initial, a, b].filter(\.isOpen).count == 1 })
        #expect(b.isOpen)
    }

    @Test func disconnectForgetsSessionState() async throws {
        let transport = FakeTransport()
        transport.serve(log: FrameLog(), standardServer)
        let connection = makeConnection()
        try await connection.connect(using: FakeConnector([transport]))
        _ = try await connection.open(SessionSummary(id: "stored-1"))
        transport.serverSends(["jsonrpc": "2.0", "id": "srq-2", "method": "sudo", "params": ["session_id": "elsewhere"]])
        #expect(await eventually { !connection.otherSessionRequests.isEmpty })

        await connection.disconnect()
        #expect(connection.activeSession == nil)
        #expect(connection.otherSessionRequests.isEmpty)
        #expect(connection.sessions.isEmpty)
        #expect(connection.state == .disconnected)
    }
}
