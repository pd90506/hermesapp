import Foundation

/// Client→server method names used by the MVP client.
/// Source: `tui_gateway/contracts/` (see `docs/protocol.md` for citations).
public enum GatewayMethod {
    public static let clientCapabilities = "client.capabilities"
    /// Answered inline by the WS read loop (`tui_gateway/ws.py`); used as heartbeat.
    public static let gatewayPing = "gateway.ping"
    public static let sessionList = "session.list"
    public static let sessionCreate = "session.create"
    public static let sessionResume = "session.resume"
    public static let sessionActivate = "session.activate"
    public static let sessionHistory = "session.history"
    public static let sessionEventsSince = "session.events.since"
    public static let sessionClose = "session.close"
    public static let sessionInterrupt = "session.interrupt"
    public static let sessionTitle = "session.title"
    public static let profilesList = "profiles.list"
    public static let profilesSetAsset = "profiles.set_asset"
    public static let profilesGetAsset = "profiles.get_asset"
    public static let promptSubmit = "prompt.submit"
    public static let approvalRespond = "approval.respond"
    public static let clarifyLock = "clarify.lock"
    public static let requestAnswer = "request.answer"
}

// MARK: - client.capabilities

public struct ClientCapabilitiesParams: Sendable, Hashable, Codable {
    /// Must be `true` or the gateway never sends approval/clarify requests to
    /// this connection (`tui_gateway/server_requests.py:30-34`).
    public var serverRequests: Bool

    public init(serverRequests: Bool = true) { self.serverRequests = serverRequests }

    enum CodingKeys: String, CodingKey { case serverRequests = "server_requests" }
}

public struct ClientCapabilitiesResult: Sendable, Hashable, Codable {
    /// Server→client request methods this backend may send.
    public var serverRequests: [String]
    public var declinesNotShown: Bool?

    enum CodingKeys: String, CodingKey {
        case serverRequests = "server_requests"
        case declinesNotShown = "declines_not_shown"
    }
}

// MARK: - session.*

// `profile` on the session params below is `ProfileParams.profile` /
// `SessionParams.profile` (`contracts/common.py:224-234`): the call runs against
// that profile's state.db and HERMES_HOME (`server.py:558-596`). A name with no
// profile on the host fails with 4064 (`rpc_dispatch.py:35-36`). Omitted = the
// gateway's launch profile.

public struct SessionListParams: Sendable, Hashable, Codable {
    public var limit: Int?
    public var includeHidden: Bool?
    /// Exact-title lookup, window-free; hidden rows resolve and a compression
    /// lineage resolves to its tip as `resolved_id` (`contracts/sessions.py:221-224`,
    /// `methods_session.py:526-559`).
    public var title: String?
    public var profile: String?

    public init(limit: Int? = nil, includeHidden: Bool? = nil, title: String? = nil, profile: String? = nil) {
        self.limit = limit
        self.includeHidden = includeHidden
        self.title = title
        self.profile = profile
    }

    enum CodingKeys: String, CodingKey {
        case limit, title, profile
        case includeHidden = "include_hidden"
    }
}

public struct SessionListResult: Sendable, Hashable, Codable {
    public var sessions: [SessionSummary]
}

public struct SessionCreateParams: Sendable, Hashable, Codable {
    public var title: String?
    public var cwd: String?
    public var model: String?
    public var provider: String?
    /// Free-form origin tag; the gateway stores it on the session row.
    public var source: String?
    public var closeOnDisconnect: Bool?
    public var profile: String?
    /// Born hidden from the default `session.list` (`contracts/sessions.py:134`).
    public var hidden: Bool?
    /// Resume follows the profile's current model/provider instead of the
    /// row's stored pin (`contracts/sessions.py:136`; Desktop sets it on Bot Chats,
    /// `apps/desktop/src/plugins/hermes-bots/canonical-chat.ts:479-485`).
    public var followProfileConfig: Bool?

    public init(title: String? = nil, cwd: String? = nil, model: String? = nil, provider: String? = nil,
                source: String? = nil, closeOnDisconnect: Bool? = nil, profile: String? = nil,
                hidden: Bool? = nil, followProfileConfig: Bool? = nil) {
        self.title = title
        self.cwd = cwd
        self.model = model
        self.provider = provider
        self.source = source
        self.closeOnDisconnect = closeOnDisconnect
        self.profile = profile
        self.hidden = hidden
        self.followProfileConfig = followProfileConfig
    }

