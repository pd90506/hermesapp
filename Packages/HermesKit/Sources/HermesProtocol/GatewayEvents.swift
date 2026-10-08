import Foundation

/// The `params` of a `{"method":"event"}` notification
/// (`_event_frame`, `tui_gateway/server.py:693-696`):
///
///     {"type":"message.delta","session_id":"<runtime sid>","payload":{...},"seq":42}
///
/// `seq` is a per-session counter stamped only on events with a non-empty
/// `session_id` (`tui_gateway/event_replay.py:67-87`). The same object shape
/// is returned in `session.events.since`'s `events` array.
public struct GatewayEvent: Sendable, Hashable, Codable {
    public var type: String
    /// Runtime session id; empty or absent for connection-global events.
    public var sessionID: String?
    public var payload: JSONValue?
    public var seq: Int?

    public init(type: String, sessionID: String? = nil, payload: JSONValue? = nil, seq: Int? = nil) {
        self.type = type
        self.sessionID = sessionID
        self.payload = payload
        self.seq = seq
    }

    enum CodingKeys: String, CodingKey {
        case type, payload, seq
        case sessionID = "session_id"
    }

    /// The method name of event notifications.
    public static let notificationMethod = "event"

    /// Typed view of the event. Unknown types, and known types whose payload
    /// does not decode, map to `.unknown` so newer gateways never break the client.
    public var kind: GatewayEventKind {
        func payload<T: Decodable>(_: T.Type) -> T? { try? (self.payload ?? .object([:])).decode(T.self) }
        switch type {
        case EventType.gatewayReady: return payload(GatewayReady.self).map(GatewayEventKind.gatewayReady) ?? .unknown
        case EventType.messageStart: return .messageStart
        case EventType.messageDelta: return payload(StreamDelta.self).map(GatewayEventKind.messageDelta) ?? .unknown
        case EventType.reasoningDelta: return payload(StreamDelta.self).map(GatewayEventKind.reasoningDelta) ?? .unknown
        case EventType.thinkingDelta: return payload(StreamDelta.self).map(GatewayEventKind.thinkingDelta) ?? .unknown
        case EventType.reasoningAvailable:
            return payload(StreamDelta.self).map(GatewayEventKind.reasoningAvailable) ?? .unknown
        case EventType.messageInterim:
            return payload(MessageInterim.self).map(GatewayEventKind.messageInterim) ?? .unknown
        case EventType.messageComplete:
            return payload(MessageComplete.self).map(GatewayEventKind.messageComplete) ?? .unknown
        case EventType.toolGenerating:
            return payload(ToolGenerating.self).map(GatewayEventKind.toolGenerating) ?? .unknown
        case EventType.toolStart: return payload(ToolStart.self).map(GatewayEventKind.toolStart) ?? .unknown
        case EventType.toolComplete: return payload(ToolComplete.self).map(GatewayEventKind.toolComplete) ?? .unknown
        case EventType.statusUpdate: return payload(StatusUpdate.self).map(GatewayEventKind.statusUpdate) ?? .unknown
        case EventType.sessionTitle: return payload(SessionTitleChange.self).map(GatewayEventKind.sessionTitle) ?? .unknown
        case EventType.sessionInfo: return payload(SessionLiveInfo.self).map(GatewayEventKind.sessionInfo) ?? .unknown
        case EventType.error: return payload(GatewayErrorPayload.self).map(GatewayEventKind.error) ?? .unknown
        case EventType.requestCancel: return payload(RequestCancel.self).map(GatewayEventKind.requestCancel) ?? .unknown
        case EventType.approvalCancelled:
            return payload(ApprovalCancelled.self).map(GatewayEventKind.approvalCancelled) ?? .unknown
        case EventType.btwComplete: return payload(SideAgentComplete.self).map(GatewayEventKind.btwComplete) ?? .unknown
        case EventType.backgroundComplete:
            return payload(SideAgentComplete.self).map(GatewayEventKind.backgroundComplete) ?? .unknown
        case EventType.sessionsChanged: return .sessionsChanged
        case EventType.sessionReclaimed:
            return payload(SessionReclaimed.self).map(GatewayEventKind.sessionReclaimed) ?? .unknown
        case EventType.notificationShow:
            return payload(GatewayNotice.self).map(GatewayEventKind.notificationShow) ?? .unknown
        case EventType.notificationClear:
            return payload(NoticeClear.self).map(GatewayEventKind.notificationClear) ?? .unknown
        default: return .unknown
        }
    }
}

