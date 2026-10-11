import Foundation
import HermesKit
import Testing

#if os(macOS)
/// The backend the macOS app starts for itself: a real `hermes serve` on this Mac,
/// found, started, signed in to and stopped as the app does.
@Suite("Live local backend", .serialized,
       .enabled(if: LiveServer.all.contains { $0.name == "local" }))
@MainActor
struct LiveLocalBackendTests {
    @Test("Starts hermes serve, connects with its token, stops it", .timeLimit(.minutes(3)))
    func startConnectStop() async throws {
        let backend = LocalBackendProcess.hermes()
        let running = try await backend.start()
        let connection = GatewayConnection()
        do {
            let connector = DashboardConnector(endpoint: try GatewayEndpoint(running.url),
                                               credential: .sessionToken(running.token))
            try await connection.connect(using: connector)
            #expect(connection.state == .connected)
            try await connection.refreshBots()
            #expect(connection.bots.contains { $0.name == LiveServer.profile })
        } catch {
            await connection.disconnect()
            await backend.stop()
            throw error
        }
        await connection.disconnect()
        await backend.stop()
        #expect(await !backend.isRunning)
        // Nothing listens on the port any more.
        let probe = URLRequest(url: URL(string: "\(running.url)/api/status")!, timeoutInterval: 2)
        await #expect(throws: (any Error).self) { _ = try await URLSession.shared.data(for: probe) }
    }
}
#endif
