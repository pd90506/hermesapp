import Foundation
import HermesProtocol

/// What the session list knows of a row beyond `session.list`: when the user last wrote in
/// it, and whether its newest stored message is a reply.
///
/// `[client choice]` The list is ordered by the user's last prompt, not by the session's
/// last activity (asked for by the user, 2026-10-29): with `session.list`'s order
/// (`last_active`, `tui_gateway/methods_session.py:148`), two chats answering at once
/// swapped places with every reply. `session.list` rows carry neither time
/// (`_session_row_summary`, `:110-122`), so both come from the dashboard's REST reads.
public struct SessionRowActivity: Sendable, Hashable {
    /// The newest prompt the user typed (`GET /api/sessions/{id}/timeline`), nil when the
    /// session has none or the server has no timeline.
    public var lastPrompt: Date?
    /// The newest stored message (`GET /api/sessions/{id}/messages?order=latest&limit=1`).
    public var newestMessage: Date?
    /// When the newest stored message is the agent's answer: an assistant row with no
    /// tool calls. Nil while a turn is still working (a tool row, or a call) or the user
    /// wrote last.
    public var newestReply: Date?
    /// The text of that reply, for a notification (`GatewayConnection.noteReply`).
    public var replyText: String?

    public init(lastPrompt: Date? = nil, newestMessage: Date? = nil, newestReply: Date? = nil,
                replyText: String? = nil) {
        self.lastPrompt = lastPrompt
        self.newestMessage = newestMessage
        self.newestReply = newestReply
        self.replyText = replyText
    }

    /// What the row is ordered, grouped and dated by: its last prompt, else (no prompt,
    /// or a server without the timeline) its newest message.
    public var listDate: Date? { lastPrompt ?? newestMessage }

    /// Most timeline pages read for one row (500 prompts each).
    static let maxTimelinePages = 20

    /// Reads both times. The newest message is required (its failure fails the read);
    /// a timeline the server doesn't have, or can't read, leaves `lastPrompt` nil.
    public static func read(for entry: HistoryEntry, from source: any SessionMessagesSource) async throws -> SessionRowActivity {
        async let prompt = lastPrompt(for: entry, from: source)
        let newest = try await SessionRowTimestamp.newest(for: entry, from: source)
        var activity = SessionRowActivity(lastPrompt: try? await prompt)
        activity.newestMessage = SessionRowTimestamp.date(of: newest?.timestamp)
        if let newest, isReply(newest) {
            activity.newestReply = activity.newestMessage
            activity.replyText = (newest.displayContent ?? newest.content)?.stringValue
        }
        return activity
    }

    /// The timestamp of the session's last prompt, following the timeline's pages.
    static func lastPrompt(for entry: HistoryEntry, from source: any SessionMessagesSource) async throws -> Date? {
        var cursor = 0
        var last: Date?
        for _ in 0..<maxTimelinePages {
            let page = try await source.timelinePage(SessionTimelineQuery(
                sessionID: entry.summary.resolvedID ?? entry.summary.id, profile: entry.profile, afterRowID: cursor))
            if let date = page.entries.last.flatMap({ SessionRowTimestamp.date(of: $0.timestamp) }) { last = date }
            guard page.pagination?.hasMore == true, let next = page.pagination?.nextCursor, next > cursor else { break }
            cursor = next
        }
        return last
    }

    /// An answer, not a step of a turn still working, nor scaffolding.
    static func isReply(_ message: StoredMessage) -> Bool {
        guard message.role == "assistant", message.displayKind != "hidden" else { return false }
        switch message.toolCalls {
        case nil, .null: return true
        case .array(let calls): return calls.isEmpty
        default: return false
        }
    }
}

/// The session list's order: by each row's `listDate`, newest first.
public enum SessionListOrder {
    /// `items` in server order, with each one's date (nil when not read yet). A row not
    /// read yet keeps its place under the row above it in server order, so rows only move
    /// once their date is known; one leading the list stays at the top.
    public static func sorted<Item>(_ items: [Item], dates: [Date?]) -> [Item] {
        var above = Date.distantFuture
        let keyed = items.enumerated().map { index, item -> (Int, Date, Item) in
            let own = dates.indices.contains(index) ? dates[index] : nil
            let key = own ?? above
            above = key
            return (index, key, item)
        }
        return keyed.sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0 < $1.0 }.map(\.2)
    }
}

/// Which replies the user has seen, per session, on this device: a row whose newest reply
/// is newer than what was seen of it shows as unread, like a chat in Claude's apps, until
/// it is opened.
///
/// `[client choice]` Kept by the app, like `SessionPins`. Hermes has a read watermark of its
/// own (`sessions.last_read_at`, `hermes_state_sessions.py:1062-1074`), but only the REST
/// list carries it and only the fenced `PATCH /api/sessions/{id} {unread}` writes it; and
/// since any activity, the user's own prompt included, passes the watermark, every turn
/// would need a write. Not synced with Desktop or between devices.
public struct SessionReadMarks: Sendable, Hashable, Codable {
    /// Seen through, in Unix seconds, by `key`.
    private var seen: [String: Double] = [:]
    /// When marks started being kept: replies older than this count as seen, so the first
    /// launch shows no old chat as unread.
    private var since: Double?

    /// Most sessions remembered; the oldest marks go first.
    static let limit = 2000

    public init() {}

    static func key(profile: String, id: String) -> String { "\(profile)/\(id)" }

    /// Starts keeping marks, once.
    public mutating func start(now: Date = .now) {
        if since == nil { since = now.timeIntervalSince1970 }
    }

    public func isUnread(profile: String, id: String, newestReply: Date?) -> Bool {
        guard let reply = newestReply?.timeIntervalSince1970,
              let seenThrough = seen[Self.key(profile: profile, id: id)] ?? since else { return false }
        return reply > seenThrough
    }

    /// Everything up to `date` was seen. Returns whether that changed anything.
    @discardableResult
    public mutating func markSeen(profile: String, id: String, through date: Date) -> Bool {
        let key = Self.key(profile: profile, id: id)
        let value = date.timeIntervalSince1970
        guard value > (seen[key] ?? -.infinity) else { return false }
        seen[key] = value
        if seen.count > Self.limit {
            for (old, _) in seen.sorted(by: { $0.value < $1.value }).prefix(seen.count - Self.limit) {
                seen[old] = nil
            }
        }
        return true
    }
}