/// Event `type` strings (`tui_gateway/contracts/events.py`).
public enum EventType {
    public static let gatewayReady = "gateway.ready"
    public static let messageStart = "message.start"
    public static let messageDelta = "message.delta"
    public static let reasoningDelta = "reasoning.delta"
    /// Spinner / provider-wait text, *not* model reasoning: Desktop shows it as
    /// a status line only (`gateway-event/message-stream.ts:195-205`,
    /// emitted by `agent_callbacks.py:117-123`).
    public static let thinkingDelta = "thinking.delta"
    public static let reasoningAvailable = "reasoning.available"
    public static let messageInterim = "message.interim"
    /// Terminal frame of every turn (success, error, or interrupt).
    public static let messageComplete = "message.complete"
    public static let toolGenerating = "tool.generating"
    public static let toolStart = "tool.start"
    public static let toolComplete = "tool.complete"
    public static let statusUpdate = "status.update"
    public static let sessionTitle = "session.title"
    public static let sessionInfo = "session.info"
    public static let error = "error"
    public static let requestCancel = "request.cancel"
    public static let approvalCancelled = "approval.cancelled"
    /// Answer to `prompt.btw` (`contracts/events.py:443-452`).
    public static let btwComplete = "btw.complete"
    /// Answer to `prompt.background` (`contracts/events.py:451`).
    public static let backgroundComplete = "background.complete"
    /// Broadcast (empty `session_id`) when any served state.db moved: renames,
    /// archives, deletes, new rows, turns. At most every 2 s
    /// (`change_watcher.py:285-331`, `contracts/events.py:730`).
    public static let sessionsChanged = "sessions.changed"
    /// Broadcast: the backend reclaimed a live session (`contracts/events.py:391-399`).
    public static let sessionReclaimed = "session.reclaimed"
    /// Out-of-band notice (`contracts/events.py:332-349`).
    public static let notificationShow = "notification.show"
    public static let notificationClear = "notification.clear"
}

public enum GatewayEventKind: Sendable, Hashable {
    case gatewayReady(GatewayReady)
    case messageStart
    case messageDelta(StreamDelta)
    case reasoningDelta(StreamDelta)
    case thinkingDelta(StreamDelta)
    case reasoningAvailable(StreamDelta)
    case messageInterim(MessageInterim)
    case messageComplete(MessageComplete)
    case toolGenerating(ToolGenerating)
    case toolStart(ToolStart)
    case toolComplete(ToolComplete)
    case statusUpdate(StatusUpdate)
    case sessionTitle(SessionTitleChange)
    case sessionInfo(SessionLiveInfo)
    case error(GatewayErrorPayload)
    case requestCancel(RequestCancel)
    case approvalCancelled(ApprovalCancelled)
    case btwComplete(SideAgentComplete)
    case backgroundComplete(SideAgentComplete)
    case sessionsChanged
    case sessionReclaimed(SessionReclaimed)
    case notificationShow(GatewayNotice)
    case notificationClear(NoticeClear)
    case unknown
}

// MARK: - Payloads

/// First frame of every connection (`GatewayReadyPayload`, `tui_gateway/ws.py:365-370`).
public struct GatewayReady: Sendable, Hashable, Codable {
    /// Random per backend process. A change across reconnects means the
    /// backend restarted and seq watermarks are void.
    public var replayEpoch: String
    public var changeEvents: Bool?
    /// When true the client should send `gateway.ping` periodically.
    public var heartbeat: Bool?
    public var skin: JSONValue?

    public init(replayEpoch: String, changeEvents: Bool? = true, heartbeat: Bool? = true) {
        self.replayEpoch = replayEpoch
        self.changeEvents = changeEvents
        self.heartbeat = heartbeat
    }

    enum CodingKeys: String, CodingKey {
        case heartbeat, skin
        case replayEpoch = "replay_epoch"
        case changeEvents = "change_events"
    }
}

/// `message.delta` / `reasoning.delta` / `reasoning.available` / `thinking.delta`
/// (`StreamDeltaPayload`, `contracts/events.py:111-124`).
public struct StreamDelta: Sendable, Hashable, Codable {
    public var text: String
    /// Rendered markdown/ANSI, when the gateway has a streamer.
    public var rendered: String?
    public var verbose: Bool?

    public init(text: String, verbose: Bool? = nil) {
        self.text = text
        self.verbose = verbose
    }
}

/// `message.interim`: commentary beside tool calls, sealed as its own segment.
public struct MessageInterim: Sendable, Hashable, Codable {
    public var text: String
    /// The text was already delivered via `message.delta`.
    public var alreadyStreamed: Bool?

