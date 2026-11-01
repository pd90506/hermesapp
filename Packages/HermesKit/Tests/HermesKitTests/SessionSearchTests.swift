import Foundation
import HermesProtocol
import Synchronization
import Testing

@testable import HermesKit

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// A content hit as `search_sessions` answers it: `hit_payload` enriched by
/// `add_lineage_result` from the sessions row (`hermes_cli/web_routers/sessions.py:353-405`).
private let contentHit = #"""
    {"snippet":"we picked >>>nimbus<<< for the\nrelease name","role":"assistant","source":"desktop",
     "model":"test-model","session_started":1761800000.5,"last_active":1761900000.0,
     "session_id":"20261030_101010_abc","lineage_root":"20261030_090909_root","profile":"coder",
     "is_default_profile":false,"id":"20261030_101010_abc","title":"Release naming",
     "started_at":1761800000.5,"ended_at":null,"is_active":false,"message_count":12,
     "tool_call_count":0,"input_tokens":10,"output_tokens":20,"preview":"what should we call it",
     "parent_session_id":"20261030_090909_root","archived":false}
    """#

@Suite struct SessionSearchHitTests {
    @Test func decodesTheEnrichedHit() throws {
        let hit = try JSONDecoder().decode(SessionSearchHit.self, from: Data(contentHit.utf8))
        #expect(hit.sessionID == "20261030_101010_abc")
        #expect(hit.lineageRoot == "20261030_090909_root")
        #expect(hit.title == "Release naming")
        #expect(hit.role == "assistant")
        #expect(hit.messageCount == 12)
        #expect(hit.date == Date(timeIntervalSince1970: 1_761_900_000))
    }

    @Test func toleratesAnIDHitWithoutARow() throws {
        let json = #"{"snippet":"Session ID: abc","role":null,"source":null,"session_started":null,"session_id":"abc","id":"abc"}"#
        let hit = try JSONDecoder().decode(SessionSearchHit.self, from: Data(json.utf8))
        #expect(hit.sessionID == "abc")
        #expect(hit.date == nil)
        #expect(hit.title == nil)
    }

    @Test func snippetSplitsAtTheMarkers() {
        let hit = SessionSearchHit(sessionID: "a", snippet: "...we picked >>>nimbus<<< and >>>cirrus<<<\nlater")
        #expect(hit.snippetSegments == [
            .init(text: "...we picked ", isMatch: false), .init(text: "nimbus", isMatch: true),
            .init(text: " and ", isMatch: false), .init(text: "cirrus", isMatch: true),
            .init(text: " later", isMatch: false),
        ])
        #expect(hit.plainSnippet == "...we picked nimbus and cirrus later")
        // An unclosed marker (a cut snippet) matches to the end.
        #expect(SessionSearchHit(sessionID: "a", snippet: "a >>>b").snippetSegments ==
                [.init(text: "a ", isMatch: false), .init(text: "b", isMatch: true)])
    }
}

@Suite(.timeLimit(.minutes(1))) struct SessionSearchRequestTests {
    @Test func asksForTheProfilesListedSources() async throws {
        let http = FakeHTTP([.init(status: 200, body: "{\"results\":[\(contentHit)]}")])
        let connector = DashboardConnector(endpoint: try GatewayEndpoint("https://hermes.example.ts.net"),
                                           credential: .bearer(accessToken: "tok"), http: http)
        let hits = try await connector.searchSessions("nimbus cloud", profile: "coder", sources: ["desktop", "tui"], limit: 50)
        #expect(hits.map(\.sessionID) == ["20261030_101010_abc"])
        let request = try #require(http.requests.first)
        #expect(request.httpMethod == "GET")
        #expect(request.url?.absoluteString ==
                "https://hermes.example.ts.net/api/sessions/search?q=nimbus%20cloud&profile=coder&limit=50&sources=desktop,tui")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer tok")
    }
}

/// Scripted hits per query, recording every search.
final class FakeSearchSource: SessionSearchSource, @unchecked Sendable {
    private let state: Mutex<(hits: [String: [SessionSearchHit]], calls: [String])>
    var failure: (any Error)?

    init(_ hits: [String: [SessionSearchHit]]) {
        state = Mutex((hits, []))
    }

    var calls: [String] { state.withLock { $0.calls } }

    func searchSessions(_ query: String, profile: String, sources: [String], limit: Int) async throws -> [SessionSearchHit] {
        state.withLock { $0.calls.append("\(profile): \(query) [\(sources.joined(separator: ","))]") }
        if let failure { throw failure }
        return state.withLock { $0.hits[query] ?? [] }
    }
}

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct SessionSearchTests {
    private func connect(_ source: FakeSearchSource?) async throws -> GatewayConnection {
        let gateway = ScriptedGateway()
        gateway.on("profiles.list", result: [
            "profiles": [profileRowPayload("default", isDefault: true), profileRowPayload("coder")],
            "bot_mode_protocol": true, "install_id": "test",
        ])
        gateway.on("session.list", result: ["sessions": [
            ["id": "listed", "title": "Listed chat", "source": "desktop", "message_count": 4],
        ]])
        let connection = try await gateway.withDefaults().connect(search: source)
        try #require(await eventually { connection.listsRefreshTask == nil && !connection.listsRefreshQueued })
        connection.selectListProfile("coder")
        await connection.refreshSessionList()
        return connection
    }

    @Test func hitsBecomeRowsTheListOpens() async throws {
        let source = FakeSearchSource(["nimbus": [
            SessionSearchHit(sessionID: "listed", title: "Listed chat", snippet: ">>>nimbus<<<", source: "desktop"),
            SessionSearchHit(sessionID: "older", title: "Older chat", snippet: "a >>>nimbus<<<", source: "tui"),
            SessionSearchHit(sessionID: "tg", snippet: ">>>nimbus<<<", source: "telegram"),
            SessionSearchHit(sessionID: "bot", title: "Bot Chat", snippet: ">>>nimbus<<<", source: "desktop"),
        ]])
        let connection = try await connect(source)
        await connection.searchSessions("  nimbus ")
        #expect(source.calls == ["coder: nimbus [desktop,tui]"])
        #expect(connection.search.query == "nimbus")
        let results = connection.search.results
        #expect(results.map(\.entry.summary.id) == ["listed", "older", "bot"], "a source the list never shows is left out")
        // The listed row itself, so it opens, pins and renames as that row does.
        #expect(results[0].entry == connection.history.first)
        #expect(results[1].entry.profile == "coder")
        #expect(results[1].entry.summary.title == "Older chat")
        #expect(results.map(\.isBotChat) == [false, false, true])
        #expect(connection.search.result(id: "coder/older")?.entry.summary.id == "older")
    }

    @Test func hiddenSourcesStayHidden() async throws {
        let source = FakeSearchSource(["x": [SessionSearchHit(sessionID: "t", snippet: "x", source: "tui")]])
        let connection = try await connect(source)
        connection.sourceSettings.setHidden(true, "tui")
        await connection.searchSessions("x")
        #expect(connection.search.results.isEmpty)
    }

    @Test func clearingAndSwitchingProfilesDropTheResults() async throws {
        let source = FakeSearchSource(["x": [SessionSearchHit(sessionID: "listed", snippet: "x", source: "desktop")]])
        let connection = try await connect(source)
        await connection.searchSessions("x")
        #expect(connection.search.results.count == 1)
        await connection.searchSessions(" ")
        #expect(connection.search.results.isEmpty)
        #expect(connection.search.query.isEmpty)

        await connection.searchSessions("x")
        connection.selectListProfile("default")
        #expect(connection.search.results.isEmpty)
        #expect(source.calls.count == 2, "an empty query is never sent")
    }

    @Test func failuresSayWhy() async throws {
        let source = FakeSearchSource([:])
        source.failure = DashboardError.http(status: 500, body: #"{"detail":"Search failed"}"#)
        let connection = try await connect(source)
        await connection.searchSessions("x")
        #expect(connection.search.error == "The dashboard answered HTTP 500.")
        #expect(!connection.search.isSearching)
    }

    @Test func withoutRESTSearchIsUnavailable() async throws {
        let connection = try await connect(nil)
        await connection.searchSessions("x")
        #expect(!connection.search.isAvailable)
    }
}
