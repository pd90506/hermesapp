import Foundation
import HermesKit
import HermesProtocol

/// What the bridge sends to the desktop app. Every message is one JSON object with a
/// `type`; field names are the wire contract in docs/desktop-bridge.md.
enum BridgeEvent: Encodable, Sendable {
    case reply(id: String, result: JSONValue)
    case failure(id: String, message: String)
    case connection(ConnectionSnapshot)
    case chat(ChatSnapshot)

    private enum CodingKeys: String, CodingKey { case type, id, result, error }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .reply(let id, let result):
            try container.encode("reply", forKey: .type)
            try container.encode(id, forKey: .id)
            try container.encode(result, forKey: .result)
        case .failure(let id, let message):
            try container.encode("reply", forKey: .type)
            try container.encode(id, forKey: .id)
            try container.encode(message, forKey: .error)
        case .connection(let snapshot):
            try snapshot.encode(to: encoder)
            try container.encode("connection", forKey: .type)
        case .chat(let snapshot):
            try snapshot.encode(to: encoder)
            try container.encode("chat", forKey: .type)
        }
    }

    func json() -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(self) else { return #"{"type":"error"}"# }
        return String(decoding: data, as: UTF8.self)
    }
}

/// The connection, its bots and the session list.
struct ConnectionSnapshot: Encodable, Sendable, Equatable {
    struct BotRow: Encodable, Sendable, Equatable {
        var name: String
        var displayName: String
        var preview: String?
        var isDefault: Bool
    }

    struct SessionRow: Encodable, Sendable, Equatable {
        /// `profile/storedID`, what `openSession` takes.
        var id: String
        var profile: String
        var storedID: String
        var title: String?
        var preview: String?
        /// Unix seconds.
        var startedAt: Double?
        var messageCount: Int?
        var isUnread: Bool
    }

    var state: String
    var detail: String?
    var bots: [BotRow]
    var listProfile: String?
    var sessions: [SessionRow]
    var sessionListLoading: Bool
    var sessionListError: String?

    @MainActor init(_ connection: GatewayConnection) {
        switch connection.shownState {
        case .disconnected: state = "disconnected"; detail = nil
        case .connecting: state = "connecting"; detail = nil
        case .connected: state = "connected"; detail = nil
        case .reconnecting(let attempt): state = "reconnecting"; detail = String(attempt)
        case .failed(let message): state = "failed"; detail = message
        }
        bots = connection.bots.map {
            BotRow(name: $0.name, displayName: $0.displayName, preview: $0.preview, isDefault: $0.isDefault)
        }
        listProfile = connection.listProfile
        sessions = connection.sessionListOrder(connection.visibleHistory).map { entry in
            SessionRow(id: entry.id, profile: entry.profile, storedID: entry.summary.id,
                       title: entry.summary.title, preview: entry.summary.preview,
                       startedAt: entry.summary.startedAt, messageCount: entry.summary.messageCount,
                       isUnread: connection.isUnread(entry))
        }
        sessionListLoading = connection.sessionListLoading
        sessionListError = connection.sessionListError
    }
}

/// The open chat and its transcript.
struct ChatSnapshot: Encodable, Sendable, Equatable {
    struct Item: Encodable, Sendable, Equatable {
        var id: String
        var role: String
        var text: String
        var reasoning: String
        var toolName: String?
        var detail: String?
        var isActive: Bool
        var outgoingStatus: String?
        /// Unix seconds.
        var timestamp: Double?
    }

    var sessionID: String
    var storedSessionID: String?
    var profile: String?
    var title: String?
    var isRunning: Bool
    var lastError: String?
    var items: [Item]

    @MainActor init(_ chat: ChatSession) {
        sessionID = chat.sessionID
        storedSessionID = chat.storedSessionID
        profile = chat.profile
        title = chat.title
        isRunning = chat.transcript.isRunning
        lastError = chat.transcript.lastError
        items = chat.transcript.items.map { item in
            let role: String = switch item.role {
            case .user: "user"
            case .assistant: "assistant"
            case .tool: "tool"
            case .system: "system"
            }
            return Item(id: item.id, role: role, text: item.text, reasoning: item.reasoning,
                        toolName: item.toolName, detail: item.detail, isActive: item.isActive,
                        outgoingStatus: item.outgoingStatus, timestamp: item.timestamp?.timeIntervalSince1970)
        }
    }
}
