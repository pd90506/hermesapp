import Foundation
import HermesProtocol

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Hermes's read watermark of stored sessions (`sessions.last_read_at`,
/// `hermes_state_sessions.py:1062-1074`), which every device of a server shares.
public protocol SessionReadSource: Sendable {
    /// When each recently active session of `profile` was last read, in Unix seconds, by
    /// id; 0 for a session never marked. A session not in the answer is not known.
    func readWatermarks(profile: String) async throws -> [String: Double]
    /// Marks the session, across its compression lineage, read up to the server's now.
    func markRead(sessionID: String, profile: String) async throws
}

extension DashboardClient {
    /// Most rows `GET /api/sessions` answers (`le=100`, `sessions.py:181-184`).
    static let readWatermarkLimit = 100

    /// `GET /api/sessions?order=recent`: the one page of the rows with the latest activity.
    /// Only this REST list carries `last_read_at`; `session.list` rows don't
    /// (`_session_row_summary`, `methods_session.py:110-122`). Only the surfaces the session
    /// list shows, so others' rows don't crowd the page.
    public func sessionReadWatermarks(profile: String, bearer: String? = nil) async throws -> [String: Double] {
        var request = request(path: "/api/sessions", method: "GET", query: [
            URLQueryItem(name: "profile", value: profile),
            URLQueryItem(name: "limit", value: String(Self.readWatermarkLimit)),
            URLQueryItem(name: "order", value: "recent"),
            URLQueryItem(name: "sources", value: SessionSourceSettings.listedSources.joined(separator: ",")),
        ])
        if let bearer { request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization") }
        let answer: WatermarkAnswer = try await send(request)
        return Dictionary(answer.sessions.map { ($0.id, $0.lastReadAt ?? 0) }, uniquingKeysWith: { max($0, $1) })
    }

    /// `PATCH /api/sessions/{id} {unread: false}`, fenced by the revision and generation
    /// of `GET /api/sessions/{id}/mutation-snapshot`, as Desktop writes it
    /// (`apps/desktop/src/api/sessions.ts:380-428`, `sessions.py:586-598,926-934`). The
    /// server refuses a write without them (`web_server_sessions.py:269-275`).
    public func markSessionRead(sessionID: String, profile: String, bearer: String? = nil) async throws {
        let scope = [URLQueryItem(name: "profile", value: profile)]
        var read = request(path: "/api/sessions/\(sessionID)/mutation-snapshot", method: "GET", query: scope)
        if let bearer { read.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization") }
        let snapshot: MutationSnapshot = try await send(read)
        guard snapshot.exists else { return }
        var body: [String: JSONValue] = [
            "unread": .bool(false),
            "request_id": .string(UUID().uuidString.lowercased()),
            "expected_revision": .number(Double(snapshot.runtimeRevision)),
            "profile": .string(profile),
        ]
        if let generation = snapshot.runtimeGeneration { body["expected_generation"] = .number(Double(generation)) }
        var write = request(path: "/api/sessions/\(sessionID)", method: "PATCH", json: .object(body))
        if let bearer { write.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization") }
        let _: JSONValue = try await send(write)
    }

    private struct WatermarkAnswer: Decodable {
        var sessions: [Row]

        struct Row: Decodable {
            var id: String
            var lastReadAt: Double?

            enum CodingKeys: String, CodingKey {
                case id
                case lastReadAt = "last_read_at"
            }
        }
    }

    private struct MutationSnapshot: Decodable {
        var exists: Bool
        var runtimeRevision: Int
        var runtimeGeneration: Int?

        enum CodingKeys: String, CodingKey {
            case exists
            case runtimeRevision = "runtime_revision"
            case runtimeGeneration = "runtime_generation"
        }
    }
}

extension DashboardConnector: SessionReadSource {
    public func readWatermarks(profile: String) async throws -> [String: Double] {
        try await authorized { try await dashboard.sessionReadWatermarks(profile: profile, bearer: $0) }
    }

    /// One more try when a turn moved the revision between the snapshot and the write.
    public func markRead(sessionID: String, profile: String) async throws {
        do {
            try await authorized { try await dashboard.markSessionRead(sessionID: sessionID, profile: profile, bearer: $0) }
        } catch DashboardError.http(status: 409, let body?)
            where body.contains("revision_conflict") || body.contains("stale_generation") {
            try await authorized { try await dashboard.markSessionRead(sessionID: sessionID, profile: profile, bearer: $0) }
        }
    }
}
