import Foundation
import HermesProtocol
import Observation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// A hit of the dashboard's session search (`GET /api/sessions/search`,
/// `hermes_cli/web_routers/sessions.py:286-463`): a stored conversation whose id, messages
/// (FTS5) or title match, one per compression lineage, resolved to the lineage's live tip.
public struct SessionSearchHit: Sendable, Hashable, Decodable {
    /// The live compression tip of the matched conversation: resume by this id.
    public var sessionID: String
    /// The lineage root, stable across compression.
    public var lineageRoot: String?
    public var title: String?
    /// The matched text, terms wrapped in `>>>` / `<<<` (`hermes_state_search.py:945`);
    /// for an id or title match, the session's preview.
    public var snippet: String
    /// Whose message matched (`user`, `assistant`, …); `nil` for id and title matches.
    public var role: String?
    public var source: String?
    public var model: String?
    /// Unix seconds.
    public var sessionStarted: Double?
    /// Unix seconds; only on hits backed by a sessions row.
    public var lastActive: Double?
    public var messageCount: Int?
    public var preview: String?
    public var archived: Bool?

    public init(sessionID: String, title: String? = nil, snippet: String = "", role: String? = nil,
                source: String? = nil, sessionStarted: Double? = nil, lastActive: Double? = nil) {
        self.sessionID = sessionID
        self.title = title
        self.snippet = snippet
        self.role = role
        self.source = source
        self.sessionStarted = sessionStarted
        self.lastActive = lastActive
    }

    enum CodingKeys: String, CodingKey {
        case title, snippet, role, source, model, preview, archived
        case sessionID = "session_id"
        case lineageRoot = "lineage_root"
        case sessionStarted = "session_started"
        case lastActive = "last_active"
        case messageCount = "message_count"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sessionID = try container.decode(String.self, forKey: .sessionID)
        lineageRoot = try? container.decodeIfPresent(String.self, forKey: .lineageRoot)
        title = try? container.decodeIfPresent(String.self, forKey: .title)
        snippet = (try? container.decodeIfPresent(String.self, forKey: .snippet)) ?? ""
        role = try? container.decodeIfPresent(String.self, forKey: .role)
        source = try? container.decodeIfPresent(String.self, forKey: .source)
        model = try? container.decodeIfPresent(String.self, forKey: .model)
        sessionStarted = try? container.decodeIfPresent(Double.self, forKey: .sessionStarted)
        lastActive = try? container.decodeIfPresent(Double.self, forKey: .lastActive)
        messageCount = try? container.decodeIfPresent(Int.self, forKey: .messageCount)
        preview = try? container.decodeIfPresent(String.self, forKey: .preview)
        archived = try? container.decodeIfPresent(Bool.self, forKey: .archived)
    }

    /// A run of the snippet, matched or not.
    public struct Segment: Sendable, Hashable {
        public var text: String
        public var isMatch: Bool
    }

    /// The snippet on one line, split at the FTS markers, which never show (Desktop strips
    /// them, `apps/desktop/src/app/chat/sidebar/index.tsx:286-293`).
    public var snippetSegments: [Segment] {
        let flat = snippet.split(whereSeparator: \.isNewline).joined(separator: " ")
        var segments: [Segment] = []
        var rest = Substring(flat)
        while !rest.isEmpty {
            guard let open = rest.range(of: ">>>") else {
                segments.append(Segment(text: String(rest), isMatch: false))
                break
            }
            if open.lowerBound > rest.startIndex {
                segments.append(Segment(text: String(rest[..<open.lowerBound]), isMatch: false))
            }
            let after = rest[open.upperBound...]
            let close = after.range(of: "<<<")
            segments.append(Segment(text: String(after[..<(close?.lowerBound ?? after.endIndex)]), isMatch: true))
            rest = close.map { after[$0.upperBound...] } ?? ""
        }
        return segments.filter { !$0.text.isEmpty }
    }

    /// The snippet as plain text, without the markers.
    public var plainSnippet: String { snippetSegments.map(\.text).joined() }

    /// When the conversation was last active, else when it started.
    public var date: Date? {
        (lastActive ?? sessionStarted).map { Date(timeIntervalSince1970: $0) }
    }
}

/// Full-text search over a profile's stored sessions, with the connection's credential.
public protocol SessionSearchSource: Sendable {
    /// `sources`: only rows of these surfaces; `[]` for all of them.
    func searchSessions(_ query: String, profile: String, sources: [String], limit: Int) async throws -> [SessionSearchHit]
}

