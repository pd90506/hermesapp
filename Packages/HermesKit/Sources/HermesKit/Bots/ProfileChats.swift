import Foundation

/// The chat each profile showed last, per server, so picking the profile again shows
/// that chat: its Bot Chat, or one of its sessions.
///
/// `[client choice]` Kept by the app, like `SessionPins`; Hermes has no notion of it.
public struct ProfileChats: Sendable, Hashable, Codable {
    /// What a profile showed last.
    public enum Chat: Sendable, Hashable, Codable {
        case botChat
        /// A session, by its stored id (`HistoryEntry.summary.id`).
        case session(String)
    }

    /// What picking a profile should show.
    public enum Restore: Sendable, Hashable {
        case botChat
        case session(HistoryEntry)
        /// The profile showed a session last: wait until its list is read, to know
        /// whether the session is still there.
        case waitForList
    }

    private var chats: [String: Chat]

    public init() {
        chats = [:]
    }

    /// Profile names are only unique per server.
    private static func key(_ profile: String, on server: UUID) -> String {
        "\(server.uuidString)/\(profile)"
    }

    public func chat(of profile: String, on server: UUID) -> Chat? {
        chats[Self.key(profile, on: server)]
    }

    public mutating func record(_ chat: Chat, of profile: String, on server: UUID) {
        chats[Self.key(profile, on: server)] = chat
    }

    /// A server's records go with it.
    public mutating func forgetServer(_ server: UUID) {
        chats = chats.filter { !$0.key.hasPrefix(server.uuidString + "/") }
    }

    /// The chat to show for a profile. `history` is the profile's session list, or `nil`
    /// while it isn't read yet; `isCurrent` is false for a list read before the profile
    /// was picked, which can show that the session is there but not that it is gone.
    /// With no record, or when the session it names is gone, the Bot Chat.
    public func restore(_ profile: String, on server: UUID, history: [HistoryEntry]?,
                        isCurrent: Bool = true) -> Restore {
        guard case .session(let id) = chat(of: profile, on: server) else { return .botChat }
        let entry = history?.first {
            $0.profile == profile && ($0.summary.id == id || $0.summary.resolvedID == id)
        }
        if let entry { return .session(entry) }
        return history != nil && isCurrent ? .botChat : .waitForList
    }
}
