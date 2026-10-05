import Foundation
import HermesProtocol
import Testing

@testable import HermesKit

@Suite(.timeLimit(.minutes(1)))
struct GatewayClientTests {
    private func connectedClient(
        configure: (inout GatewayClient.Configuration) -> Void = { _ in }
    ) async throws -> (GatewayClient, FakeTransport, InboundRecorder) {
        let transport = FakeTransport()
        var configuration = GatewayClient.Configuration()
        configuration.heartbeatInterval = nil
        configure(&configuration)
        let client = GatewayClient(transport: transport, configuration: configuration)
        let recorder = InboundRecorder(await client.inbound())
        async let ready = client.connect()
        await transport.completeHandshake()
        _ = try await ready
        // Drain the gateway.ready event.
        _ = await recorder.nextEvent()
        return (client, transport, recorder)
    }

    @Test func connectWaitsForReadyThenAdvertisesServerRequests() async throws {
        let transport = FakeTransport()
        let client = GatewayClient(transport: transport)
        async let connected = client.connect()

        transport.sendReady(epoch: "abc")
        let capabilities = await transport.nextSent()
        #expect(capabilities["method"] == "client.capabilities")
        #expect(capabilities["params"] == ["server_requests": true])
        #expect(capabilities["jsonrpc"] == "2.0")
        transport.respond(to: capabilities, result: ["server_requests": ["approval", "clarify"]])

        let ready = try await connected
        #expect(ready.replayEpoch == "abc")
        #expect(await client.state == .connected)
        #expect(await client.capabilities?.serverRequests == ["approval", "clarify"])
    }

    @Test func connectFailsWhenReadyNeverArrives() async throws {
        let transport = FakeTransport()
        var configuration = GatewayClient.Configuration()
        configuration.readyTimeout = .milliseconds(50)
        let client = GatewayClient(transport: transport, configuration: configuration)
        await #expect(throws: GatewayClientError.readyTimeout) { try await client.connect() }
        #expect(await client.state == .closed)
        #expect(transport.isClosed)
    }

    @Test func connectPropagatesTransportHandshakeFailure() async throws {
        let transport = FakeTransport(connectError: TransportError.handshakeFailed("403"))
        let client = GatewayClient(transport: transport)
        await #expect(throws: TransportError.handshakeFailed("403")) { try await client.connect() }
        #expect(await client.state == .closed)
    }

    @Test func correlatesOutOfOrderResponsesByID() async throws {
        let (client, transport, _) = try await connectedClient()

        async let first = client.call("one")
        let firstFrame = await transport.nextSent()
        async let second = client.call("two")
        let secondFrame = await transport.nextSent()
        #expect(firstFrame["method"] == "one")
        #expect(secondFrame["method"] == "two")
        #expect(firstFrame["id"] != secondFrame["id"])

        transport.respond(to: secondFrame, result: "second")
        transport.respond(to: firstFrame, result: "first")
        #expect(try await first == "first")
        #expect(try await second == "second")
    }

    @Test func errorResponseThrowsRPCError() async throws {
        let (client, transport, _) = try await connectedClient()
        let result = Task { try await client.resumeSession(storedSessionID: "missing") }
        let frame = await transport.nextSent()
        #expect(frame["method"] == "session.resume")
        #expect(frame["params"] == ["session_id": "missing"])
        transport.respondError(to: frame, code: 4001, message: "session not found")
        await #expect(throws: RPCError(code: 4001, message: "session not found")) { try await result.value }
    }

    @Test func callTimesOut() async throws {
        let (client, transport, _) = try await connectedClient()
        let result = Task { try await client.call("slow", timeout: .milliseconds(50)) }
        _ = await transport.nextSent()
        await #expect(throws: GatewayClientError.timeout(method: "slow")) { try await result.value }
    }

