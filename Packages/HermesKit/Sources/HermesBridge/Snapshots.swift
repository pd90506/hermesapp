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
    case composer(ComposerSnapshot)

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
        case .composer(let snapshot):
            try snapshot.encode(to: encoder)
            try container.encode("composer", forKey: .type)
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
        /// The profile has an avatar image on the server.
        var hasAvatar: Bool
        /// The colour picked in Hermes Desktop, 0xRRGGBB, when there is one.
        var avatarColor: UInt32?
        /// Set while the profile's avatar image is loaded (`avatar` reads it); it changes
        /// when the image does.
        var avatarID: String?
        /// `idle`, `recent` (its Bot Chat had a message in the last 90 s), `working` or
        /// `waitingForYou` (`GatewayConnection.activity(for:)`).
        var activity: String
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
        var isPinned: Bool
        /// The list's section: `pinned`, `recent` (the unlabelled head, under "Sessions"),
        /// or a date range's id (`SessionDateBucket.id`), titled by `groupTitle`.
        var group: String
        var groupTitle: String?
    }

    var state: String
    var detail: String?
    var bots: [BotRow]
    var listProfile: String?
    var sessions: [SessionRow]
    var sessionListLoading: Bool
    var sessionListError: String?

    /// `pins` and `server`: the pinned sessions (`SessionPins`), listed first under
    /// "Pinned"; the rest in Desktop's date groups (`sessionDateGroups`), as the Mac's list.
    @MainActor init(_ connection: GatewayConnection, pins: SessionPins = SessionPins(), server: UUID = UUID(),
                    now: Date = .now) {
        switch connection.shownState {
        case .disconnected: state = "disconnected"; detail = nil
        case .connecting: state = "connecting"; detail = nil
        case .connected: state = "connected"; detail = nil
        case .reconnecting(let attempt): state = "reconnecting"; detail = String(attempt)
        case .failed(let message): state = "failed"; detail = message
        }
        bots = connection.bots.map { bot in
            let activity = switch connection.activity(for: bot, now: now) {
            case .idle: "idle"
            case .recent: "recent"
            case .working: "working"
            case .waitingForYou: "waitingForYou"
            }
            let avatarID = connection.avatars[bot.name].map { "\($0.count)-\($0.hashValue)" }
            return BotRow(name: bot.name, displayName: bot.displayName, preview: bot.preview, isDefault: bot.isDefault,
                          hasAvatar: bot.hasAvatar, avatarColor: bot.avatarColor, avatarID: avatarID, activity: activity)
        }
        listProfile = connection.listProfile
        func row(_ entry: HistoryEntry, group: String, title: String?, pinned: Bool) -> SessionRow {
            SessionRow(id: entry.id, profile: entry.profile, storedID: entry.summary.id,
                       title: entry.summary.title, preview: entry.summary.preview,
                       startedAt: entry.summary.startedAt, messageCount: entry.summary.messageCount,
                       isUnread: connection.isUnread(entry), isPinned: pinned, group: group, groupTitle: title)
        }
        let split = pins.split(connection.sessionListOrder(connection.visibleHistory), on: server)
        sessions = split.pinned.map { row($0, group: "pinned", title: "Pinned", pinned: true) }
            + connection.sessionDateGroups(split.others, now: now).flatMap { group in
                group.items.map { row($0, group: group.id, title: group.bucket?.title(), pinned: false) }
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
        /// An assistant item's `text` and `reasoning`, parsed (docs/desktop-bridge.md, "Markdown").
        var markdown: [MarkdownPart]?
        var reasoningMarkdown: [MarkdownPart]?
        /// A user item's images (`name`, and `localID`: the composer card it was sent
        /// from) and the names of its files.
        var images: [Image]?
        var attachments: [String]?
        /// A tool item's call, as `ToolCallView` draws it.
        var tool: TranscriptWire.Tool?
        /// `interrupted` for a reply cut short.
        var outcome: String?
        /// A reply with nothing to show yet (`isBlankReply`): the waiting row stands in.
        var isBlank: Bool?
        /// The message has the Copy bar under it (`ConversationMarkdown.hasActionBar`).
        var hasActionBar: Bool?
        /// A background notice Hermes wrote as a user turn (`headline`, `detail`), and
        /// what the self-improvement review saved (`headline` is its label).
        var notice: TranscriptWire.Note?
        var review: TranscriptWire.Note?
        var isCompressionNote: Bool?
    }

    struct Image: Encodable, Sendable, Equatable {
        var name: String
        /// Where the image is on the gateway, for `imageData`.
        var path: String?
        var localID: String?
    }

    var sessionID: String
    var storedSessionID: String?
    var profile: String?
    var title: String?
    var isRunning: Bool
    var lastError: String?
    var items: [Item]
    /// The transcript's blocks, in order (docs/desktop-bridge.md, "Transcript").
    var blocks: [TranscriptWire.Block]
    /// The last prompt or reply: its action bar shows without hover.
    var newestMessageID: String?
    var waiting: TranscriptWire.Waiting?
    /// The running turn's status line, when Hermes gives one.
    var status: String?
    /// Branch in New Chat is offered (not in a Bot Chat).
    var canBranch: Bool

    @MainActor init(_ chat: ChatSession, markdown cache: MarkdownCache = MarkdownCache(), canBranch: Bool = true) {
        sessionID = chat.sessionID
        storedSessionID = chat.storedSessionID
        profile = chat.profile
        title = chat.title
        isRunning = chat.transcript.isRunning
        lastError = chat.transcript.lastError
        let transcript = chat.transcript
        blocks = transcript.blocks.map(TranscriptWire.Block.init)
        newestMessageID = ConversationMarkdown.newestMessageID(in: transcript.items)
        waiting = transcript.waiting.map(TranscriptWire.Waiting.init)
        status = transcript.isRunning ? transcript.status : nil
        self.canBranch = canBranch
        items = chat.transcript.items.map { item in
            let role: String = switch item.role {
            case .user: "user"
            case .assistant: "assistant"
            case .tool: "tool"
            case .system: "system"
            }
            var row = Item(id: item.id, role: role, text: item.text, reasoning: item.reasoning,
                           toolName: item.toolName, detail: item.detail, isActive: item.isActive,
                           outgoingStatus: item.outgoingStatus, timestamp: item.timestamp?.timeIntervalSince1970)
            if item.role == .user {
                if !item.images.isEmpty {
                    row.images = item.images.map { Image(name: $0.name, path: $0.path, localID: $0.localID?.uuidString) }
                }
                if !item.attachments.isEmpty { row.attachments = item.attachments }
            }
            if item.role == .tool { row.tool = TranscriptWire.Tool(ToolCallView(item)) }
            row.outcome = item.outcome
            if item.isBlankReply { row.isBlank = true }
            if ConversationMarkdown.hasActionBar(item) { row.hasActionBar = true }
            if let notice = item.backgroundNotice {
                row.notice = TranscriptWire.Note(headline: notice.headline, detail: notice.detail)
            }
            if let note = item.reviewNote { row.review = TranscriptWire.Note(headline: note.label, detail: note.detail) }
            if item.isCompressionNote { row.isCompressionNote = true }
            if item.role == .assistant {
                if !item.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    row.markdown = cache.parts(item.text, streaming: item.isActive)
                }
                if !item.reasoning.isEmpty {
                    row.reasoningMarkdown = cache.parts(item.reasoning, streaming: item.isActive)
                }
            }
            return row
        }
    }
}
