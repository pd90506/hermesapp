import Foundation
import HermesProtocol
import Testing
@testable import HermesKit

private actor TimestampSource: SessionMessagesSource {
    var rows: [StoredMessage] = []
    var order: String? = "latest"
    var queries: [SessionMessagesQuery] = []

    func set(_ timestamps: [Double?], order: String? = "latest") {
        rows = timestamps.enumerated().map { index, timestamp in
            var row = StoredMessage(id: index + 1, role: index == 0 ? "user" : "assistant")
            row.timestamp = timestamp
            return row
        }
        self.order = order
    }

    func messagesPage(_ query: SessionMessagesQuery) async throws -> SessionMessagesPage {
        queries.append(query)
        return SessionMessagesPage(messages: Array(rows.suffix(query.limit)), pagination:
            order.map { SessionMessagesPagination(limit: query.limit, offset: 0, order: $0, returned: min(rows.count, query.limit)) })
    }
}

private actor FailingOnceSource: SessionMessagesSource {
    var calls = 0

    func messagesPage(_ query: SessionMessagesQuery) async throws -> SessionMessagesPage {
        calls += 1
        if calls == 1 { throw CancellationError() }
        var row = StoredMessage(id: 1, role: "user")
        row.timestamp = 500
        return SessionMessagesPage(messages: [row], pagination:
            SessionMessagesPagination(limit: query.limit, offset: 0, order: "latest", returned: 1))
    }
}

struct SessionRowTimestampTests {
    // Real list shape: tui_gateway/methods_session.py:110-122 includes started_at,
    // but no last_active. REST paging/timestamps: web_routers/sessions.py:726-768.
    private func entry() throws -> HistoryEntry {
        let data = Data(#"{"id":"root","resolved_id":"tip","started_at":100,"message_count":2,"source":"cli"}"#.utf8)
        return HistoryEntry(profile: "coder", summary: try JSONDecoder().decode(SessionSummary.self, from: data))
    }

    @Test func newestMessageReplacesCreationTimeAndRefreshesAfterSendAndReply() async throws {
        let entry = try entry()
        let source = TimestampSource()
        await source.set([200])
        #expect(try await SessionRowTimestamp.latest(for: entry, from: source) == Date(timeIntervalSince1970: 200))
        await source.set([200, 300])
        #expect(try await SessionRowTimestamp.latest(for: entry, from: source) == Date(timeIntervalSince1970: 300))
        await source.set([200, 300, 400])
        #expect(try await SessionRowTimestamp.latest(for: entry, from: source) == Date(timeIntervalSince1970: 400))
        let queries = await source.queries
        #expect(queries.count == 3)
        #expect(queries.allSatisfy { $0.sessionID == "tip" && $0.profile == "coder" && $0.order == .latest && $0.limit == 1 && $0.offset == 0 })
    }

    @Test func uncompressedSessionUsesStoredID() async throws {
        let entry = HistoryEntry(profile: "other", summary: SessionSummary(id: "stored"))
        let source = TimestampSource()
        await source.set([200])
        _ = try await SessionRowTimestamp.latest(for: entry, from: source)
        #expect(await source.queries.first?.sessionID == "stored")
        #expect(await source.queries.first?.profile == "other")
    }

    @Test func missingInvalidOrEmptyDatesNeverFallBackToCreation() async throws {
        let entry = try entry()
        let source = TimestampSource()
        for value in [nil, 0, -1, .nan, .infinity] as [Double?] {
            await source.set([value])
            #expect(try await SessionRowTimestamp.latest(for: entry, from: source) == nil)
        }
        await source.set([])
        #expect(try await SessionRowTimestamp.latest(for: entry, from: source) == nil)
    }

    /// A list refresh re-asks every visible row; only rows with new stored messages read again.
    @MainActor
    @Test(.timeLimit(.minutes(1))) func listRefreshesReadOnlyRowsWithNewMessages() async throws {
        let source = TimestampSource()
        await source.set([200])
        let transport = FakeTransport()
        transport.serve(log: FrameLog()) { _, _ in .object([:]) }
        var configuration = GatewayClient.Configuration()
        configuration.heartbeatInterval = nil
        let connection = GatewayConnection(configuration: configuration)
        try await connection.connect(using: FakeConnector([transport], messages: source))
        func row(count: Int?) -> HistoryEntry {
            var summary = SessionSummary(id: "root")
            summary.resolvedID = "tip"
            summary.messageCount = count
            return HistoryEntry(profile: "coder", summary: summary)
        }
        #expect(await connection.latestMessageDate(for: row(count: 1)) == Date(timeIntervalSince1970: 200))
        #expect(await connection.latestMessageDate(for: row(count: 1)) == Date(timeIntervalSince1970: 200))
        #expect(await source.queries.count == 1)
        // A reply stored: the count moves, the date is read again.
        await source.set([200, 300])
        #expect(await connection.latestMessageDate(for: row(count: 2)) == Date(timeIntervalSince1970: 300))
        #expect(await source.queries.count == 2)
        // Another profile's session with the same id is its own row.
        var other = row(count: 2)
        other.profile = "work"
        _ = await connection.latestMessageDate(for: other)
        #expect(await source.queries.count == 3)
        // No count to key on: read each time.
        _ = await connection.latestMessageDate(for: row(count: nil))
        _ = await connection.latestMessageDate(for: row(count: nil))
        #expect(await source.queries.count == 5)
        await connection.disconnect()
    }

    @MainActor
    @Test(.timeLimit(.minutes(1))) func failedReadsAreNotCached() async throws {
        let source = FailingOnceSource()
        let transport = FakeTransport()
        transport.serve(log: FrameLog()) { _, _ in .object([:]) }
        var configuration = GatewayClient.Configuration()
        configuration.heartbeatInterval = nil
        let connection = GatewayConnection(configuration: configuration)
        try await connection.connect(using: FakeConnector([transport], messages: source))
        let entry = HistoryEntry(profile: "coder", summary: try JSONDecoder().decode(
            SessionSummary.self, from: Data(#"{"id":"s","message_count":3}"#.utf8)))
        #expect(await connection.latestMessageDate(for: entry) == nil)
        #expect(await connection.latestMessageDate(for: entry) == Date(timeIntervalSince1970: 500))
        #expect(await source.calls == 2)
        await connection.disconnect()
    }

    @Test func unsupportedPagingNeverMistakesOldestMessageForNewest() async throws {
        let entry = try entry()
        let source = TimestampSource()
        for order in [nil, "oldest"] as [String?] {
            await source.set([200], order: order)
            #expect(try await SessionRowTimestamp.latest(for: entry, from: source) == nil)
        }
        #expect(await source.queries.count == 2) // no whole-history fallback
    }
}
