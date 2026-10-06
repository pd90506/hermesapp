import Foundation

// `GET /api/sessions/{id}/messages`: bounded pages of a stored transcript
// (`hermes_cli/web_routers/sessions.py:685-729`). The rows are the state.db
// `messages` rows (`hermes_state_common.py:449-480`) as `_row_to_message_dict`
// returns them (`hermes_state_messages.py:1311-1333`), passed through
// `_project_for_display` (`web_routers/sessions.py:617-682`), which keeps one
// output row per input row. They are NOT the `TranscriptMessage` shape that
// `session.resume` sends; `StoredMessageProjection` turns them into display rows.

/// Which end of the transcript a page counts from.
public enum SessionMessagesOrder: String, Sendable, Hashable, Codable {
    /// Pages back from the newest row; rows still come oldest first.
    case latest
    case oldest
}

/// Query of `GET /api/sessions/{id}/messages`.
public struct SessionMessagesQuery: Sendable, Hashable {
    /// Stored session id (any lineage member; the server follows it to the tip,
    /// `web_routers/sessions.py:697`).
    public var sessionID: String
    /// Profile whose state.db holds the session (`nil` = the dashboard's own).
    public var profile: String?
    public var order: SessionMessagesOrder
    /// At most 500; the server clamps (`web_routers/sessions.py:702`).
    public var limit: Int
    /// Rows to skip from the `order` end: the rows already loaded.
    public var offset: Int

    public init(sessionID: String, profile: String?, order: SessionMessagesOrder = .latest,
                limit: Int, offset: Int = 0) {
        self.sessionID = sessionID
        self.profile = profile
        self.order = order
        self.limit = limit
        self.offset = offset
    }
}

/// One stored row. Only what a display transcript needs is typed.
public struct StoredMessage: Sendable, Hashable, Codable {
    /// The row id (`messages.id`), unique per profile store and increasing
    /// with insertion. `SessionMessage.row_id` / `persisted_turn.row_ids` use it.
    public var id: Int?
    public var role: String
    /// A string, or JSON content parts (`_decode_content`).
    public var content: JSONValue?
    public var toolCallID: String?
    /// OpenAI-style `[{id, function:{name, arguments}}]` on assistant rows.
    public var toolCalls: JSONValue?
    public var toolName: String?
    public var timestamp: Double?
    public var reasoning: String?
    public var reasoningContent: String?
    /// `hidden` rows are model-facing scaffolding (`_project_for_display`).
    public var displayKind: String?
    /// Display-only text replacing `content`: compaction summaries and mid-turn
    /// steers (`web_routers/sessions.py:663-680`).
    public var displayContent: JSONValue?

    public init(id: Int?, role: String, content: JSONValue? = nil) {
        self.id = id
        self.role = role
        self.content = content
    }

    enum CodingKeys: String, CodingKey {
        case id, role, content, timestamp, reasoning
        case toolCallID = "tool_call_id"
        case toolCalls = "tool_calls"
        case toolName = "tool_name"
        case reasoningContent = "reasoning_content"
        case displayKind = "display_kind"
        case displayContent = "display_content"
    }
}

/// `pagination` of a messages page (`web_routers/sessions.py:726-729`).
public struct SessionMessagesPagination: Sendable, Hashable, Codable {
    public var limit: Int?
    public var offset: Int?
    public var order: String?
    public var returned: Int?

    public init(limit: Int?, offset: Int?, order: String?, returned: Int?) {
        self.limit = limit
        self.offset = offset
        self.order = order
        self.returned = returned
    }
}

/// Response of `GET /api/sessions/{id}/messages`.
public struct SessionMessagesPage: Sendable, Hashable, Codable {
    /// The lineage tip the server read.
    public var sessionID: String?
    public var profile: String?
    public var messages: [StoredMessage]
    /// Missing on gateways that predate paging: the page is then the whole history.
    public var pagination: SessionMessagesPagination?

    public init(sessionID: String? = nil, profile: String? = nil, messages: [StoredMessage],
                pagination: SessionMessagesPagination?) {
        self.sessionID = sessionID
        self.profile = profile
        self.messages = messages
        self.pagination = pagination
    }

    enum CodingKeys: String, CodingKey {
        case profile, messages, pagination
        case sessionID = "session_id"
    }
}
