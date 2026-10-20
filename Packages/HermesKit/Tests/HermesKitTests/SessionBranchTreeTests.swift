import Foundation
import HermesProtocol
import Synchronization
import Testing

@testable import HermesKit

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// Branches nested under the chat they came from, as Desktop's sidebar shows them
// (`apps/desktop/src/lib/session-branch-tree.ts`).

private func entry(_ id: String, tip: String? = nil) -> HistoryEntry {
    var summary = SessionSummary(id: id, title: id)
    summary.resolvedID = tip
    return HistoryEntry(profile: "coder", summary: summary)
}

private func ids(_ rows: [SessionTreeRow]) -> [String] { rows.map(\.entry.summary.id) }

@Suite struct SessionBranchTreeTests {
    /// A branch from an old reply is listed at that reply's time, far below the newest
    /// chats; nested, it shows under its parent, the last one with "└─ ".
    @Test func branchesShowUnderTheirParent() {
        let list = ["new", "parent", "other", "older", "branch-2", "branch-1"].map { entry($0) }
        let rows = SessionBranchTree.flatten(list, parents: ["branch-1": "parent", "branch-2": "parent"])
        #expect(ids(rows) == ["new", "parent", "branch-2", "branch-1", "other", "older"])
        #expect(rows.map(\.branchStem) == [nil, nil, "├─ ", "└─ ", nil, nil])
    }

    /// The group sorts by its most recent member: a branch in use lifts its parent.
    @Test func aRecentBranchLiftsItsParent() {
        let list = ["branch", "new", "parent"].map { entry($0) }
        let rows = SessionBranchTree.flatten(list, parents: ["branch": "parent"])
        #expect(ids(rows) == ["parent", "branch", "new"])
    }

    /// A branch of a branch nests under its own parent.
    @Test func aBranchOfABranchNestsTwice() {
        let list = ["grandchild", "parent", "child"].map { entry($0) }
        let rows = SessionBranchTree.flatten(list, parents: ["child": "parent", "grandchild": "child"])
        #expect(ids(rows) == ["parent", "child", "grandchild"])
        #expect(rows.map(\.branchStem) == [nil, "└─ ", "└─ "])
    }

    /// A parent named by its compression tip is the row listing that lineage; a parent not
    /// listed (archived, deleted, hidden) leaves the branch where it is; so does a cycle.
    @Test func tipsUnlistedParentsAndCycles() {
        let list = [entry("branch"), entry("root", tip: "tip"), entry("orphan"), entry("a"), entry("b")]
        let rows = SessionBranchTree.flatten(list, parents: ["branch": "tip", "orphan": "gone", "a": "b", "b": "a"])
        #expect(ids(rows) == ["root", "branch", "orphan", "a", "b"])
        #expect(rows.map(\.branchStem) == [nil, "└─ ", nil, nil, nil])
    }

    /// Desktop's rule (`forkParentId`): a `/new` or reset child is not a branch.
    @Test func theParentFollowsDesktopsRule() throws {
        let json = #"""
            {"sessions":[{"id":"b","parent_session_id":"p","_branched_from":"p"},
                         {"id":"legacy","parent_session_id":"p"},
                         {"id":"reset","parent_session_id":"p","_reset_from":"p"},
                         {"id":"root","parent_session_id":null}]}
            """#
        struct Page: Decodable { var sessions: [SessionLinkRow] }
        let rows = try JSONDecoder().decode(Page.self, from: Data(json.utf8)).sessions
        #expect(rows.map(SessionBranchTree.parent(of:)) == ["p", "p", nil, nil])
    }
}

/// A `GET /api/sessions` row as the dashboard sends it with `compact_rows`, the markers
/// lifted out of `model_config` (`hermes_state.py:530-560`), `_strip_session_list_rows`
/// applied (`web_server_gateway.py:679-683`).
private let linksPage = #"""
    {"sessions":[
      {"id":"20261020_062000_ab12cd","source":"desktop","user_id":null,"model":"m","parent_session_id":"20261019_101500_ffee00",
       "started_at":1792477200.0,"ended_at":null,"end_reason":null,"message_count":4,"title":"Plan #2","archived":false,
       "pinned":false,"hidden":0,"preview":"first","last_active":1792390000.0,"_branched_from":"20261019_101500_ffee00",
       "is_active":false,"profile":"coder","is_default_profile":false},
      {"id":"20261019_101500_ffee00","source":"desktop","parent_session_id":null,"started_at":1792390000.0,
       "message_count":9,"title":"Plan","archived":false,"pinned":false,"preview":"first","last_active":1792400000.0,
       "is_active":false,"profile":"coder","is_default_profile":false}],
     "total":2,"limit":100,"offset":0,"storage":{}}
    """#

@Suite(.timeLimit(.minutes(1)))
struct SessionLinksTests {
    @Test func readsTheNewestStartedSessionsOfTheProfile() async throws {
        let http = FakeHTTP([.init(status: 200, body: linksPage)])
        let connector = DashboardConnector(endpoint: try GatewayEndpoint("https://hermes.example.ts.net"),
                                           credential: .bearer(accessToken: "at-1"), http: http,
                                           makeSocket: { _ in FakeTransport() })
        let links = try await connector.recentSessionLinks(profile: "coder")

        let request = try #require(http.requests.first)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer at-1")
        let url = try #require(request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) })
        #expect(url.path == "/api/sessions")
        #expect(url.queryItems == [
            URLQueryItem(name: "profile", value: "coder"), URLQueryItem(name: "order", value: "created"),
            URLQueryItem(name: "limit", value: "100"), URLQueryItem(name: "offset", value: "0"),
            URLQueryItem(name: "archived", value: "exclude"),
        ])
        #expect(links == ["20261020_062000_ab12cd": "20261019_101500_ffee00", "20261019_101500_ffee00": nil])
    }

    /// A branch made elsewhere (Desktop, the TUI) is nested once the dashboard says whose
    /// it is; rows already checked are not asked about again.
    @MainActor
    @Test func theListReadsWhichRowsAreBranches() async throws {
        let gateway = ScriptedGateway().withDefaults()
        gateway.on("profiles.list", result: [
            "profiles": [profileRowPayload("default", isDefault: true), profileRowPayload("coder")],
            "bot_mode_protocol": true, "install_id": "test",
        ])
        gateway.on("session.list", result: ["sessions": [sessionRow(id: "new"), sessionRow(id: "parent"),
                                                          sessionRow(id: "branch")]])
        let links = FakeLinks(["branch": "parent", "new": nil, "parent": nil])
        let connection = try await gateway.connect(links: links)
        try await connection.refreshBots()
        connection.selectListProfile("coder")
        await connection.refreshSessionList()

        #expect(await eventually { connection.sessionTree(connection.history).map(\.branchStem) == [nil, nil, "└─ "] })
        #expect(ids(connection.sessionTree(connection.history)) == ["new", "parent", "branch"])
        let reads = links.reads
        await connection.refreshSessionList()
        try await Task.sleep(for: .milliseconds(50))
        #expect(links.reads == reads)
        #expect(links.profiles.allSatisfy { $0 == "coder" })
    }
}

private final class FakeLinks: SessionLinkSource {
    private let state: Mutex<(links: [String: String?], profiles: [String])>

    init(_ links: [String: String?]) { state = Mutex((links, [])) }

    var reads: Int { state.withLock { $0.profiles.count } }
    var profiles: [String] { state.withLock { $0.profiles } }

    func recentSessionLinks(profile: String) async throws -> [String: String?] {
        state.withLock { state in
            state.profiles.append(profile)
            return state.links
        }
    }
}