extension DashboardClient {
    /// `GET /api/sessions/search?q=&profile=&sources=&limit=`: `{results: [...]}`, id
    /// matches first, then message matches, then title matches (`sessions.py:286-463`).
    /// The limit is clamped to 1…100 there.
    public func searchSessions(_ query: String, profile: String, sources: [String], limit: Int,
                               bearer: String? = nil) async throws -> [SessionSearchHit] {
        var items = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "profile", value: profile),
            URLQueryItem(name: "limit", value: String(limit)),
        ]
        if !sources.isEmpty { items.append(URLQueryItem(name: "sources", value: sources.joined(separator: ","))) }
        var request = request(path: "/api/sessions/search", method: "GET", query: items)
        // FTS over a large state.db is the dashboard's slowest read (`sessions.py:461-463`).
        request.timeoutInterval = 30
        if let bearer { request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization") }
        let answer: SearchAnswer = try await send(request)
        return answer.results
    }

    private struct SearchAnswer: Decodable { var results: [SessionSearchHit] }
}

extension DashboardConnector: SessionSearchSource {
    public func searchSessions(_ query: String, profile: String, sources: [String],
                               limit: Int) async throws -> [SessionSearchHit] {
        try await authorized {
            try await dashboard.searchSessions(query, profile: profile, sources: sources, limit: limit, bearer: $0)
        }
    }
}

/// A hit as the session list shows it: the row it opens, and whether that is the Bot Chat.
public struct SessionSearchResult: Sendable, Hashable, Identifiable {
    public var hit: SessionSearchHit
    /// The listed row when the list has the session, else one made from the hit.
    public var entry: HistoryEntry
    /// The hit is the profile's Bot Chat, which opens as the Bot Chat.
    public var isBotChat: Bool

    public var id: String { entry.id }
}

/// The session list's search: the list profile's sessions whose messages, title or id match
/// the query, read from the dashboard (`SessionSearchSource`) by `GatewayConnection`.
@MainActor
@Observable
public final class SessionSearch {
    /// The query `results` answer, trimmed; empty when nothing was searched.
    public internal(set) var query = ""
    public internal(set) var results: [SessionSearchResult] = []
    public internal(set) var isSearching = false
    public internal(set) var error: String?
    /// `false` when the connection has no REST access, so nothing can be searched.
    public internal(set) var isAvailable = true
    @ObservationIgnored var token = 0
    @ObservationIgnored var profile: String?

    public init() {}

    /// The result whose row is `id` (`HistoryEntry.id`), to open a hit the list doesn't hold.
    public func result(id: String) -> SessionSearchResult? {
        results.first { $0.id == id }
    }

    func reset() {
        token += 1
        query = ""
        results = []
        isSearching = false
        error = nil
        profile = nil
    }
}

extension GatewayConnection {
    /// How many hits a search asks for. Desktop asks for the default 20; a list scrolls.
    static let searchLimit = 50

    /// Searches the list profile's sessions for `query`; an empty query clears the results.
    /// Only the sources the list shows are searched (`SessionSourceSettings`), so a hit is
    /// a chat the list could show. A later call supersedes an earlier one still running.
    public func searchSessions(_ query: String) async {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let profile = listProfile else {
            search.reset()
            return
        }
        guard let source = searchSource else {
            search.isAvailable = false
            return
        }
        search.isAvailable = true
        search.token += 1
        let token = search.token
        search.isSearching = true
        defer { if token == search.token { search.isSearching = false } }
        do {
            let hits = try await source.searchSessions(trimmed, profile: profile,
                                                       sources: SessionSourceSettings.listedSources,
                                                       limit: Self.searchLimit)
            guard token == search.token, listProfile == profile else { return }
            search.query = trimmed
            search.profile = profile
            search.error = nil
            search.results = searchResults(hits, profile: profile)
        } catch {
            guard token == search.token, listProfile == profile else { return }
            search.query = trimmed
            search.profile = profile
            search.results = []
            search.error = Self.describe(error)
        }
    }

    /// The hits the list may show, as rows: a listed row where there is one, so a hit
    /// opens, pins and renames as that row does.
    func searchResults(_ hits: [SessionSearchHit], profile: String) -> [SessionSearchResult] {
        let bot = bots.first { $0.name == profile }
        let listed = historyProfile == profile ? history : []
        var seen = Set<String>()
        return hits.compactMap { hit in
            guard SessionSourceSettings.isListed(hit.source) else { return nil }
            let entry = listed.first { $0.summary.id == hit.sessionID || $0.summary.resolvedID == hit.sessionID }
                ?? HistoryEntry(profile: profile, summary: SessionSummary(
                    id: hit.sessionID, title: hit.title, preview: hit.preview,
                    startedAt: hit.sessionStarted, messageCount: hit.messageCount, source: hit.source))
            guard sourceSettings.shows(entry.summary), seen.insert(entry.id).inserted else { return nil }
            let isBotChat = bot.map { Self.isBotChat(entry.summary, of: $0) } ?? false
            return SessionSearchResult(hit: hit, entry: entry, isBotChat: isBotChat)
        }
    }
}
