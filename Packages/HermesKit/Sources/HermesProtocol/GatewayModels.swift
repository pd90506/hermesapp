import Foundation

// Shared shapes used by several gateway methods and events.
//
// Field names follow `tui_gateway/contracts/` (mirrored in Hermes at
// `apps/shared/src/gateway-contract.openrpc.json`). Only the fields an MVP
// chat client needs are typed; everything is optional unless the contract
// marks it required, so newer gateways with extra or missing fields still
// decode. Explicit `CodingKeys` are used instead of a snake-case key
// strategy because that strategy would also rewrite free-form dictionary
// keys (tool args, clarify answers).

/// One row of `session.list` (`SessionListRow`, contracts/sessions.py).
public struct SessionSummary: Sendable, Hashable, Codable, Identifiable {
    /// The stored session id — pass it to `session.resume`.
    public var id: String
    public var resolvedID: String?
    public var title: String?
    public var preview: String?
    /// Unix seconds.
    public var startedAt: Double?
    public var messageCount: Int?
    public var liveMessageCount: Int?
    public var source: String?

    public init(id: String, title: String? = nil, preview: String? = nil, startedAt: Double? = nil,
                messageCount: Int? = nil, source: String? = nil) {
        self.id = id
        self.title = title
        self.preview = preview
        self.startedAt = startedAt
        self.messageCount = messageCount
        self.source = source
    }

    enum CodingKeys: String, CodingKey {
        case id, title, preview, source
        case resolvedID = "resolved_id"
        case startedAt = "started_at"
        case messageCount = "message_count"
        case liveMessageCount = "live_message_count"
    }
}

/// A row of the durable display transcript (`TranscriptMessage`, contracts/common.py).
public struct TranscriptMessage: Sendable, Hashable, Codable {
    /// `user`, `assistant`, `tool`, `system`, … (open set).
    public var role: String
    public var text: String?
    /// Structured content (multimodal parts) when `text` is absent.
    public var content: JSONValue?
    public var toolCallID: String?
    public var timestamp: Double?
    public var rowID: Int?
    public var displayKind: String?
    /// Tool name for `role == "tool"` rows.
    public var name: String?
    /// Short tool context (e.g. the command or path).
    public var context: String?
    public var args: JSONValue?
    public var reasoning: String?

    public init(role: String, text: String? = nil) {
        self.role = role
        self.text = text
    }

    enum CodingKeys: String, CodingKey {
        case role, text, content, timestamp, name, context, args, reasoning
        case toolCallID = "tool_call_id"
        case rowID = "row_id"
        case displayKind = "display_kind"
    }

    /// Best-effort plain text: `text`, else the concatenated text parts of `content`.
    public var plainText: String {
        if let text { return text }
        switch content {
        case .string(let s): return s
        case .array(let parts):
            return parts.compactMap { $0["text"]?.stringValue }.joined(separator: "\n")
        default: return ""
        }
    }
}

/// Live session metadata (`SessionLiveInfo`, contracts/common.py). Subset.
public struct SessionLiveInfo: Sendable, Hashable, Codable {
    public var model: String?
    public var provider: String?
    public var reasoningEffort: String?
    public var cwd: String?
    public var branch: String?
    public var running: Bool?
    public var title: String?
    public var storedSessionID: String?
    public var version: String?
    public var approvalMode: String?
    public var profileName: String?
    public var usage: JSONValue?

    public init() {}

    enum CodingKeys: String, CodingKey {
        case model, provider, cwd, branch, running, title, version, usage
        case reasoningEffort = "reasoning_effort"
        case storedSessionID = "stored_session_id"
        case approvalMode = "approval_mode"
        case profileName = "profile_name"
    }
}

/// The turn that was running when a client (re)attached (`InflightTurn`, contracts/sessions.py).
public struct InflightTurn: Sendable, Hashable, Codable {
    /// Assistant text streamed so far.
    public var assistant: String?
    public var streaming: Bool?
    /// The user prompt that started the turn.
    public var user: String?
    /// Set on a *retained failed* turn (`session_auto_continue.py:546-549`):
    /// the turn is over and must render as failed, not as still running.
    public var error: String?
    public var status: String?
    public var recoverable: Bool?

    public init(assistant: String? = nil, streaming: Bool? = nil, user: String? = nil,
                error: String? = nil, status: String? = nil) {
        self.assistant = assistant
        self.streaming = streaming
        self.user = user
        self.error = error
        self.status = status
    }

    /// True for a retained failed turn rather than a live one.
    public var isFailed: Bool { !(error ?? "").isEmpty }
}

/// An unanswered server→client request returned on (re)attach (`OpenRequestEntry`).
public struct OpenRequestEntry: Sendable, Hashable, Codable {
    public var id: String
    public var method: String
    public var params: JSONValue

    public init(id: String, method: String, params: JSONValue) {
        self.id = id
        self.method = method
        self.params = params
    }
}

/// Result of `session.resume` / `session.activate` (`LiveSessionSnapshot`, contracts/sessions.py).
public struct LiveSessionSnapshot: Sendable, Hashable, Codable {
    /// Runtime id for all subsequent calls on this connection.
    public var sessionID: String
    public var messageCount: Int
    public var messages: [TranscriptMessage]
    public var info: SessionLiveInfo?
    /// Durable DB key as `stored_session_id`. Only `session.create` fills
    /// this; resume/activate payloads carry `session_key` instead
    /// (`methods_session.py:908-911`, `server.py:3172-3186`). Prefer `storedKey`.
    public var storedSessionID: String?
    /// The stored key on resume/activate payloads (`_session_lookup_key`).
    public var sessionKey: String?
    /// What `session.resume` was asked for (stored id or title).
    public var resumed: String?
    public var running: Bool?
    /// idle | starting | waiting | working | streaming | resuming
    public var status: String?
    public var inflight: InflightTurn?
    public var openRequests: [OpenRequestEntry]?

    public init(sessionID: String, messages: [TranscriptMessage] = [], info: SessionLiveInfo? = nil,
                storedSessionID: String? = nil, sessionKey: String? = nil, running: Bool? = nil,
                inflight: InflightTurn? = nil, openRequests: [OpenRequestEntry]? = nil) {
        self.sessionID = sessionID
        self.messageCount = messages.count
        self.messages = messages
        self.info = info
        self.storedSessionID = storedSessionID
        self.sessionKey = sessionKey
        self.running = running
        self.inflight = inflight
        self.openRequests = openRequests
    }

    enum CodingKeys: String, CodingKey {
        case messages, info, running, status, inflight, resumed
        case sessionID = "session_id"
        case messageCount = "message_count"
        case storedSessionID = "stored_session_id"
        case sessionKey = "session_key"
        case openRequests = "open_requests"
    }

    /// The durable key from whichever field this payload carries.
    public var storedKey: String? {
        for candidate in [sessionKey, storedSessionID, info?.storedSessionID] {
            if let candidate, !candidate.isEmpty { return candidate }
        }
        return nil
    }
}
