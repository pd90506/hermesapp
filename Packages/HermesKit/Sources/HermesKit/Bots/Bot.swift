import Foundation
import HermesProtocol

/// One bot in the sidebar: a Hermes profile and its one permanent chat.
///
/// Mirrors Hermes Desktop's Bot Mode (`apps/desktop/src/AGENTS.md`, "Bot Mode"):
/// the chat's only identity is (profile, session titled exactly
/// `Bot.chatTitle`). No session id is ever stored as the bot's chat; the
/// canonical ids below are the server's current answer, used for display and
/// to recognise that chat in listings, never as the target of an open.
public struct Bot: Sendable, Hashable, Identifiable {
    /// The canonical chat's title (`canonical-chat.ts:50`, `tools/bot_mode_probe.py` `BOT_CHAT_TITLE`).
    public static let chatTitle = "Bot Chat"

    public var profile: ProfileRow

    public init(profile: ProfileRow) { self.profile = profile }

    public var id: String { profile.name }
    /// The profile name, sent as `profile` on scoped calls.
    public var name: String { profile.name }
    public var isDefault: Bool { profile.isDefault == true || profile.name == "default" }

    /// What the row shows, in Desktop's order (`plugins/hermes-bots/labels.ts:45-75`):
    /// the Bot Mode title in `ui_meta`, the profile's display name, "Hermes" for
    /// `default`, then the name with `-`/`_` as spaces, capitalised.
    public var displayName: String {
        if let title = profile.uiMeta?["hermes-bots"]?["title"]?.stringValue?.trimmed, !title.isEmpty {
            return title
        }
        if let display = profile.displayName?.trimmed, !display.isEmpty { return display }
        if profile.name.lowercased() == "default" { return "Hermes" }
        let words = profile.name.replacingOccurrences(of: "[-_]+", with: " ", options: .regularExpression).trimmed
        return words.split(separator: " ").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
    }

    /// The Bot Chat's newest message, or `nil` before the bot has a chat.
    public var preview: String? {
        guard let text = profile.canonicalSession?.preview?.trimmed, !text.isEmpty else { return nil }
        return text
    }

    /// Last activity of the Bot Chat.
    public var lastActive: Date? {
        guard let seconds = profile.canonicalSession?.lastActive, seconds > 0 else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    public var hasChat: Bool { profile.canonicalSession != nil }

    /// Is this listing row the Bot Chat registry row? `root_title` (the lineage
    /// root's title) wins when a gateway reports it; plain `title` otherwise
    /// (`canonical-chat.ts:196-204`).
    public static func isChatRow(_ row: SessionSummary) -> Bool {
        let rootTitle = (row.rootTitle ?? "").trimmed
        return rootTitle == chatTitle || (rootTitle.isEmpty && (row.title ?? "").trimmed == chatTitle)
    }

    /// Stored ids the Bot Chat answers to right now: registry row and lineage tip.
    public var chatStoredIDs: Set<String> {
        guard let canonical = profile.canonicalSession else { return [] }
        return Set([canonical.id, canonical.resolvedID].compactMap { $0 }.filter { !$0.isEmpty })
    }

    // MARK: Activity

    /// Desktop's "active now" window for the Bot Chat (`row-helpers.ts:55-57`).
    public static let activeWindow: TimeInterval = 90
    /// Workers heartbeat at least every 60 s; one missed beat is bridged (`row-helpers.ts:72-86`).
    public static let workerWindow: TimeInterval = 150

    /// Roster-only activity. `GatewayConnection.activity(for:)` adds what this
    /// app sees live (a running turn, a request waiting for an answer).
    public func activity(now: Date = Date(), liveTurnRunning: Bool = false,
                         waitingForAnswer: Bool = false) -> BotActivity {
        if waitingForAnswer { return .waitingForYou }
        if liveTurnRunning { return .working }
        if let beat = profile.workerSession?.lastActive, beat > 0,
            now.timeIntervalSince1970 - beat < Self.workerWindow
        {
            return .working
        }
        if let last = lastActive, now.timeIntervalSince(last) < Self.activeWindow { return .recent }
        return .idle
    }

    /// `default` first, then the server's order (`profiles.list` order).
    public static func roster(_ profiles: [ProfileRow]) -> [Bot] {
        let bots = profiles.map(Bot.init(profile:))
        return bots.filter(\.isDefault) + bots.filter { !$0.isDefault }
    }
}

public enum BotActivity: Sendable, Hashable {
    case idle
    /// The Bot Chat had a message in the last 90 s.
    case recent
    /// A turn is running in this app, or a background worker of the profile is alive.
    case working
    /// A session of this bot is blocked on an approval/clarify/… answer.
    case waitingForYou
}

/// A session of some profile shown in the History area (side chats and every
/// other non-Bot-Chat session of the profile).
public struct HistoryEntry: Sendable, Hashable, Identifiable {
    public var profile: String
    public var summary: SessionSummary

    public init(profile: String, summary: SessionSummary) {
        self.profile = profile
        self.summary = summary
    }

    /// Stored ids are only unique per profile database.
    public var id: String { "\(profile)/\(summary.id)" }
}

/// What a `ChatSession` is to the bot sidebar.
public enum ChatKind: Sendable, Hashable {
    /// The profile's one permanent Bot Chat.
    case botChat
    /// Any other session of a profile (a side chat, or one opened from History).
    case sideChat
    /// An unscoped session on the gateway's launch profile.
    case session
}

/// Bot Chat open failures. Both mean "try again": never create a new Bot Chat
/// when the registry could not be read (`canonical-chat.ts:282-292,328-338`).
public enum BotChatError: Error, Sendable, Equatable {
    /// The exact-title lookup failed.
    case registryUnavailable(profile: String, detail: String)
    /// The lookup found nothing but the roster says the bot has a Bot Chat.
    case registryUnconfirmed(profile: String)
    /// A new Bot Chat was created but could not be saved under its name, so it
    /// is not used (the next open would not find it).
    case notRegistered(profile: String, detail: String)
}

/// Restore outcomes that mean "nothing to restore" rather than "try again".
enum RestoreError: Error {
    /// The bot's profile has no Bot Chat any more.
    case botChatGone
}

extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}

/// The newest persisted message date, not session creation or runtime activity.
/// `session.list` omits this metadata (`tui_gateway/methods_session.py:110-122`).
/// Read only one newest row through the existing REST paging interface.
public enum SessionRowTimestamp {
    public static func latest(for entry: HistoryEntry, from source: any SessionMessagesSource) async throws -> Date? {
        let page = try await source.messagesPage(SessionMessagesQuery(
            sessionID: entry.summary.resolvedID ?? entry.summary.id,
            profile: entry.profile, order: .latest, limit: 1))
        // Older servers can ignore paging/order. Never walk the transcript or label
        // an oldest page as newest. No creation-time fallback for missing metadata.
        guard page.pagination?.order == "latest", page.messages.count <= 1,
              let seconds = page.messages.last?.timestamp, seconds.isFinite, seconds > 0 else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    /// What a read for `entry` depends on: its profile, its compression tip and the
    /// tip's stored message count, which every stored message bumps
    /// (`_bump_session_counters`, `hermes_state_messages.py:376-387`). Nil without a
    /// count: such a row is read each time.
    public static func cacheKey(for entry: HistoryEntry) -> String? {
        guard let count = entry.summary.messageCount else { return nil }
        return "\(entry.profile)/\(entry.summary.resolvedID ?? entry.summary.id)/\(count)"
    }
}