    enum CodingKeys: String, CodingKey {
        case text
        case alreadyStreamed = "already_streamed"
    }
}

/// `message.complete` (`MessageCompletePayload`, contracts/events.py:138-208). Subset.
public struct MessageComplete: Sendable, Hashable, Codable {
    /// Typed `str | JsonValue` in the contract (`contracts/events.py:189`):
    /// usually a string, but decoding must not fail on anything else or
    /// the turn's terminal frame would be lost. Use `textValue`.
    public var text: JSONValue?
    /// `complete` | `error` | `interrupted`
    public var status: String?
    public var reasoning: String?
    public var error: String?
    public var warning: String?
    public var recoverable: Bool?
    public var partial: Bool?
    public var usage: JSONValue?
    /// `persisted_turn.user_row_id` (`prompt_turn.py:873-918,939-941`): the stored row of
    /// this turn's prompt, when Hermes committed it.
    public var persistedUserRowID: Int?
    /// `persisted_turn.row_ids`: every row this turn committed, prompt first.
    public var persistedRowIDs: [Int]?

    public init(text: String? = nil, status: String? = nil, error: String? = nil) {
        self.text = text.map(JSONValue.string)
        self.status = status
        self.error = error
    }

    enum CodingKeys: String, CodingKey {
        case text, status, reasoning, error, warning, recoverable, partial, usage
    }

    /// Read only: the receipt is not re-encoded.
    private enum ReceiptKeys: String, CodingKey {
        case persistedTurn = "persisted_turn"
    }

    private enum PersistedTurnKeys: String, CodingKey {
        case userRowID = "user_row_id"
        case rowIDs = "row_ids"
    }

    /// Lenient: this is the terminal frame of every turn, so an optional field of
    /// an unexpected shape must not demote it to `.unknown`.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        text = try? container.decodeIfPresent(JSONValue.self, forKey: .text)
        status = try? container.decodeIfPresent(String.self, forKey: .status)
        reasoning = try? container.decodeIfPresent(String.self, forKey: .reasoning)
        error = try? container.decodeIfPresent(String.self, forKey: .error)
        warning = try? container.decodeIfPresent(String.self, forKey: .warning)
        recoverable = try? container.decodeIfPresent(Bool.self, forKey: .recoverable)
        partial = try? container.decodeIfPresent(Bool.self, forKey: .partial)
        usage = try? container.decodeIfPresent(JSONValue.self, forKey: .usage)
        if let receipt = try? decoder.container(keyedBy: ReceiptKeys.self)
            .nestedContainer(keyedBy: PersistedTurnKeys.self, forKey: .persistedTurn) {
            persistedUserRowID = try? receipt.decodeIfPresent(Int.self, forKey: .userRowID)
            persistedRowIDs = try? receipt.decodeIfPresent([Int].self, forKey: .rowIDs)
        }
    }

    /// `text` as display text: strings as-is, text parts joined, other JSON serialised.
    public var textValue: String {
        switch text {
        case nil, .null?: return ""
        case .string(let value)?: return value
        case .array(let parts)? where parts.allSatisfy({ $0["text"]?.stringValue != nil }):
            return parts.compactMap { $0["text"]?.stringValue }.joined()
        case let value?:
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            return (try? encoder.encode(value)).map { String(decoding: $0, as: UTF8.self) } ?? ""
        }
    }
}

public struct ToolGenerating: Sendable, Hashable, Codable {
    public var name: String
}

/// `tool.start` (`ToolStartPayload`, `contracts/events.py:261-275`).
public struct ToolStart: Sendable, Hashable, Codable {
    public var toolID: String
    public var name: String
    /// Short (80-char) preview of the main argument.
    public var context: String?
    public var preview: String?
    public var args: JSONValue?
    /// Verbose mode only.
    public var argsText: String?

    enum CodingKeys: String, CodingKey {
        case name, context, preview, args
        case toolID = "tool_id"
        case argsText = "args_text"
    }
}

/// `tool.complete` (`ToolCompletePayload`, `contracts/events.py:278-294`).
/// There is no separate tool-output event: the output is `result_text` / `result` here.
public struct ToolComplete: Sendable, Hashable, Codable {
    public var toolID: String
    public var name: String
    public var args: JSONValue?
    public var durationS: Double?
    public var summary: String?
    public var resultText: String?
    /// JSON-parsed tool result, or the raw string (`tool_progress.py:343-346`).
    public var result: JSONValue?
    /// Edit tools: a unified diff.
    public var inlineDiff: String?
    /// Todo tools: the full todo list.
    public var todos: JSONValue?
    /// Not in the contract. Desktop reads it only for an error animation
    /// (`gateway-event/tools.ts:109`); marking the tool failed is the app's choice.
    public var error: String?