    enum CodingKeys: String, CodingKey {
        case title, cwd, model, provider, source, profile, hidden
        case closeOnDisconnect = "close_on_disconnect"
        case followProfileConfig = "follow_profile_config"
    }
}

public struct SessionCreateResult: Sendable, Hashable, Codable {
    /// Runtime id for subsequent calls.
    public var sessionID: String
    /// Durable DB key. The row only exists after the first prompt.
    public var storedSessionID: String
    public var messageCount: Int
    public var messages: [TranscriptMessage]
    public var info: SessionLiveInfo?

    enum CodingKeys: String, CodingKey {
        case messages, info
        case sessionID = "session_id"
        case storedSessionID = "stored_session_id"
        case messageCount = "message_count"
    }

    public var snapshot: LiveSessionSnapshot {
        LiveSessionSnapshot(sessionID: sessionID, messages: messages, info: info,
                            storedSessionID: storedSessionID, running: false)
    }
}

public struct SessionResumeParams: Sendable, Hashable, Codable {
    /// Stored session id (or exact title).
    public var sessionID: String
    public var source: String?
    public var closeOnDisconnect: Bool?
    /// Resume from this profile's state.db (`methods_session.py:634-636`).
    public var profile: String?
    /// Send no transcript: `messages` is empty and `message_count` is the stored
    /// size (`methods_session.py:638-639,689-691,903-909`). The transcript is read
    /// over REST in pages instead.
    public var omitMessages: Bool?
    /// Answer with a bounded ack and load the model history in the background
    /// (`methods_session.py:949-967`, `server.py:2968-3025`); the first turn waits
    /// for it (`server.py:1066-1074`). The resume size guard then checks the tip
    /// segment only (`methods_session.py:854-869`).
    public var deferHistory: Bool?

    public init(sessionID: String, source: String? = nil, closeOnDisconnect: Bool? = nil, profile: String? = nil,
                omitMessages: Bool? = nil, deferHistory: Bool? = nil) {
        self.sessionID = sessionID
        self.source = source
        self.closeOnDisconnect = closeOnDisconnect
        self.profile = profile
        self.omitMessages = omitMessages
        self.deferHistory = deferHistory
    }

    enum CodingKeys: String, CodingKey {
        case source, profile
        case sessionID = "session_id"
        case closeOnDisconnect = "close_on_disconnect"
        case omitMessages = "omit_messages"
        case deferHistory = "defer_history"
    }
}

/// Params for the many methods that take only a session id
/// (`session.history`, `session.close`, `session.interrupt`, `session.activate`).
public struct SessionIDParams: Sendable, Hashable, Codable {
    public var sessionID: String

    public init(sessionID: String) { self.sessionID = sessionID }

    enum CodingKeys: String, CodingKey { case sessionID = "session_id" }
}

/// `session.activate`: re-attaches this connection to a live session (cancels
/// its orphan reap and rebinds event delivery, `methods_session.py:1160-1172`).
public struct SessionActivateParams: Sendable, Hashable, Codable {
    public var sessionID: String
    /// Skip the DB history read when only the reattach is wanted.
    public var omitMessages: Bool?

    public init(sessionID: String, omitMessages: Bool? = nil) {
        self.sessionID = sessionID
        self.omitMessages = omitMessages
    }

    enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case omitMessages = "omit_messages"
    }
}

public struct SessionHistoryResult: Sendable, Hashable, Codable {
    public var count: Int
    public var messages: [TranscriptMessage]
}

public struct SessionEventsSinceParams: Sendable, Hashable, Codable {
    public var sessionID: String
    public var lastSeen: Int?

    public init(sessionID: String, lastSeen: Int?) {
        self.sessionID = sessionID
        self.lastSeen = lastSeen
    }

    enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case lastSeen = "last_seen"
    }
}

public struct SessionEventsSinceResult: Sendable, Hashable, Codable {
    /// Inner `params` objects of the replayed `event` notifications, each with its `seq`.
    public var events: [GatewayEvent]
    public var latestSeq: Int
    /// Events were evicted from the replay ring; refetch state with `session.resume`.
    public var truncated: Bool
    public var count: Int
    /// The backend's replay epoch (compare with `gateway.ready.replay_epoch`).
    public var epoch: String
    public var openRequests: [OpenRequestEntry]

