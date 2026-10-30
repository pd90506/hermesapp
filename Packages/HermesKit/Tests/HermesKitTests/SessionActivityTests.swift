import Foundation
import HermesProtocol
import Testing
@testable import HermesKit

/// Serves each session's newest stored message and its prompts' timeline, by stored id.
/// Shapes: `GET /api/sessions/{id}/messages` (`hermes_cli/web_routers/sessions.py:739-798`)
/// and `GET /api/sessions/{id}/timeline` (`:801-820`, `hermes_state_timeline.py:142-166`).
private actor ActivitySource: SessionMessagesSource {
    var newest: [String: StoredMessage] = [:]
    var prompts: [String: [Double]] = [:]
    var timelinePageSize = 500
    var timelineFails = false
    var messageReads = 0
    var timelineQueries: [SessionTimelineQuery] = []

    func set(_ id: String, prompts: [Double], newest: StoredMessage?) {
        self.prompts[id] = prompts
        self.newest[id] = newest
    }

    func configure(pageSize: Int = 500, fails: Bool = false) {
        timelinePageSize = pageSize
        timelineFails = fails
    }

    func messagesPage(_ query: SessionMessagesQuery) async throws -> SessionMessagesPage {
        messageReads += 1
        let rows = newest[query.sessionID].map { [$0] } ?? []
        return SessionMessagesPage(messages: rows, pagination:
            SessionMessagesPagination(limit: query.limit, offset: 0, order: "latest", returned: rows.count))
    }

    func timelinePage(_ query: SessionTimelineQuery) async throws -> SessionTimelinePage {
        timelineQueries.append(query)
        if timelineFails { throw SessionTimelineUnsupported() }
        let all = (prompts[query.sessionID] ?? []).enumerated().map { index, time in
            SessionTimelineEntry(rowID: index + 1, timestamp: time)
        }
        let rest = all.filter { ($0.rowID ?? 0) > query.afterRowID }
        let page = Array(rest.prefix(timelinePageSize))
        let more = rest.count > page.count
        return SessionTimelinePage(entries: page, pagination: SessionTimelinePagination(
            total: all.count, hasMore: more, nextCursor: more ? page.last?.rowID : nil))
    }
}

private func message(_ role: String, at time: Double, toolCalls: JSONValue? = nil) -> StoredMessage {
    var row = StoredMessage(id: 1, role: role)
    row.timestamp = time
    row.toolCalls = toolCalls
    return row
}

private func row(_ id: String, count: Int = 2, profile: String = "coder") -> HistoryEntry {
    var summary = SessionSummary(id: id)
    summary.messageCount = count
    return HistoryEntry(profile: profile, summary: summary)
}

@MainActor
private func connected(_ source: ActivitySource) async throws -> GatewayConnection {
    let transport = FakeTransport()
    transport.serve(log: FrameLog()) { _, _ in .object([:]) }
    var configuration = GatewayClient.Configuration()
    configuration.heartbeatInterval = nil
    let connection = GatewayConnection(configuration: configuration)
    try await connection.connect(using: FakeConnector([transport], messages: source))
    return connection
}

private func date(_ seconds: Double) -> Date { Date(timeIntervalSince1970: seconds) }

struct SessionActivityTests {
    @Test func readsTheLastPromptAndWhetherTheNewestMessageIsAReply() async throws {
        let source = ActivitySource()
        await source.set("a", prompts: [100, 200], newest: message("assistant", at: 260))
        let activity = try await SessionRowActivity.read(for: row("a"), from: source)
        #expect(activity == SessionRowActivity(lastPrompt: date(200), newestMessage: date(260), newestReply: date(260)))
        #expect(activity.listDate == date(200))
    }

    /// A turn still working (a tool row or a call) or a prompt with no answer yet is no reply.
    @Test func stepsOfATurnAreNotReplies() async throws {
        let source = ActivitySource()
        let call: JSONValue = .array([.object(["id": .string("c1")])])
        for newest in [message("tool", at: 300), message("assistant", at: 300, toolCalls: call), message("user", at: 300)] {
            await source.set("a", prompts: [200], newest: newest)
            let activity = try await SessionRowActivity.read(for: row("a"), from: source)
            #expect(activity.newestReply == nil)
            #expect(activity.newestMessage == date(300))
        }
        await source.set("a", prompts: [200], newest: message("assistant", at: 300, toolCalls: .array([])))
        #expect(try await SessionRowActivity.read(for: row("a"), from: source).newestReply == date(300))
    }

    @Test func followsTimelinePagesToTheLastPrompt() async throws {
        let source = ActivitySource()
        await source.configure(pageSize: 2)
        await source.set("a", prompts: [10, 20, 30, 40, 50], newest: message("assistant", at: 60))
        #expect(try await SessionRowActivity.read(for: row("a"), from: source).lastPrompt == date(50))
        #expect(await source.timelineQueries.map(\.afterRowID) == [0, 2, 4])
    }

