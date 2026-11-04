import Foundation
import HermesProtocol
import Testing

@testable import HermesKit

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The server's side of `SessionReadSource`: a watermark per stored id, stamped by a write.
private actor ReadSource: SessionMessagesSource, SessionReadSource {
    var newest: [String: Double] = [:]
    var watermarks: [String: Double] = [:]
    var marked: [String] = []
    var writesFail = false

    func set(_ id: String, newest: Double, watermark: Double = 0) {
        self.newest[id] = newest
        watermarks[id] = watermark
    }

    func setWatermark(_ id: String, _ read: Double) { watermarks[id] = read }
    func failWrites(_ fail: Bool) { writesFail = fail }

    func messagesPage(_ query: SessionMessagesQuery) async throws -> SessionMessagesPage {
        var row = StoredMessage(id: 1, role: "assistant")
        row.timestamp = newest[query.sessionID]
        return SessionMessagesPage(messages: [row], pagination:
            SessionMessagesPagination(limit: query.limit, offset: 0, order: "latest", returned: 1))
    }

    func readWatermarks(profile: String) async throws -> [String: Double] { watermarks }

    func markRead(sessionID: String, profile: String) async throws {
        marked.append(sessionID)
        if writesFail { throw DashboardError.http(status: 503, body: "owner_unreachable") }
        watermarks[sessionID] = max(watermarks[sessionID] ?? 0, newest[sessionID] ?? 0)
    }
}

private func row(_ id: String, count: Int = 2) -> HistoryEntry {
    var summary = SessionSummary(id: id)
    summary.messageCount = count
    return HistoryEntry(profile: "coder", summary: summary)
}

private func date(_ seconds: Double) -> Date { Date(timeIntervalSince1970: seconds) }

@MainActor
private func connected(_ source: ReadSource, marksSince: Double = 1_000) async throws -> GatewayConnection {
    let transport = FakeTransport()
    transport.serve(log: FrameLog()) { _, _ in .object([:]) }
    var configuration = GatewayClient.Configuration()
    configuration.heartbeatInterval = nil
    let connection = GatewayConnection(configuration: configuration)
    try await connection.connect(using: FakeConnector([transport], messages: source, read: source))
    var marks = SessionReadMarks()
    marks.start(now: date(marksSince))
    connection.readMarks = marks
    return connection
}

