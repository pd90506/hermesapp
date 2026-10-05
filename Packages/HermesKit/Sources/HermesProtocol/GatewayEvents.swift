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
        case EventType.reasoningDelta, EventType.thinkingDelta:
            return payload(StreamDelta.self).map(GatewayEventKind.reasoningDelta) ?? .unknown
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
    /// Legacy alias of reasoning.delta.
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
}

public enum GatewayEventKind: Sendable, Hashable {
    case gatewayReady(GatewayReady)
    case messageStart
    case messageDelta(StreamDelta)
    case reasoningDelta(StreamDelta)
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

/// `message.delta` / `reasoning.delta` / `reasoning.available` (`StreamDeltaPayload`).
public struct StreamDelta: Sendable, Hashable, Codable {
    public var text: String
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

    public init(text: String? = nil, status: String? = nil, error: String? = nil) {
        self.text = text.map(JSONValue.string)
        self.status = status
        self.error = error
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

/// `tool.start` (`ToolStartPayload`).
public struct ToolStart: Sendable, Hashable, Codable {
    public var toolID: String
    public var name: String
    public var context: String?
    public var preview: String?
    public var args: JSONValue?

    enum CodingKeys: String, CodingKey {
        case name, context, preview, args
        case toolID = "tool_id"
    }
}

/// `tool.complete` (`ToolCompletePayload`).
public struct ToolComplete: Sendable, Hashable, Codable {
    public var toolID: String
    public var name: String
    public var durationS: Double?
    public var summary: String?
    public var resultText: String?
    /// JSON-parsed tool result when possible.
    public var result: JSONValue?

    enum CodingKeys: String, CodingKey {
        case name, summary, result
        case toolID = "tool_id"
        case durationS = "duration_s"
        case resultText = "result_text"
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
