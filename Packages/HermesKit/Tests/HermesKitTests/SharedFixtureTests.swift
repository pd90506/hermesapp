import Foundation
import HermesProtocol
import Testing

@testable import HermesKit

/// The cases in `Packages/fixtures`, which the desktop app's TypeScript core checks too
/// (`Packages/hermes-core/tests/shared-fixtures.test.ts`). Both cores must agree on them;
/// see `Packages/fixtures/README.md`.
@Suite struct SharedFixtureTests {
    static let directory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // HermesKitTests
        .deletingLastPathComponent()  // Tests
        .deletingLastPathComponent()  // HermesKit
        .deletingLastPathComponent()  // Packages
        .appendingPathComponent("fixtures")

    static func load<T: Decodable>(_ name: String, as type: T.Type = T.self) throws -> T {
        try JSONDecoder().decode(T.self, from: Data(contentsOf: directory.appendingPathComponent(name)))
    }

    // MARK: endpoint.json

    struct EndpointFixture: Decodable {
        struct Normalize: Decodable { var input: String; var base: String?; var error: String? }
        struct WebSocket: Decodable { var input: String; var ticket: String; var url: String }
        struct ServerName: Decodable { var url: String; var name: String? }
        var normalize: [Normalize]
        var webSocket: [WebSocket]
        var serverName: [ServerName]
    }

    @Test func endpointNormalisation() throws {
        let fixture = try Self.load("endpoint.json", as: EndpointFixture.self)
        for item in fixture.normalize {
            if let error = item.error {
                do {
                    _ = try GatewayEndpoint(item.input)
                    Issue.record("\(item.input) should fail with \(error)")
                } catch let thrown as GatewayEndpoint.Error {
                    switch thrown {
                    case .invalidURL: #expect(error == "invalidURL", "\(item.input)")
                    case .unsupportedScheme: #expect(error == "unsupportedScheme", "\(item.input)")
                    }
                }
            } else {
                #expect(try GatewayEndpoint(item.input).baseURL.absoluteString == item.base, "\(item.input)")
            }
        }
        for item in fixture.webSocket {
            let url = try GatewayEndpoint(item.input).webSocketURL(query: [URLQueryItem(name: "ticket", value: item.ticket)])
            #expect(url.absoluteString == item.url, "\(item.input)")
        }
        for item in fixture.serverName {
            #expect(ServerConfig.defaultName(for: item.url) == item.name, "\(item.url)")
        }
    }

    // MARK: bots.json

    struct BotsFixture: Decodable {
        struct Expected: Decodable {
            var name: String
            var displayName: String
            var preview: String?
            var chatStoredIDs: [String]
            var activity: String
        }
        var now: Double
        var profiles: [ProfileRow]
        var expected: [Expected]
    }

    @Test func botRoster() throws {
        let fixture = try Self.load("bots.json", as: BotsFixture.self)
        let roster = Bot.roster(fixture.profiles)
        #expect(roster.map(\.name) == fixture.expected.map(\.name))
        let now = Date(timeIntervalSince1970: fixture.now)
        for item in fixture.expected {
            let bot = try #require(roster.first { $0.name == item.name })
            #expect(bot.displayName == item.displayName, "\(item.name)")
            #expect(bot.preview == item.preview, "\(item.name)")
            #expect(bot.chatStoredIDs == Set(item.chatStoredIDs), "\(item.name)")
            #expect(Self.name(of: bot.activity(now: now)) == item.activity, "\(item.name)")
        }
    }

    static func name(of activity: BotActivity) -> String {
        switch activity {
        case .idle: "idle"
        case .recent: "recent"
        case .working: "working"
        case .waitingForYou: "waitingForYou"
        }
    }

    // MARK: session-list.json

    struct SessionListFixture: Decodable {
        var canonicalSession: ProfileCanonicalSession
        var rows: [SessionSummary]
        var listed: [String]

        enum CodingKeys: String, CodingKey {
            case rows, listed
            case canonicalSession = "canonical_session"
        }
    }

    /// The rule `GatewayConnection.refreshSessionList` applies to a profile's rows.
    @MainActor @Test func listedSessions() throws {
        let fixture = try Self.load("session-list.json", as: SessionListFixture.self)
        let bot = Bot(profile: ProfileRow(name: "default", canonicalSession: fixture.canonicalSession))
        let listed = fixture.rows.filter { row in
            SessionSourceSettings.isListed(row.source) && !GatewayConnection.isBotChat(row, of: bot)
        }
        #expect(listed.map(\.id) == fixture.listed)
    }

    // MARK: server-requests.json

    struct ServerRequestsFixture: Decodable {
        struct Declined: Decodable { var method: String; var code: Int }
        var declined: [Declined]
        var supported: [String]
    }

    @Test func declinedServerRequests() throws {
        let fixture = try Self.load("server-requests.json", as: ServerRequestsFixture.self)
        for item in fixture.declined {
            #expect(GatewayClient.decline(item.method).code == item.code, "\(item.method)")
        }
        #expect(ServerRequestMethod.mvpSupported == Set(fixture.supported))
    }

    // MARK: session-projection.json

    struct ProjectionFixture: Decodable {
        struct Shown: Decodable, Equatable {
            var role: String
            var text: String
            var reasoning: String?
            var toolName: String?
            var detail: String?
            var attachments: [String]?
            var images: [String]?
            var rowID: Int?
        }
        struct Case: Decodable {
            var name: String
            var startsSession: Bool
            var rows: [StoredMessage]
            var expected: [Shown]
        }
        var cases: [Case]
    }

    /// The rows `ChatSession` shows for a stored page (`StoredMessageProjection.items`).
    @Test func storedRowsAsChatRows() throws {
        let fixture = try Self.load("session-projection.json", as: ProjectionFixture.self)
        for item in fixture.cases {
            var calls: StoredMessageProjection.ToolCalls = [:]
            let shown = StoredMessageProjection.items(from: item.rows, toolCalls: &calls, startsSession: item.startsSession)
                .map { row in
                    ProjectionFixture.Shown(
                        role: "\(row.role)", text: row.text, reasoning: row.reasoning.isEmpty ? nil : row.reasoning,
                        toolName: row.toolName, detail: row.detail,
                        attachments: row.attachments.isEmpty ? nil : row.attachments,
                        images: row.images.isEmpty ? nil : row.images.compactMap(\.path), rowID: row.rowID)
                }
            #expect(shown == item.expected, "\(item.name)")
        }
    }

    // MARK: servers-auth.json

    struct ServersAuthFixture: Decodable {
        struct Pair: Decodable { var verifier: String; var challenge: String }
        struct Ready: Decodable { var output: String; var port: Int? }
        var pkce: [Pair]
        var readyPort: [Ready]
    }

    @Test func pkceChallenges() throws {
        let fixture = try Self.load("servers-auth.json", as: ServersAuthFixture.self)
        for item in fixture.pkce {
            #expect(PKCE(verifier: item.verifier).challenge == item.challenge, "\(item.verifier)")
        }
    }

    @Test func localBackendReadyPort() throws {
        let fixture = try Self.load("servers-auth.json", as: ServersAuthFixture.self)
        for item in fixture.readyPort {
            #expect(LocalBackend.readyPort(in: item.output) == item.port, "\(item.output)")
        }
    }
}