    @Test func typedMethodsEncodeParamsAndDecodeResults() async throws {
        let (client, transport, _) = try await connectedClient()

        async let sessions = client.listSessions(limit: 5)
        let listFrame = await transport.nextSent()
        #expect(listFrame["method"] == "session.list")
        #expect(listFrame["params"] == ["limit": 5])
        transport.respond(to: listFrame, result: ["sessions": [
            ["id": "s1", "title": "Hello", "preview": "hi", "started_at": 1_700_000_000.5, "message_count": 3,
             "source": "tui", "future_field": true],
        ]])
        let rows = try await sessions
        #expect(rows.map(\.id) == ["s1"])
        #expect(rows.first?.messageCount == 3)

        async let submit = client.submitPrompt(sessionID: "sid-1", text: "hello")
        let submitFrame = await transport.nextSent()
        #expect(submitFrame["method"] == "prompt.submit")
        #expect(submitFrame["params"] == ["session_id": "sid-1", "text": "hello"])
        transport.respond(to: submitFrame, result: ["status": "streaming", "user_row_id": 12])
        #expect(try await submit.status == "streaming")
    }

    @Test func dispatchesTypedEventsAndTracksSeq() async throws {
        let (client, transport, recorder) = try await connectedClient()

        transport.sendEvent("message.delta", seq: 1, payload: ["text": "Hel"])
        transport.sendEvent("tool.start", seq: 2, payload: ["tool_id": "t1", "name": "terminal", "context": "ls"])
        transport.sendEvent("message.delta", seq: 2, payload: ["text": "dup"])  // duplicate seq: dropped
        transport.sendEvent("some.future.event", seq: 3, payload: ["x": 1])

        let delta = try #require(await recorder.nextEvent())
        #expect(delta.kind == .messageDelta(StreamDelta(text: "Hel")))
        let tool = try #require(await recorder.nextEvent())
        guard case .toolStart(let start) = tool.kind else { Issue.record("expected tool.start"); return }
        #expect(start.toolID == "t1")
        #expect(start.context == "ls")
        let future = try #require(await recorder.nextEvent())
        #expect(future.type == "some.future.event")
        #expect(future.kind == .unknown)
        #expect(await client.lastSeq["sid-1"] == 3)
    }

    @Test func deliversSupportedServerRequestsAndSendsAnswers() async throws {
        let (client, transport, recorder) = try await connectedClient()

        transport.serverSends([
            "jsonrpc": "2.0", "id": "srq-aaaaaaaaaaaa", "method": "approval",
            "params": ["session_id": "sid-1", "request_id": "ap-1", "command": "rm -rf build",
                       "description": "recursive delete", "choices": ["once", "session", "always", "deny"]],
        ])
        guard case .serverRequest(let request)? = await recorder.next() else {
            Issue.record("expected server request"); return
        }
        #expect(request.id == "srq-aaaaaaaaaaaa")
        #expect(!request.replayed)
        guard case .approval(let approval) = request.kind else { Issue.record("expected approval"); return }
        #expect(approval.command == "rm -rf build")
        #expect(approval.offeredChoices == [.once, .session, .always, .deny])

        try await client.answer(request, approval: ApprovalAnswer(choice: .once))
        let answer = await transport.nextSent()
        #expect(answer == ["jsonrpc": "2.0", "id": "srq-aaaaaaaaaaaa", "result": ["choice": "once"]])
    }

    @Test func clarifyAnswerEncodesNullForSkippedQuestions() async throws {
        let (client, transport, recorder) = try await connectedClient()
        transport.serverSends([
            "jsonrpc": "2.0", "id": "srq-c", "method": "clarify",
            "params": ["session_id": "sid-1", "questions": [
                ["qid": "q1", "question": "Which?", "choices": ["a", "b"], "multi_select": false],
                ["qid": "q2", "question": "Why?"],
            ]],
        ])
        guard case .serverRequest(let request)? = await recorder.next(),
            case .clarify(let clarify) = request.kind
        else { Issue.record("expected clarify"); return }
        #expect(clarify.questions.map(\.qid) == ["q1", "q2"])

        try await client.answer(request, clarify: ClarifyAnswer(answers: ["q1": "a", "q2": nil]))
        let answer = await transport.nextSent()
        #expect(answer["result"] == ["answers": ["q1": "a", "q2": nil]])
    }

