import Foundation
import HermesProtocol

/// What a connection last read of its lists: the roster, the avatars, and each profile's
/// sessions with what their rows read. The app keeps it across launches, so a launch
/// shows the lists at once, as they were, while the server is connected and read again
/// (the user, 2026-11-12: the list stayed on "Loading sessions…" for seconds).
///
/// `[client choice]` Hermes has no notion of it. Nothing in it is trusted as current: a
/// chat is only opened once the server is connected.
public struct SessionListCache: Sendable, Hashable, Codable {
    /// One profile's sessions, in server order.
    public struct ProfileList: Sendable, Hashable, Codable {
        public var rows: [SessionSummary]
        /// The `session.list` limit the read settled on (`GatewayConnection.sessionListLimits`).
        public var limit: Int?
        /// What each row read last (`SessionRowActivity`), by stored session id.
        public var activity: [String: RowActivity]
    }

    /// A row's activity and the `SessionRowTimestamp.cacheKey` it was read at.
    public struct RowActivity: Sendable, Hashable, Codable {
        public var key: String
        public var activity: SessionRowActivity
    }

    public var profiles: [ProfileRow] = []
    public var avatars: [String: Data] = [:]
    public var lists: [String: ProfileList] = [:]

    public init() {}

    public var isEmpty: Bool { profiles.isEmpty }
}

extension GatewayConnection {
    /// The lists as they are now, for the app to keep (`listCacheChanged`).
    public var listCache: SessionListCache {
        var cache = SessionListCache()
        cache.profiles = bots.map(\.profile)
        cache.avatars = avatars
        for (profile, entries) in profileLists {
            var activity: [String: SessionListCache.RowActivity] = [:]
            for entry in entries {
                guard var read = rowActivity[entry.id] else { continue }
                // A reply's text is for its notification, not for a file.
                read.activity.replyText = nil
                activity[entry.summary.id] = .init(key: read.key, activity: read.activity)
            }
            cache.lists[profile] = .init(rows: entries.map(\.summary), limit: sessionListLimits[profile],
                                         activity: activity)
        }
        return cache
    }

    /// Shows the lists kept from an earlier launch, before the first connect. Nothing
    /// once this connection has read a roster of its own.
    public func restore(_ cache: SessionListCache) {
        guard bots.isEmpty, client == nil, !cache.isEmpty else { return }
        bots = Bot.roster(cache.profiles)
        avatars = cache.avatars.filter { name, _ in bots.contains { $0.name == name && $0.hasAvatar } }
        for (profile, list) in cache.lists where bots.contains(where: { $0.name == profile }) {
            let entries = list.rows.map { HistoryEntry(profile: profile, summary: $0) }
            profileLists[profile] = entries
            sessionListLimits[profile] = list.limit
            for entry in entries {
                if let read = list.activity[entry.summary.id] { rowActivity[entry.id] = (read.key, read.activity) }
            }
        }
        let preferred = bots.first { $0.name == preferredListProfile }
        selectListProfile((preferred ?? bots.first(where: \.isDefault) ?? bots.first)?.name)
    }
}