/// `SessionReadMarks` shared through Hermes's watermark (`sessions.last_read_at`).
@Suite(.timeLimit(.minutes(1))) @MainActor struct SessionReadSyncTests {
    /// The case asked for: read on the iPhone, not unread on the Mac.
    @Test func aReplyReadElsewhereIsNotUnreadHere() async throws {
        let source = ReadSource()
        await source.set("a", newest: 2_000, watermark: 2_100)
        await source.set("b", newest: 2_000, watermark: 1_900)
        let connection = try await connected(source)
        await connection.readRowActivity([row("a"), row("b")])
        #expect(!connection.isUnread(row("a")))
        #expect(connection.isUnread(row("b")))
        // Read elsewhere later: the next list clears it.
        await source.setWatermark("b", 2_100)
        await connection.readRowActivity([row("a"), row("b")])
        #expect(!connection.isUnread(row("b")))
        #expect(await source.marked.isEmpty)
        await connection.disconnect()
    }

    @Test func aReplyAfterTheWatermarkIsUnread() async throws {
        let source = ReadSource()
        await source.set("a", newest: 3_000, watermark: 2_000)
        let connection = try await connected(source)
        await connection.readRowActivity([row("a")])
        #expect(connection.isUnread(row("a")))
        #expect(await source.marked.isEmpty)
        await connection.disconnect()
    }

    /// What this device saw before marks were shared, or while the server was away.
    @Test func whatWasSeenHereReachesTheServerAndOnlyOnce() async throws {
        let source = ReadSource()
        await source.set("seen", newest: 2_000)
        await source.set("unseen", newest: 2_000)
        await source.set("beforeMarks", newest: 500)
        let connection = try await connected(source)
        connection.readMarks.markSeen(profile: "coder", id: "seen", through: date(2_500))
        let rows = [row("seen"), row("unseen"), row("beforeMarks")]
        await connection.readRowActivity(rows)
        #expect(await eventuallyAsync { await source.marked == ["seen"] })
        await connection.readRowActivity(rows)
        await connection.readPushTask?.value
        #expect(await source.marked == ["seen"])
        await connection.disconnect()
    }

    @Test func aFailedWriteIsNotRetriedOnEveryList() async throws {
        let source = ReadSource()
        await source.failWrites(true)
        await source.set("a", newest: 2_000)
        let connection = try await connected(source)
        connection.readMarks.markSeen(profile: "coder", id: "a", through: date(2_500))
        await connection.readRowActivity([row("a")])
        #expect(await eventuallyAsync { await source.marked == ["a"] })
        await connection.readPushTask?.value
        await connection.readRowActivity([row("a")])
        await connection.readPushTask?.value
        #expect(await source.marked == ["a"])
        await connection.disconnect()
    }

    /// A row the server didn't list has no known watermark: nothing to compare with.
    @Test func aRowPastTheServersPageIsLeftAlone() async throws {
        let source = ReadSource()
        await source.set("a", newest: 2_000)
        let connection = try await connected(source)
        connection.readMarks.markSeen(profile: "coder", id: "other", through: date(2_500))
        await connection.readRowActivity([row("other")])
        await connection.readPushTask?.value
        #expect(await source.marked.isEmpty)
        await connection.disconnect()
    }

    @MainActor
    private func eventuallyAsync(_ condition: @MainActor () async -> Bool) async -> Bool {
        for _ in 0..<300 {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return await condition()
    }
}

/// The dashboard's fenced write, shaped as `apps/desktop/src/api/sessions.ts:380-428` sends it.
@Suite(.timeLimit(.minutes(1))) struct SessionReadRequestTests {
    private static let snapshot = FakeHTTP.Reply(status: 200,
        body: #"{"session_id":"a","exists":true,"runtime_revision":7,"runtime_generation":2}"#)
    private static let written = FakeHTTP.Reply(status: 200, body: #"{"ok":true}"#)

    private func connector(_ http: FakeHTTP) throws -> DashboardConnector {
        DashboardConnector(endpoint: try GatewayEndpoint("https://hermes.example.ts.net"),
                           credential: .bearer(accessToken: "tok"), http: http)
    }

    @Test func readsWatermarksOfTheRecentListedRows() async throws {
        let http = FakeHTTP([.init(status: 200, body:
            #"{"sessions":[{"id":"a","last_read_at":1800000000.5},{"id":"b","last_read_at":null}],"total":2}"#)])
        let marks = try await connector(http).readWatermarks(profile: "coder")
        #expect(marks == ["a": 1_800_000_000.5, "b": 0])
        #expect(http.requests.first?.url?.absoluteString ==
                "https://hermes.example.ts.net/api/sessions?profile=coder&limit=100&order=recent&sources=desktop,tui")
    }

    @Test func writesWithTheSnapshotsRevision() async throws {
        let http = FakeHTTP([Self.snapshot, Self.written])
        try await connector(http).markRead(sessionID: "a", profile: "coder")
        let requests = http.requests
        #expect(requests.map(\.httpMethod) == ["GET", "PATCH"])
        #expect(requests[0].url?.absoluteString ==
                "https://hermes.example.ts.net/api/sessions/a/mutation-snapshot?profile=coder")
        #expect(requests[1].url?.path == "/api/sessions/a")
        let body = try JSONDecoder().decode(JSONValue.self, from: try #require(requests[1].httpBody))
        #expect(body["unread"] == .bool(false))
        #expect(body["expected_revision"] == .number(7))
        #expect(body["expected_generation"] == .number(2))
        #expect(body["profile"] == .string("coder"))
        #expect(body["request_id"]?.stringValue?.isEmpty == false)
    }

    /// A turn moved the revision in between: a new snapshot, a new request id.
    @Test func retriesOnceOnAConflict() async throws {
        let http = FakeHTTP([Self.snapshot, .init(status: 409, body: #"{"detail":"revision_conflict"}"#),
                             Self.snapshot, Self.written])
        try await connector(http).markRead(sessionID: "a", profile: "coder")
        #expect(http.requests.map(\.httpMethod) == ["GET", "PATCH", "GET", "PATCH"])
    }
}