    enum CodingKeys: String, CodingKey {
        case events, truncated, count, epoch
        case latestSeq = "latest_seq"
        case openRequests = "open_requests"
    }
}

/// `session.title` with a title sets it (`contracts/sessions.py:306-317`). Setting
/// it on a session whose row does not exist yet persists the row now
/// (`methods_session.py:1229-1241`). A title another row already holds fails
/// with 4022 "Title '…' is already in use by session …"
/// (`hermes_state_titles.py:154`, `methods_session.py:1242-1243`).
public struct SessionTitleParams: Sendable, Hashable, Codable {
    public var sessionID: String
    public var title: String

    public init(sessionID: String, title: String) {
        self.sessionID = sessionID
        self.title = title
    }

    enum CodingKeys: String, CodingKey {
        case title
        case sessionID = "session_id"
    }
}

public struct SessionTitleResult: Sendable, Hashable, Codable {
    public var title: String
    public var sessionKey: String?
    /// `true`: no row yet; the title is applied on the first turn.
    public var pending: Bool?

    enum CodingKeys: String, CodingKey {
        case title, pending
        case sessionKey = "session_key"
    }
}

public struct SessionCloseResult: Sendable, Hashable, Codable {
    public var closed: Bool
}

public struct SessionInterruptResult: Sendable, Hashable, Codable {
    /// `interrupted` | `not_interrupted`
    public var status: String
    public var interrupted: Bool?
}

// MARK: - prompt.submit

public struct PromptSubmitParams: Sendable, Hashable, Codable {
    public var sessionID: String
    public var text: String
    /// Queue behind a running turn instead of applying `display.busy_input_mode`
    /// (`contracts/prompt_voice.py:35`, `methods_prompt.py:768-770`).
    public var queued: Bool?

    public init(sessionID: String, text: String, queued: Bool? = nil) {
        self.sessionID = sessionID
        self.text = text
        self.queued = queued
    }

    enum CodingKeys: String, CodingKey {
        case text, queued
        case sessionID = "session_id"
    }
}

public struct PromptSubmitResult: Sendable, Hashable, Codable {
    /// `streaming` (turn started) | `queued` | `steered` | `redirected` (session was busy).
    public var status: String?
    public var userRowID: Int?

    enum CodingKeys: String, CodingKey {
        case status
        case userRowID = "user_row_id"
    }
}

// MARK: - Server-request answer side channels

/// `approval.respond` — alternative to answering the `approval` server
/// request frame directly. The frame response is the primary path.
public struct ApprovalRespondParams: Sendable, Hashable, Codable {
    public var sessionID: String
    public var choice: ApprovalChoice
    public var all: Bool?
    public var requestID: String?

    public init(sessionID: String, choice: ApprovalChoice, all: Bool? = nil, requestID: String? = nil) {
        self.sessionID = sessionID
        self.choice = choice
        self.all = all
        self.requestID = requestID
    }

    enum CodingKeys: String, CodingKey {
        case choice, all
        case sessionID = "session_id"
        case requestID = "request_id"
    }
}

public struct ApprovalRespondResult: Sendable, Hashable, Codable {
    public var resolved: Int
}

/// `clarify.lock` — lock one answer of a batch clarify request.
public struct ClarifyLockParams: Sendable, Hashable, Codable {
    public var requestID: String
    public var questionID: String
    /// `nil` = skipped; sent as JSON `null` (`contracts/prompt_voice.py:254`).
    public var answer: String?

    public init(requestID: String, questionID: String, answer: String?) {
        self.requestID = requestID
        self.questionID = questionID
        self.answer = answer
    }

    enum CodingKeys: String, CodingKey {
        case answer
        case requestID = "request_id"
        case questionID = "question_id"
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(requestID, forKey: .requestID)
        try container.encode(questionID, forKey: .questionID)
        try container.encode(answer, forKey: .answer)  // explicit null, not omitted
    }
}

/// Result of `clarify.lock` and `request.answer`.
public struct RequestLockResult: Sendable, Hashable, Codable {
    /// `ok` | `expired`
    public var status: String
    public var remaining: [String]?
}

/// `request.answer` — answer an open server request this connection never
/// received as a frame (e.g. listed in `open_requests`).
public struct RequestAnswerParams: Sendable, Hashable, Codable {
    public var id: String
    public var result: JSONValue

    public init(id: String, result: JSONValue) {
        self.id = id
        self.result = result
    }
}
