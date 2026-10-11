import Foundation
import Testing

@testable import HermesKit

@Suite struct ServerListTests {
    @Test func migratesTheSingleServerSetting() throws {
        // As the app's `ConnectionSettings` wrote it under "connectionSettings.v1".
        let legacy = Data(#"{"serverURL":"https://hermes.example.ts.net","authMode":"accessToken","provider":"basic","username":"me"}"#.utf8)
        let loaded = ServerList.load(current: nil, legacy: legacy)
        let server = try #require(loaded.servers.first)
        #expect(loaded.servers.count == 1)
        #expect(loaded.migrated == server)
        #expect(server.serverURL == "https://hermes.example.ts.net")
        #expect(server.authMode == .accessToken)
        #expect(server.username == "me")
        #expect(server.displayName == "hermes")
        #expect(server.secretAccount == "gateway-secret.\(server.id.uuidString)")
        #expect(server.secretAccount != ServerList.legacySecretAccount)
    }

    @Test func noServerFromAnEmptyOrMissingLegacySetting() {
        #expect(ServerList.load(current: nil, legacy: nil).servers.isEmpty)
        let blank = Data(#"{"serverURL":"","authMode":"password","provider":"basic","username":""}"#.utf8)
        let loaded = ServerList.load(current: nil, legacy: blank)
        #expect(loaded.servers.isEmpty)
        #expect(loaded.migrated == nil)
    }

    @Test func aSavedListWinsOverTheLegacySetting() throws {
        let legacy = Data(#"{"serverURL":"https://old.example.ts.net"}"#.utf8)
        let saved = [ServerConfig(name: "NUC", serverURL: "https://nuc.example.ts.net"),
                     ServerConfig(serverURL: "127.0.0.1:9139", authMode: .sessionToken)]
        let loaded = ServerList.load(current: try #require(ServerList.encode(saved)), legacy: legacy)
        #expect(loaded.servers == saved)
        #expect(loaded.migrated == nil)
        // Removing every server is remembered too: the old setting doesn't come back.
        let empty = ServerList.load(current: try #require(ServerList.encode([])), legacy: legacy)
        #expect(empty.servers.isEmpty)
    }

    @Test func decodesEntriesMissingNewerFields() throws {
        let id = UUID()
        let data = Data(#"[{"id":"\#(id.uuidString)","serverURL":"https://a.example.ts.net","authMode":"unknownMode"}]"#.utf8)
        let server = try #require(ServerList.load(current: data, legacy: nil).servers.first)
        #expect(server.id == id)
        #expect(server.name.isEmpty)
        #expect(server.authMode == .password)
        #expect(server.provider == "basic")
    }

    @Test(arguments: [
        ("https://panda.example.ts.net", "panda"),
        ("hermes.example.ts.net:9119", "hermes"),
        ("http://127.0.0.1:9139", "127.0.0.1:9139"),
        ("localhost:9119", "localhost:9119"),
        ("http://[::1]:9119/", "[::1]:9119"),
        ("", "New Server"),
    ])
    func derivesANameFromTheURL(url: String, name: String) {
        #expect(ServerConfig(serverURL: url).displayName == name)
    }

    @Test func aGivenNameWins() {
        #expect(ServerConfig(name: "  Home  ", serverURL: "https://nuc.example.ts.net").displayName == "Home")
    }

    @Test func authModesMapOntoCredentials() {
        var server = ServerConfig(serverURL: "x", provider: "basic", username: "u")
        #expect(server.credential(secret: "p") == .password(provider: "basic", username: "u", password: "p"))
        server.authMode = .accessToken
        #expect(server.credential(secret: "t") == .bearer(accessToken: "t"))
        server.authMode = .sessionToken
        #expect(server.credential(secret: "t") == .sessionToken("t"))
    }
}