    /// S4: window-owned bridges get 4404 ("not shown here") so a Desktop
    /// window sharing the session can still answer; any other error code is a
    /// final answer. Everything else unsupported gets -32601.
    @Test(arguments: [
        ("terminal.read", 4404), ("preview.read", 4404), ("preview.act", 4404), ("window.read", 4404),
        ("tour", 4404), ("vault.code", -32601), ("display.install.sudo", -32601), ("brand.new", -32601),
    ])
    func declinesUnsupportedServerRequests(method: String, code: Int) async throws {
        let (client, transport, _) = try await connectedClient()
        transport.serverSends(["jsonrpc": "2.0", "id": "srq-t", "method": .string(method), "params": ["session_id": "sid-1"]])
        let reply = await transport.nextSent()
        withExtendedLifetime(client) {}
        #expect(reply["id"] == "srq-t")
        #expect(reply["result"] == nil)
        #expect(reply["error"]?["code"] == .number(Double(code)))
    }

    @Test func redeliverMarksReplayedAndSkipsDuplicates() async throws {
        let (client, transport, recorder) = try await connectedClient()
        transport.serverSends(["jsonrpc": "2.0", "id": "srq-1", "method": "sudo", "params": ["session_id": "sid-1"]])
        guard case .serverRequest(let live)? = await recorder.next() else { Issue.record("expected request"); return }
        #expect(live.id == "srq-1")

        await client.redeliver([
            OpenRequestEntry(id: "srq-1", method: "sudo", params: ["session_id": "sid-1"]),
            OpenRequestEntry(id: "srq-2", method: "secret",
                             params: ["session_id": "sid-1", "env_var": "API_KEY", "prompt": "Key?"]),
        ])
        guard case .serverRequest(let replayed)? = await recorder.next() else { Issue.record("expected request"); return }
        #expect(replayed.id == "srq-2")
        #expect(replayed.replayed)
        guard case .secret(let secret) = replayed.kind else { Issue.record("expected secret"); return }
        #expect(secret.envVar == "API_KEY")
    }

    private static let activateResult: JSONValue = [
        "session_id": "sid-1", "session_key": "stored-1", "message_count": 0, "messages": [],
        "info": [:], "running": true,
    ]

    /// B1: the fast path must rebind the session (`session.activate`) BEFORE
    /// asking for missed events, and hold back live events until replayed.
    @Test func reattachActivatesThenReplaysInSeqOrder() async throws {
        let (client, transport, recorder) = try await connectedClient()

        async let reattach = client.reattach(sessionID: "sid-1", lastSeen: 4)
        let activate = await transport.nextSent()
        #expect(activate["method"] == "session.activate")
        #expect(activate["params"] == ["session_id": "sid-1", "omit_messages": true])
        transport.respond(to: activate, result: Self.activateResult)

        let since = await transport.nextSent()
        #expect(since["method"] == "session.events.since")
        #expect(since["params"] == ["session_id": "sid-1", "last_seen": 4])

        // Live events now flow to this socket; they must wait for the replay.
        transport.sendEvent("message.delta", seq: 6, payload: ["text": "B"])  // also in the ring: dedup
        transport.sendEvent("message.delta", seq: 7, payload: ["text": "C"])
        transport.respond(to: since, result: [
            "events": [
                ["type": "message.delta", "session_id": "sid-1", "seq": 5, "payload": ["text": "A"]],
                ["type": "message.delta", "session_id": "sid-1", "seq": 6, "payload": ["text": "B"]],
            ],
            "latest_seq": 6, "truncated": false, "count": 2, "epoch": "epoch-1",
            "open_requests": [["id": "srq-9", "method": "approval",
                               "params": ["session_id": "sid-1", "request_id": "r"]]],
        ])
        let result = try await reattach
        #expect(result.isComplete)
        #expect(result.snapshot.storedKey == "stored-1")

        var texts: [String] = []
        for _ in 0..<3 {
            if case .messageDelta(let delta)? = await recorder.nextEvent()?.kind { texts.append(delta.text) }
        }
        #expect(texts == ["A", "B", "C"])
        guard case .serverRequest(let request)? = await recorder.next() else { Issue.record("expected request"); return }
        #expect(request.id == "srq-9" && request.replayed)
    }

