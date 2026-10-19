import Foundation
import HermesProtocol
import Testing

@testable import HermesKit

/// A connection that drops and gets back within `tryingNoticeDelay` shows nothing; one
/// that keeps trying longer shows it (user, 2026-10-19).
private func server(_ method: String, _ params: JSONValue) -> JSONValue? {
    method == "session.list" ? ["sessions": []] : nil
}

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct ReconnectNoticeTests {
    private func makeConnection(backoff: Duration = .milliseconds(1)) -> GatewayConnection {
        var configuration = GatewayClient.Configuration()
        configuration.heartbeatInterval = nil
        return GatewayConnection(configuration: configuration, backoff: { _ in backoff })
    }

    @Test func aQuickReconnectShowsNothing() async throws {
        let first = FakeTransport(), second = FakeTransport()
        first.serve(log: FrameLog(), server)
        second.serve(log: FrameLog(), server)
        // Slow enough to be seen trying, well inside the quiet time.
        let connection = makeConnection(backoff: .milliseconds(100))
        try await connection.connect(using: FakeConnector([first, second]))
        #expect(connection.shownState == .connected)

        first.serverDrops()
        #expect(await eventually { connection.state == .reconnecting(attempt: 1) })
        #expect(connection.shownState == .connected)
        #expect(!connection.isTryingNoticeably)
        #expect(await eventually { connection.state == .connected })
        #expect(connection.shownState == .connected)
        #expect(!connection.isTryingNoticeably)
    }

    @Test func aLongReconnectShowsOnceTheQuietTimeIsOver() async throws {
        let first = FakeTransport()
        first.serve(log: FrameLog(), server)
        let connection = makeConnection(backoff: .milliseconds(20))
        connection.maxReconnectAttempts = nil
        connection.tryingNoticeDelay = .milliseconds(200)
        // No transports left: every attempt fails.
        try await connection.connect(using: FakeConnector([first]))

        first.serverDrops()
        #expect(await eventually {
            if case .reconnecting = connection.state { return true }
            return false
        })
        #expect(connection.shownState == .connected)
        #expect(await eventually { connection.isTryingNoticeably })
        guard case .reconnecting = connection.shownState else {
            Issue.record("shown as \(connection.shownState) once the quiet time is over")
            return
        }

        await connection.disconnect()
        #expect(!connection.isTryingNoticeably)
        #expect(connection.shownState == .disconnected)
    }

    @Test func aFirstConnectShowsAtOnce() async throws {
        let transport = FakeTransport()
        transport.serve(log: FrameLog(), server)
        let connection = makeConnection()
        let connect = Task { try await connection.connect(using: FakeConnector([transport])) }
        #expect(await eventually { connection.state != .disconnected })
        // Nothing was connected to show meanwhile.
        if connection.state == .connecting { #expect(connection.shownState == .connecting) }
        try await connect.value
        #expect(connection.shownState == .connected)
    }
}
