import Foundation
import HermesProtocol
import Testing

@testable import HermesKit

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct RevisitIdentityTests {
    private func connect() async throws -> (GatewayConnection, FakeTransport, PagedServer, FrameLog) {
        let server = PagedServer(store: FakeMessageStore(count: 300))
        let log = FrameLog()
        let (connection, transport) = try await server.connect(log: log)
        return (connection, transport, server, log)
    }

    private func request(_ method: String, in log: FrameLog) async -> JSONValue? {
        for _ in 0..<300 {
            if let found = log.requests(method).first { return found }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return nil
    }

    /// A reconcile on an older socket is replaced; a send waiting for it keeps waiting
    /// for the replacement, which may still move the chat.
    @Test func aSendWaitsThroughAReplacedReconcile() async throws {
        let (connection, transport, server, log) = try await connect()
        let first = try await connection.open(SessionSummary(id: "stored-1"))
        await settle(first)

        // A reconcile started on a socket that is no longer the connection's own; its
        // `session.activate` never answers.
        let stale = FakeTransport()
        stale.serve(log: FrameLog()) { method, params in method == "session.activate" ? nil : server.answer(method, params) }
        var configuration = GatewayClient.Configuration()
        configuration.heartbeatInterval = nil
        let staleClient = GatewayClient(transport: stale, configuration: configuration)
        _ = try await staleClient.connect()
        _ = connection.revisit(first, token: connection.beginSelection(), client: staleClient)

        let submits = log.requests("prompt.submit").count
        let sending = Task { try await first.send("hi") }
        try await Task.sleep(for: .milliseconds(50))

        // Replaced by one on the current socket, which is still binding the chat.
        _ = server.held.withLock { $0.insert("session.activate") }
        _ = connection.revisit(first, token: connection.beginSelection(), client: try #require(connection.client))
        let activate = try #require(await request("session.activate", in: log))
        try await Task.sleep(for: .milliseconds(100))
        #expect(log.requests("prompt.submit").count == submits)

        transport.respond(to: activate, result: try #require(server.answer("session.activate", activate["params"] ?? nil)))
        try await sending.value
        #expect(log.requests("prompt.submit").count == submits + 1)
        await staleClient.close()
    }

    /// A Bot Chat the registry no longer has is dropped, its draft with it.
    @Test func aDroppedChatTakesItsComposer() async throws {
        let (connection, _, server, _) = try await connect()
        let bot = try await connection.openBotChat(profile: "coder")
        await settle(bot)
        let first = try await connection.open(SessionSummary(id: "stored-1"))
        await settle(first)
        connection.composer(for: bot).draft = "for a chat that is gone"

        server.botChatGone.withLock { $0 = true }
        _ = try await connection.openBotChat(profile: "coder")
        await bot.revisitTask?.value

        #expect(connection.activeSession == nil)
        #expect(!connection.warmChats.contains { $0 === bot })
        #expect(connection.composer(for: bot).draft.isEmpty)
    }
}
