import Foundation
import HermesKit
import Testing

/// Deletes every chat left in the `hermesapp-test` profile (the UI tests' chats,
/// or a round trip that died before its cleanup). Only that profile is touched.
/// `scripts/live-test.sh` runs it last, with `HERMES_LIVE_SWEEP=1`.
@Suite("Live sweep of the test profile",
       .enabled(if: !LiveServer.all.isEmpty && ProcessInfo.processInfo.environment["HERMES_LIVE_SWEEP"] == "1"))
@MainActor
struct LiveSweepTests {
    @Test("Deletes the test profile's chats", .timeLimit(.minutes(2)), arguments: LiveServer.all)
    func sweep(server: LiveServer) async throws {
        let connection = GatewayConnection()
        try await connection.connect(using: server.connector())
        defer { Task { await connection.disconnect() } }
        connection.selectListProfile(LiveServer.profile)
        await connection.refreshSessionList()
        for entry in connection.history where entry.profile == LiveServer.profile && !connection.isProtected(entry) {
            // A chat another client (the UI-tested app) left live answers 4023 to a
            // plain delete. Resuming it re-binds its runtime here, so it can be closed.
            let chat = try await connection.open(entry)
            try await connection.delete(chat)
        }
        await connection.refreshSessionList()
        #expect(connection.history.allSatisfy { connection.isProtected($0) })
    }
}
