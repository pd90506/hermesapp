import Foundation
import HermesProtocol
import Synchronization
import Testing

@testable import HermesKit

/// A PNG signature and a few bytes: enough for the type sniffing on both sides.
private let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 1, 2, 3, 4])

/// A gateway whose profiles' avatars the test can change: `profiles.list` reports
/// `has_avatar` from the store, and `profiles.get_asset` / `set_asset` read and write it
/// as `methods_profiles.py:411-463` do.
private final class AvatarServer: Sendable {
    let store: Mutex<[String: Data]>
    init(_ store: [String: Data] = [:]) { self.store = Mutex(store) }

    func gateway() -> ScriptedGateway {
        let gateway = ScriptedGateway()
        gateway.on("profiles.list") { _ in
            let store = self.store.withLock { $0 }
            return .result([
                "profiles": [profileRowPayload("default", isDefault: true, hasAvatar: store["default"] != nil),
                             profileRowPayload("coder", hasAvatar: store["coder"] != nil)],
                "bot_mode_protocol": true, "install_id": "test",
            ])
        }
        gateway.on("profiles.get_asset") { params in
            let name = params["name"]?.stringValue ?? ""
            guard let image = self.store.withLock({ $0[name] }) else { return .result(["found": false]) }
            return .result(["found": true, "mime": "image/png", "size": .number(Double(image.count)),
                            "data": .string("data:image/png;base64,\(image.base64EncodedString())")])
        }
        gateway.on("profiles.set_asset") { params in
            let name = params["name"]?.stringValue ?? ""
            if params["clear"]?.boolValue == true {
                let removed = self.store.withLock { $0.removeValue(forKey: name) } == nil ? 0 : 1
                return .result(["ok": true, "asset": "avatar", "size": 0, "removed": .number(Double(removed))])
            }
            guard let image = ProfileAvatar.decode(dataURL: params["data"]?.stringValue ?? "") else {
                return .error(code: 4068, message: "data is not valid base64")
            }
            self.store.withLock { $0[name] = image }
            return .result(["ok": true, "asset": "avatar", "size": .number(Double(image.count))])
        }
        return gateway.withDefaults()
    }
}

@MainActor
@Suite struct ProfileAvatarTests {
    @Test func dataURLsRoundTrip() {
        #expect(ProfileAvatar.dataURL(png).hasPrefix("data:image/png;base64,"))
        #expect(ProfileAvatar.decode(dataURL: ProfileAvatar.dataURL(png)) == png)
        #expect(ProfileAvatar.decode(dataURL: png.base64EncodedString()) == png)
        #expect(ProfileAvatar.mimeType(of: Data([0xFF, 0xD8, 0xFF, 0xE0])) == "image/jpeg")
        #expect(ProfileAvatar.decode(dataURL: "data:image/png,not-base64") == nil)
    }

    @Test func colourComesFromDesktopsBotMeta() throws {
        let row = try profileRowPayload("coder", uiMeta: ["hermes-bots": ["color": "#3B82F6"]]).decode(ProfileRow.self)
        #expect(Bot(profile: row).avatarColor == 0x3B82F6)
        let short = try profileRowPayload("coder", uiMeta: ["hermes-bots": ["color": "#fa0"]]).decode(ProfileRow.self)
        #expect(Bot(profile: short).avatarColor == 0xFFAA00)
        let named = try profileRowPayload("coder", uiMeta: ["hermes-bots": ["color": "blue"]]).decode(ProfileRow.self)
        #expect(Bot(profile: named).avatarColor == nil)
    }

    /// Only the bots marked `has_avatar` are read, once each.
    @Test(.timeLimit(.minutes(1))) func rosterLoadsTheAvatarsItHas() async throws {
        let server = AvatarServer(["coder": png])
        let gateway = server.gateway()
        let connection = try await gateway.connect()
        #expect(await eventually { connection.avatars["coder"] == png })
        #expect(connection.avatars["default"] == nil)
        try await connection.refreshBots()
        #expect(gateway.params("profiles.get_asset").map { $0["name"]?.stringValue } == ["coder"])
        await connection.disconnect()
        #expect(connection.avatars.isEmpty)
    }

    @Test(.timeLimit(.minutes(1))) func setAndRemoveWriteTheServersAsset() async throws {
        let server = AvatarServer()
        let gateway = server.gateway()
        let connection = try await gateway.connect()
        try #require(await eventually { connection.bots.count == 2 })

        try await connection.setAvatar(png, for: "default")
        #expect(server.store.withLock { $0["default"] } == png)
        #expect(connection.avatars["default"] == png)
        #expect(connection.bots.first { $0.name == "default" }?.hasAvatar == true)
        let sent = try #require(gateway.params("profiles.set_asset").first)
        #expect(sent["asset"]?.stringValue == "avatar")
        #expect(sent["data"]?.stringValue?.hasPrefix("data:image/png;base64,") == true)

        try await connection.removeAvatar(for: "default")
        #expect(server.store.withLock { $0["default"] } == nil)
        #expect(connection.avatars["default"] == nil)
        #expect(gateway.params("profiles.set_asset").last?["clear"]?.boolValue == true)
        await connection.disconnect()
    }

    /// An avatar removed elsewhere disappears with the next roster.
    @Test(.timeLimit(.minutes(1))) func avatarGoneFromTheRosterIsDropped() async throws {
        let server = AvatarServer(["coder": png])
        let connection = try await server.gateway().connect()
        try #require(await eventually { connection.avatars["coder"] != nil })
        server.store.withLock { $0["coder"] = nil }
        try await connection.refreshBots()
        #expect(connection.avatars["coder"] == nil)
        await connection.disconnect()
    }
}