    enum CodingKeys: String, CodingKey {
        case name, args, summary, result, todos, error
        case toolID = "tool_id"
        case durationS = "duration_s"
        case resultText = "result_text"
        case inlineDiff = "inline_diff"
    }
}

extension ToolComplete {
    /// `error` is outside the contract: a value of another shape is dropped instead
    /// of demoting the whole `tool.complete` to `.unknown` (which would leave the row running).
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        toolID = try container.decode(String.self, forKey: .toolID)
        name = try container.decode(String.self, forKey: .name)
        args = try container.decodeIfPresent(JSONValue.self, forKey: .args)
        durationS = try container.decodeIfPresent(Double.self, forKey: .durationS)
        summary = try container.decodeIfPresent(String.self, forKey: .summary)
        resultText = try container.decodeIfPresent(String.self, forKey: .resultText)
        result = try container.decodeIfPresent(JSONValue.self, forKey: .result)
        inlineDiff = try container.decodeIfPresent(String.self, forKey: .inlineDiff)
        todos = try container.decodeIfPresent(JSONValue.self, forKey: .todos)
        error = try? container.decodeIfPresent(String.self, forKey: .error)
    }
}

/// `status.update`: transient status line.
public struct StatusUpdate: Sendable, Hashable, Codable {
    /// status | lifecycle | compacting | goal | loop | heartbeat | process | …
    public var kind: String?
    public var text: String
}

/// `session.title`. `session_id` here is the *stored* key.
public struct SessionTitleChange: Sendable, Hashable, Codable {
    public var sessionID: String
    public var title: String

    enum CodingKeys: String, CodingKey {
        case title
        case sessionID = "session_id"
    }
}

/// `error`: a session-level failure outside a turn.
public struct GatewayErrorPayload: Sendable, Hashable, Codable {
    public var message: String
}

/// `request.cancel`: the backend withdrew an open server→client request.
public struct RequestCancel: Sendable, Hashable, Codable {
    public var id: String
    public var method: String?
    /// timeout | interrupted | shutdown | resolved | session_closed
    public var reason: String?
}

/// `approval.cancelled`.
public struct ApprovalCancelled: Sendable, Hashable, Codable {
    public var reason: String?
    public var requestIDs: [String]

    enum CodingKeys: String, CodingKey {
        case reason
        case requestIDs = "request_ids"
    }
}

/// `btw.complete` (`SideAgentCompletePayload`, `contracts/events.py:443-452`).
/// `text` starts with `error: ` when the side question failed (`methods_prompt.py:1282-1315`).
public struct SideAgentComplete: Sendable, Hashable, Codable {
    public var taskID: String
    public var text: String
    public var question: String?

    enum CodingKeys: String, CodingKey {
        case text, question
        case taskID = "task_id"
    }
}

/// `session.reclaimed` (`SessionReclaimedPayload`, `contracts/events.py:391-399`).
public struct SessionReclaimed: Sendable, Hashable, Codable {
    /// The runtime id that is gone.
    public var sessionID: String
    public var storedSessionID: String?
    /// `idle_timeout` | `lru_evict` | `ws_orphan_reap`
    public var reason: String?

    enum CodingKeys: String, CodingKey {
        case reason
        case sessionID = "session_id"
        case storedSessionID = "stored_session_id"
    }
}

/// `notification.show` (`NotificationShowPayload`, `contracts/events.py:332-341`).
public struct GatewayNotice: Sendable, Hashable, Codable {
    public var text: String
    /// `info` | `warn` | `error` | `success`
    public var level: String?
    /// `sticky` | `ttl` | `agent`
    public var kind: String?
    public var ttlMS: Int?
    /// A notice with the same key replaces the previous one; `notification.clear` names it.
    public var key: String?
    public var id: String?

    public init(text: String, level: String? = nil, kind: String? = nil, ttlMS: Int? = nil,
                key: String? = nil, id: String? = nil) {
        self.text = text
        self.level = level
        self.kind = kind
        self.ttlMS = ttlMS
        self.key = key
        self.id = id
    }

    enum CodingKeys: String, CodingKey {
        case text, level, kind, key, id
        case ttlMS = "ttl_ms"
    }
}

/// `notification.clear` (`NotificationClearPayload`, `contracts/events.py:344-345`).
public struct NoticeClear: Sendable, Hashable, Codable {
    public var key: String
}