    /// S1: `events.since` answers an unknown/reaped sid or another process
    /// with an *empty success*; the client must not call that "caught up".
    @Test(arguments: [
        ("epoch-OTHER", 9, false),  // backend restarted between ready and the call
        ("epoch-1", 2, false),  // server seq behind our watermark: counter was reset
        ("epoch-1", 4, true),
    ])
    func reattachValidatesReplay(epoch: String, latestSeq: Int, complete: Bool) async throws {
        let (client, transport, _) = try await connectedClient()
        async let reattach = client.reattach(sessionID: "sid-1", lastSeen: 4)
        transport.respond(to: await transport.nextSent(), result: Self.activateResult)
        transport.respond(to: await transport.nextSent(), result: [
            "events": [], "latest_seq": .number(Double(latestSeq)), "truncated": false, "count": 0,
            "epoch": .string(epoch), "open_requests": [],
        ])
        #expect(try await reattach.isComplete == complete)
        #expect(await client.lastSeq["sid-1"] == (complete ? 4 : nil))
    }

    /// B1/S1: activate on a session that is no longer live fails loudly (4007)
    /// instead of the empty success `events.since` would give.
    @Test func reattachSurfacesLostSession() async throws {
        let (client, transport, _) = try await connectedClient()
        let reattach = Task { try await client.reattach(sessionID: "sid-1", lastSeen: 4) }
        transport.respondError(to: await transport.nextSent(), code: 4007, message: "session no longer live; retry resume")
        await #expect(throws: RPCError(code: 4007, message: "session no longer live; retry resume")) {
            try await reattach.value
        }
        // The hold-back buffer is gone: live events flow again.
        let next = Task { try await client.reattach(sessionID: "sid-1", lastSeen: 4) }
        #expect(await transport.nextSent()["method"] == "session.activate")
        next.cancel()
    }

    @Test func concurrentReattachForSameSessionIsRejected() async throws {
        let (client, transport, _) = try await connectedClient()
        let first = Task { try await client.reattach(sessionID: "sid-1", lastSeen: 1) }
        _ = await transport.nextSent()
        await #expect(throws: GatewayClientError.replayInProgress) {
            try await client.reattach(sessionID: "sid-1", lastSeen: 1)
        }
        first.cancel()
    }

    @Test func connectionDropFailsPendingCallsAndNotifiesSubscribers() async throws {
        let (client, transport, recorder) = try await connectedClient()
        let pending = Task { try await client.call("session.history") }
        _ = await transport.nextSent()
        transport.serverDrops()

        await #expect(throws: GatewayClientError.self) { try await pending.value }
        guard case .disconnected(let error)? = await recorder.next() else { Issue.record("expected disconnect"); return }
        #expect(error != nil)
        #expect(await client.state == .closed)
        await #expect(throws: GatewayClientError.notConnected) { try await client.call("x") }
    }

    @Test func heartbeatPingsAndDropsSilentConnection() async throws {
        let transport = FakeTransport()
        var configuration = GatewayClient.Configuration()
        configuration.heartbeatInterval = .milliseconds(20)
        configuration.heartbeatTimeout = .milliseconds(200)
        let client = GatewayClient(transport: transport, configuration: configuration)
        let recorder = InboundRecorder(await client.inbound())
        async let ready = client.connect()
        await transport.completeHandshake(heartbeat: true)
        _ = try await ready

        let ping = await transport.nextSent()
        #expect(ping["method"] == "gateway.ping")
        #expect(ping["id"]?.stringValue?.hasPrefix("heartbeat-") == true)

        // Stay silent: the client must give up on its own.
        while let item = await recorder.next() {
            if case .disconnected(let error) = item {
                #expect(error as? GatewayClientError == .heartbeatTimeout)
                break
            }
        }
        #expect(transport.isClosed)
    }
}
