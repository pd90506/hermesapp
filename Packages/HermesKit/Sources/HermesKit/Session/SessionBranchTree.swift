import Foundation
import HermesProtocol

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// A row of the session list: a session and, for a branch shown under the chat it was
/// branched from, Desktop's stem ("├─ " or, for the last, "└─ ").
public struct SessionTreeRow: Sendable, Hashable, Identifiable {
    public var entry: HistoryEntry
    public var branchStem: String?

    public var id: HistoryEntry.ID { entry.id }

    public init(entry: HistoryEntry, branchStem: String? = nil) {
        self.entry = entry
        self.branchStem = branchStem
    }
}

/// Branches nested under their parent, as Desktop's sidebar shows them
/// (`flattenSessionsWithBranches`, `apps/desktop/src/lib/session-branch-tree.ts:85-200`).
///
/// A branch's copied messages keep the parent's timestamps (`_BRANCH_COPY_FIELDS`,
/// `tui_gateway/methods_session_branch.py:57-65`), and the list sorts by the newest message
/// (`_sql_freshest_of`, `hermes_state_common.py:257-268`), so a branch from an old reply
/// lands at that reply's time, far down a long list. Nested, it shows under its parent.
public enum SessionBranchTree {
    /// `entries` in the list's order (most recent first); `parents` maps a branch's stored
    /// id to its parent's. A branch whose parent is not listed stays where it is.
    public static func flatten(_ entries: [HistoryEntry], parents: [String: String]) -> [SessionTreeRow] {
        guard entries.count > 1, !parents.isEmpty else { return entries.map { SessionTreeRow(entry: $0) } }

        // A parent named by its compression tip is the row that lists that lineage.
        var indexByID: [String: Int] = [:]
        for (index, entry) in entries.enumerated() {
            if let tip = entry.summary.resolvedID, !tip.isEmpty, indexByID[tip] == nil { indexByID[tip] = index }
            indexByID[entry.summary.id] = index
        }
        var children: [Int: [Int]] = [:]
        var nested = Set<Int>()
        for (index, entry) in entries.enumerated() {
            guard let parentID = parents[entry.summary.id] ?? entry.summary.resolvedID.flatMap({ parents[$0] }),
                let parent = indexByID[parentID], parent != index
            else { continue }
            nested.insert(index)
            children[parent, default: []].append(index)  // in list order: most recent first
        }

        // A group sorts by its most recent member, so a busy branch lifts its parent too
        // (`groupRecency`, :146-167). Earlier in the list is more recent.
        var groupFirst: [Int: Int] = [:]
        func first(_ index: Int, visiting: Set<Int> = []) -> Int {
            if let known = groupFirst[index] { return known }
            guard !visiting.contains(index) else { return index }  // a parent cycle
            let value = (children[index] ?? []).reduce(index) { min($0, first($1, visiting: visiting.union([index]))) }
            groupFirst[index] = value
            return value
        }
        let roots = entries.indices.filter { !nested.contains($0) }
            .sorted { (first($0), $0) < (first($1), $1) }

        var rows: [SessionTreeRow] = []
        var seen = Set<Int>()
        func emit(_ index: Int, stem: String?) {
            guard seen.insert(index).inserted else { return }
            rows.append(SessionTreeRow(entry: entries[index], branchStem: stem))
            let kids = children[index] ?? []
            for (position, kid) in kids.enumerated() {
                emit(kid, stem: position == kids.count - 1 ? "└─ " : "├─ ")
            }
        }
        roots.forEach { emit($0, stem: nil) }
        // Anything a cycle kept out of the walk is still listed.
        for index in entries.indices where !seen.contains(index) {
            rows.append(SessionTreeRow(entry: entries[index]))
        }
        return rows
    }

    /// The parent a listed row was branched from, by Desktop's rule (`forkParentId`,
    /// :28-40): none for a `/new` or reset child (`_reset_from`), else `_branched_from`,
    /// else `parent_session_id`.
    static func parent(of row: SessionLinkRow) -> String? {
        if row.resetFrom?.trimmed.isEmpty == false { return nil }
        if let branched = row.branchedFrom?.trimmed, !branched.isEmpty { return branched }
        let parent = row.parentSessionID?.trimmed
        return parent?.isEmpty == false ? parent : nil
    }
}

/// The lineage fields of a `GET /api/sessions` row (`hermes_cli/web_routers/sessions.py:177-235`):
/// the `/new` and `/branch` markers lifted out of `model_config` (`_session_row_dict`,
/// `hermes_state.py:530-560`). `session.list` rows carry neither.
struct SessionLinkRow: Decodable, Sendable {
    var id: String
    var parentSessionID: String?
    var branchedFrom: String?
    var resetFrom: String?

    enum CodingKeys: String, CodingKey {
        case id
        case parentSessionID = "parent_session_id"
        case branchedFrom = "_branched_from"
        case resetFrom = "_reset_from"
    }
}

/// Which listed sessions are branches, and of what, over the dashboard's REST API, with the
/// same credential as the socket.
public protocol SessionLinkSource: Sendable {
    /// The most recently started sessions of `profile` (branches are new when made, so the
    /// ones not nested yet are here), each with the stored id it was branched from, if any.
    func recentSessionLinks(profile: String) async throws -> [String: String?]
}

extension DashboardClient {
    /// The dashboard's page cap (`le=100`, `sessions.py:174-181`).
    static let sessionLinksLimit = 100

    /// `GET /api/sessions?profile=&order=created&limit=100`: newest started first.
    public func recentSessionLinks(profile: String, bearer: String? = nil) async throws -> [String: String?] {
        var request = request(path: "/api/sessions", method: "GET", query: [
            URLQueryItem(name: "profile", value: profile),
            URLQueryItem(name: "order", value: "created"),
            URLQueryItem(name: "limit", value: String(Self.sessionLinksLimit)),
            URLQueryItem(name: "offset", value: "0"),
            URLQueryItem(name: "archived", value: "exclude"),
        ])
        if let bearer { request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization") }
        let page: LinksPage = try await send(request)
        var links: [String: String?] = [:]
        for row in page.sessions { links[row.id] = SessionBranchTree.parent(of: row) }
        return links
    }

    private struct LinksPage: Decodable { var sessions: [SessionLinkRow] }
}

extension DashboardConnector: SessionLinkSource {
    public func recentSessionLinks(profile: String) async throws -> [String: String?] {
        try await authorized { try await dashboard.recentSessionLinks(profile: profile, bearer: $0) }
    }
}
