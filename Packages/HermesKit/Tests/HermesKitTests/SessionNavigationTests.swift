import HermesProtocol
import Testing
@testable import HermesKit

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct SessionNavigationTests {
    private func connect() async throws -> (GatewayConnection, ScriptedGateway) {
        let gateway = ScriptedGateway().withDefaults()
        gateway.on("profiles.list", result: [
            "profiles": [profileRowPayload("coder"), profileRowPayload("default", isDefault: true)],
            "bot_mode_protocol": true, "install_id": "test",
        ])
        gateway.on("session.create", result: createdPayload(sid: "new", key: "new-key"))
        gateway.on("session.resume") { params in
            .result(resumedPayload(sid: "runtime", key: params["session_id"]?.stringValue ?? ""))
        }
        let connection = try await gateway.connect()
        #expect(await eventually { connection.listsRefreshTask == nil })
        return (connection, gateway)
    }

    @Test func navigationDoesNotOpenOrCreateChats() async throws {
        let (connection, gateway) = try await connect()
        #expect(connection.listProfile == "default")
        let active = try await connection.newSideChat(profile: "default")
        #expect(await eventually { connection.listsRefreshTask == nil })
        let composer = connection.composer(for: active)
        composer.draft = "Keep this draft"
        let creates = gateway.params("session.create").count
        connection.navigationPage = .sessions
        connection.selectListProfile("coder")
        await connection.refreshSessionList()
        connection.navigationPage = .bots
        #expect(connection.activeSession === active)
        #expect(connection.composer(for: active) === composer)
        #expect(composer.draft == "Keep this draft")
        #expect(gateway.params("session.create").count == creates)
        #expect(gateway.params("session.resume").isEmpty)
        #expect(gateway.params("prompt.submit").isEmpty)
        #expect(gateway.params("session.interrupt").isEmpty)
    }

    @Test func readsBeyondTwentyAndExpandsFullPrefixWithoutHiddenOrOffset() async throws {
        let (connection, gateway) = try await connect()
        // Plain rows: methods_session.py:118-126,563-577; server applies hidden/source filtering.
        let rows = (0..<250).map { sessionRow(id: "s\($0)") } + [sessionRow(id: "bot", title: "Bot Chat")]
        gateway.on("session.list") { params in
            let limit = params["limit"]?.intValue ?? 200
            return .result(["sessions": .array(Array(rows.prefix(limit)))])
        }
        connection.navigationPage = .sessions
        connection.selectListProfile("coder")
        await connection.refreshSessionList()
        #expect(connection.history.count == 250)
        #expect(connection.history.allSatisfy { $0.profile == "coder" })
        let scoped = gateway.params("session.list").filter { $0["profile"] == "coder" }
        // 251 > 200 grew, so 800 confirms the end.
        #expect(scoped.map { $0["limit"]?.intValue } == [200, 400, 800])
        let entry = try #require(connection.history.last)
        let session = try await connection.open(entry)
        #expect(session.profile == "coder")
        #expect(gateway.params("session.resume").last?["session_id"] == "s249")
        #expect(gateway.params("session.resume").last?["profile"] == "coder")
    }

    @Test func lateProfileResultCannotReplaceNewProfileAndErrorsRetry() async throws {
        let (connection, gateway) = try await connect()
        gateway.on("session.list") { params in
            if params["profile"] == "coder" { return nil }
            return .result(["sessions": [sessionRow(id: "default-session")]])
        }
        connection.selectListProfile("coder")
        let old = Task { await connection.refreshSessionList() }
        #expect(await eventually { gateway.log.requests("session.list").contains { $0["params"]?["profile"] == "coder" } })
        let held = try #require(gateway.log.requests("session.list").last { $0["params"]?["profile"] == "coder" })
        connection.selectListProfile("default")
        await connection.refreshSessionList()
        gateway.transport.respond(to: held, result: ["sessions": [sessionRow(id: "stale")]])
        await old.value
        #expect(connection.history.map(\.summary.id) == ["default-session"])
        #expect(!connection.sessionListLoading)
        gateway.on("session.list") { _ in .error(code: 5006, message: "unavailable") }
        await connection.refreshSessionList()
        #expect(connection.sessionListError != nil)
        #expect(connection.history.map(\.summary.id) == ["default-session"])
        gateway.on("session.list", result: ["sessions": []])
        await connection.refreshSessionList()
        #expect(connection.sessionListError == nil)
        #expect(connection.history.isEmpty)
    }

    /// `session.list` as the server computes it: read `max(2*limit, 200)` rows, drop the
    /// internal sources, cut to `limit` (`methods_session.py:570-571`, `_listing_rows`
    /// :149-152, `INTERNAL_LISTING_SOURCES` in `hermes_state_sessions.py:199`).
    private func serveWithInternalRows(_ gateway: ScriptedGateway, _ raw: [JSONValue]) {
        gateway.on("session.list") { params in
            guard params["title"] == nil else { return .result(["sessions": []]) }
            let limit = params["limit"]?.intValue ?? 200
            let visible = raw.prefix(max(limit * 2, 200)).filter {
                !["kanban", "tool", "oneshot"].contains($0["source"]?.stringValue ?? "")
            }
            return .result(["sessions": .array(Array(visible.prefix(limit)))])
        }
    }

    private func row(_ id: String, source: String) -> JSONValue {
        ["id": .string(id), "title": "", "preview": "", "started_at": 1_700_000_000,
         "message_count": 2, "source": .string(source)]
    }

    @Test func aShortListingCrowdedByInternalRowsIsReadFurther() async throws {
        let (connection, gateway) = try await connect()
        // The 500 newest rows are kanban workers; the human chats are older.
        let raw = (0..<500).map { row("k\($0)", source: "kanban") }
            + (0..<50).map { row("h\($0)", source: "desktop") }
        serveWithInternalRows(gateway, raw)
        connection.navigationPage = .sessions
        connection.selectListProfile("coder")
        await connection.refreshSessionList()
        #expect(connection.history.map(\.summary.id) == (0..<50).map { "h\($0)" })
        let limits = gateway.params("session.list").filter { $0["profile"] == "coder" }.map { $0["limit"]?.intValue }
        #expect(limits == [200, 400, 800])  // 0, then 50, then still 50: the end
    }

    @Test func aSettledListingRefreshesWithOneRead() async throws {
        let (connection, gateway) = try await connect()
        serveWithInternalRows(gateway, (0..<30).map { row("s\($0)", source: "desktop") })
        connection.selectListProfile("coder")
        await connection.refreshSessionList()
        let first = gateway.params("session.list").filter { $0["profile"] == "coder" }.count
        #expect(first == 2)  // the listing, then one larger read that did not grow
        await connection.refreshSessionList()
        let reads = gateway.params("session.list").filter { $0["profile"] == "coder" }
        #expect(reads.count == first + 1)
        #expect(reads.last?["limit"] == 400)
        #expect(connection.history.count == 30)
    }

    @Test func aReconnectDoesNotLeaveTheListLoading() async throws {
        let (connection, gateway) = try await connect()
        gateway.on("session.list") { params in params["profile"] == "coder" ? nil : .result(["sessions": []]) }
        connection.selectListProfile("coder")
        let read = Task { await connection.refreshSessionList() }
        #expect(await eventually { gateway.log.requests("session.list").contains { $0["params"]?["profile"] == "coder" } })
        #expect(connection.sessionListLoading)
        // A reconnect attempt that fails: a new generation, no client, no new read.
        await #expect(throws: (any Error).self) { try await connection.connect(using: FakeConnector([])) }
        await read.value
        #expect(!connection.sessionListLoading)
        #expect(connection.history.isEmpty)
    }
}