    /// An older Hermes without the timeline: rows fall back to their newest message.
    @Test func noTimelineFallsBackToTheNewestMessage() async throws {
        let source = ActivitySource()
        await source.configure(fails: true)
        await source.set("a", prompts: [100], newest: message("assistant", at: 150))
        let activity = try await SessionRowActivity.read(for: row("a"), from: source)
        #expect(activity.lastPrompt == nil)
        #expect(activity.listDate == date(150))
    }

    @Test func ordersByDateKeepingUnreadRowsUnderTheRowAbove() {
        let items = ["a", "b", "c", "d"]
        // Server order a, b, c, d (by last activity). b's prompt is newest; c not read yet.
        #expect(SessionListOrder.sorted(items, dates: [date(100), date(300), nil, date(200)]) == ["b", "c", "d", "a"])
        // Nothing read: server order.
        #expect(SessionListOrder.sorted(items, dates: [nil, nil, nil, nil]) == items)
        // Equal dates keep server order.
        #expect(SessionListOrder.sorted(items, dates: [date(1), date(1), date(1), date(1)]) == items)
    }

    @Test func readMarksStartQuietAndClearWhenSeen() {
        var marks = SessionReadMarks()
        // Not started: nothing is unread.
        #expect(!marks.isUnread(profile: "p", id: "a", newestReply: date(500)))
        marks.start(now: date(400))
        marks.start(now: date(900)) // once
        #expect(!marks.isUnread(profile: "p", id: "a", newestReply: date(300)))
        #expect(marks.isUnread(profile: "p", id: "a", newestReply: date(500)))
        #expect(!marks.isUnread(profile: "p", id: "a", newestReply: nil))
        let first = marks.markSeen(profile: "p", id: "a", through: date(500))
        let older = marks.markSeen(profile: "p", id: "a", through: date(450))
        #expect(first && !older)
        #expect(!marks.isUnread(profile: "p", id: "a", newestReply: date(500)))
        #expect(marks.isUnread(profile: "p", id: "a", newestReply: date(501)))
        // Per profile.
        #expect(marks.isUnread(profile: "q", id: "a", newestReply: date(500)))
    }

    /// A list refresh reads every row once; later ones only rows whose stored count moved.
    @MainActor
    @Test(.timeLimit(.minutes(1))) func refreshReadsOnlyRowsWithNewMessages() async throws {
        let source = ActivitySource()
        await source.set("a", prompts: [100], newest: message("assistant", at: 110))
        await source.set("b", prompts: [200], newest: message("assistant", at: 210))
        let connection = try await connected(source)
        await connection.readRowActivity([row("a"), row("b")])
        #expect(await source.messageReads == 2)
        await connection.readRowActivity([row("a"), row("b")])
        #expect(await source.messageReads == 2)
        await source.set("a", prompts: [100], newest: message("assistant", at: 400))
        await connection.readRowActivity([row("a", count: 3), row("b")])
        #expect(await source.messageReads == 3)
        #expect(connection.activity(for: row("a", count: 3))?.newestReply == date(400))
        await connection.disconnect()
    }

    /// The case asked for: two chats answering in turn don't swap places; the one the
    /// user wrote in last stays on top, and the dates and groups follow the prompts.
    @MainActor
    @Test(.timeLimit(.minutes(1))) func repliesDoNotReorderTheList() async throws {
        let source = ActivitySource()
        let now = Date(timeIntervalSince1970: 1_800_000_000).timeIntervalSince1970
        // Server order (last activity): a answered last, but the user wrote in b last.
        await source.set("a", prompts: [now - 120], newest: message("assistant", at: now - 5))
        await source.set("b", prompts: [now - 60], newest: message("assistant", at: now - 10))
        await source.set("c", prompts: [now - 90 * 86400], newest: message("assistant", at: now - 90 * 86400))
        let connection = try await connected(source)
        let rows = [row("a"), row("b"), row("c")]
        await connection.readRowActivity(rows)
        let ordered = connection.sessionListOrder(rows)
        #expect(ordered.map(\.summary.id) == ["b", "a", "c"])
        #expect(connection.listDate(for: rows[0]) == date(now - 120))
        let groups = connection.sessionDateGroups(ordered, now: date(now))
        #expect(groups.map { $0.items.map(\.summary.id) } == [["b", "a"], ["c"]])
        await connection.disconnect()
    }

    @MainActor
    @Test(.timeLimit(.minutes(1))) func repliesAreUnreadUntilSeen() async throws {
        let source = ActivitySource()
        await source.set("a", prompts: [100], newest: message("assistant", at: 2_000_000_000))
        await source.set("b", prompts: [100], newest: message("assistant", at: 50))
        let connection = try await connected(source)
        var marks = SessionReadMarks()
        marks.start(now: date(1_000))
        connection.readMarks = marks
        await connection.readRowActivity([row("a"), row("b")])
        // a's reply came after marks started; b's before.
        #expect(connection.isUnread(row("a")))
        #expect(!connection.isUnread(row("b")))
        // Seen (as when its chat leaves the screen): no longer unread.
        connection.readMarks.markSeen(profile: "coder", id: "a", through: date(2_000_000_000))
        #expect(!connection.isUnread(row("a")))
        await connection.disconnect()
    }
}
