import Foundation
import HermesKit
import HermesProtocol
import Testing

@testable import HermesBridge

/// `searchSessions` and its `search` snapshot: the profile's chats whose messages,
/// title or id match, as the sidebar's search shows them, and a hit the list doesn't
/// hold opening as a chat anyway.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct BridgeSearchTests {
    private struct FakeSearchSource: SessionSearchSource {
        let hits: [SessionSearchHit]
        func searchSessions(_ query: String, profile: String, sources: [String], limit: Int) async throws
            -> [SessionSearchHit] { hits }
    }

    private func hit(_ sessionID: String, snippet: String = "", role: String? = nil) -> SessionSearchHit {
        SessionSearchHit(sessionID: sessionID, title: "Titled chat", snippet: snippet, role: role,
                         source: "desktop", sessionStarted: 1_700_000_000, lastActive: 1_700_000_500)
    }

    @Test func resultsCarryTheMatchRunsAndTheBotChatFlag() async throws {
        let outbox = Outbox()
        let source = FakeSearchSource(hits: [
            hit("coder-chat", snippet: "say >>>hello<<< there"),
            hit("stored-9", snippet: "plain text", role: "user"),
        ])
        let bridge = try await Bridge.connected(BridgeServer(), outbox: outbox, search: source)
        try await bridge.receive(#"{"id":"s1","method":"searchSessions","params":{"query":"hello"}}"#)
        #expect(await eventually { outbox.last("search")?["query"] as? String == "hello" })
        let search = try #require(outbox.last("search"))
        #expect(search["query"] as? String == "hello")
        #expect(search["isAvailable"] as? Bool == true)
        let results = try #require(search["results"] as? [[String: Any]])
        #expect(results.count == 2)
        let botChat = results[0]
        // The hit is the bot's canonical chat: it opens as the Bot Chat, with its own title.
        #expect(botChat["isBotChat"] as? Bool == true)
        #expect(botChat["title"] as? String == "Bot Chat")
        let plain = results[1]
        #expect(plain["isBotChat"] as? Bool == false)
        #expect(plain["title"] as? String == "Titled chat")
        #expect(plain["id"] as? String == "coder/stored-9")
        #expect(plain["role"] as? String == "user")
        // The matched words are marked; the FTS markers never show.
        let segments = plain["segments"] as? [[String: Any]] ?? []
        #expect(segments.map { $0["text"] as? String } == ["plain text"])
        let marked = botChat["segments"] as? [[String: Any]] ?? []
        #expect(marked.map { $0["text"] as? String } == ["say ", "hello", " there"])
        #expect(marked.map { $0["isMatch"] as? Bool } == [false, true, false])
    }

    @Test func aHitTheListDoesNotHoldOpensAsAChat() async throws {
        let outbox = Outbox()
        let server = BridgeServer()
        let source = FakeSearchSource(hits: [hit("stored-9")])
        let bridge = try await Bridge.connected(server, outbox: outbox, search: source)
        try await bridge.receive(#"{"id":"s1","method":"searchSessions","params":{"query":"hello"}}"#)
        #expect(await eventually { outbox.last("search")?["query"] as? String == "hello" })
        server.on("session.resume") { _ in BridgeServer.resumed(sid: "rt-9", key: "stored-9") }
        try await bridge.receive(#"{"id":"o1","method":"openSession","params":{"id":"coder/stored-9"}}"#)
        #expect(outbox.last["error"] == nil)
        let chat = try #require(outbox.last("chat"))
        #expect(chat["sessionID"] as? String == "rt-9")
        #expect(chat["storedSessionID"] as? String == "stored-9")
        // The resume carries the hit's stored id; the answer's own key is session_key.
        let resume = try #require(server.log.requests("session.resume").last)
        #expect(resume["params"]?["session_id"]?.stringValue == "stored-9")
    }

    @Test func aSessionNeitherListedNorSearchedIsRefused() async throws {
        let outbox = Outbox()
        let bridge = try await Bridge.connected(BridgeServer(), outbox: outbox)
        try await bridge.receive(#"{"id":"o1","method":"openSession","params":{"id":"coder/nope"}}"#)
        #expect(outbox.last["error"] as? String == "no session coder/nope in the list")
    }

    @Test func anEmptyQueryClearsTheResults() async throws {
        let outbox = Outbox()
        let source = FakeSearchSource(hits: [hit("stored-9")])
        let bridge = try await Bridge.connected(BridgeServer(), outbox: outbox, search: source)
        try await bridge.receive(#"{"id":"s1","method":"searchSessions","params":{"query":"hello"}}"#)
        try await bridge.receive(#"{"id":"s2","method":"searchSessions","params":{"query":""}}"#)
        #expect(await eventually { outbox.last("search")?["query"] as? String == "" })
        let search = try #require(outbox.last("search"))
        #expect((search["results"] as? [Any])?.isEmpty == true)
        #expect(search["query"] as? String == "")
    }
}
