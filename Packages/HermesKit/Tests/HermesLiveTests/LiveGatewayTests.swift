import Foundation
import HermesKit
import HermesProtocol
import Testing

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// End-to-end checks against real dashboards, in the `hermesapp-test` profile.
/// Each test that creates a chat deletes it again, also when it fails.
@Suite("Live Hermes gateway", .serialized, .enabled(if: !LiveServer.all.isEmpty))
@MainActor
struct LiveGatewayTests {
    @Test("Status probe is public and reports a version", arguments: LiveServer.all)
    func status(server: LiveServer) async throws {
        let (data, response) = try await URLSession.shared.data(from: server.endpoint.url(path: "/api/status"))
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect((object?["version"] as? String)?.isEmpty == false)
    }

    @Test("Connects and lists the test profile as a bot", .timeLimit(.minutes(1)), arguments: LiveServer.all)
    func connectsAndListsTestProfile(server: LiveServer) async throws {
        let connection = GatewayConnection()
        try await connection.connect(using: server.connector())
        defer { Task { await connection.disconnect() } }
        #expect(connection.state == .connected)
        try await connection.refreshBots()
        #expect(connection.bots.contains { $0.name == LiveServer.profile },
                "create it with: hermes profile create \(LiveServer.profile) --clone --no-alias")
    }

    @Test("Sends a prompt, streams the reply, reopens it after reconnecting",
          .timeLimit(.minutes(4)), arguments: LiveServer.all)
    func roundTrip(server: LiveServer) async throws {
        let connection = GatewayConnection()
        try await connection.connect(using: server.connector())
        let chat = try await connection.newSideChat(profile: LiveServer.profile)
        var cleanup: (@MainActor () async -> Void)? = { try? await connection.delete(chat) }
        defer {
            Task { @MainActor [cleanup] in
                await cleanup?()
                await connection.disconnect()
            }
        }

        let marker = "PONG-\(Int.random(in: 1000...9999))"
        try await chat.send("Reply with exactly \(marker) and nothing else. Do not use tools.")
        try await waitUntil("the reply to start", timeout: .seconds(60)) { chat.transcript.isRunning }
        try await waitUntil("the reply to finish", timeout: .seconds(150)) { !chat.transcript.isRunning }
        #expect(chat.transcript.lastError == nil)
        let reply = chat.transcript.items.last { $0.role == .assistant }
        #expect(reply?.text.contains(marker) == true, "reply: \(reply?.text ?? "none")")

        // Name it after the first turn so a leftover is recognisable.
        try? await connection.rename(chat, to: "\(LiveServer.chatPrefix) \(marker)")
        let storedID = try #require(chat.storedSessionID)
        await connection.disconnect()

        // A fresh connection finds the chat in the profile's list and reloads it.
        let second = GatewayConnection()
        try await second.connect(using: server.connector())
        cleanup = nil
        defer {
            Task { @MainActor in
                if let entry = second.history.first(where: { $0.summary.id == storedID }) {
                    try? await second.delete(entry)
                }
                await second.disconnect()
            }
        }
        second.selectListProfile(LiveServer.profile)
        await second.refreshSessionList()
        let entry = try #require(second.history.first { $0.summary.id == storedID })
        let reopened = try await second.open(entry)
        try await waitUntil("the stored transcript") {
            reopened.transcript.items.contains { $0.role == .assistant && $0.text.contains(marker) }
        }
        try await second.delete(entry)
        try await waitUntil("the deleted chat to leave the list") {
            !second.history.contains { $0.summary.id == storedID }
        }
    }
}
