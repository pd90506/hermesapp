import Foundation

/// Sessions the user pinned to the top of their profile's list, per server.
///
/// `[client choice]` Kept by the app. Hermes's own pin is the `sessions.pinned` column,
/// written only through the dashboard's fenced REST `PATCH /api/sessions/{id} {pinned}`
/// (`apps/desktop/src/api/sessions.ts:427-428`); `session.list` rows don't carry it
/// (`_session_row_summary`, `methods_session.py:110-122`), so this app could not read
/// pins back over JSON-RPC (`docs/protocol.md` §10.9).
public struct SessionPins: Sendable, Hashable, Codable {
    private var keys: Set<String>

    public init() {
        keys = []
    }

    /// Stored ids are only unique per profile db, and profile names per server.
    private static func key(_ entry: HistoryEntry, on server: UUID) -> String {
        "\(server.uuidString)/\(entry.profile)/\(entry.summary.id)"
    }

    public func isPinned(_ entry: HistoryEntry, on server: UUID) -> Bool {
        keys.contains(Self.key(entry, on: server))
    }

    public mutating func setPinned(_ pinned: Bool, _ entry: HistoryEntry, on server: UUID) {
        if pinned {
            keys.insert(Self.key(entry, on: server))
        } else {
            keys.remove(Self.key(entry, on: server))
        }
    }

    /// A server's pins go with it.
    public mutating func forgetServer(_ server: UUID) {
        keys = keys.filter { !$0.hasPrefix(server.uuidString + "/") }
    }

    /// The pinned rows, then the rest, each in list order.
    public func split(_ entries: [HistoryEntry], on server: UUID) -> (pinned: [HistoryEntry], others: [HistoryEntry]) {
        var pinned: [HistoryEntry] = []
        var others: [HistoryEntry] = []
        for entry in entries {
            if isPinned(entry, on: server) { pinned.append(entry) } else { others.append(entry) }
        }
        return (pinned, others)
    }
}
