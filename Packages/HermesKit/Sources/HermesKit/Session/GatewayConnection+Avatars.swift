import Foundation
import HermesProtocol

/// Profile avatars: images in each profile's asset store on the server, read once per
/// connection for the bots `profiles.list` marks `has_avatar`, as Desktop does
/// (`pullServerAvatars`, `plugins/hermes-bots/profile-ops.ts:165-215`).
extension GatewayConnection {
    /// Reads the avatars not loaded yet and forgets those the roster no longer has.
    func loadAvatars() {
        let withAvatar = Set(bots.filter(\.hasAvatar).map(\.name))
        for name in avatars.keys where !withAvatar.contains(name) { avatars[name] = nil }
        guard let client else { return }
        let gen = generation
        for name in withAvatar where avatars[name] == nil && !avatarLoads.contains(name) {
            avatarLoads.insert(name)
            Task { [weak self] in
                let image = try? await client.profileAvatar(profile: name)
                guard let self, gen == self.generation else { return }
                self.avatarLoads.remove(name)
                // The roster may have dropped it meanwhile.
                if let image, self.bots.contains(where: { $0.name == name && $0.hasAvatar }) {
                    self.avatars[name] = image
                }
            }
        }
    }

    /// Stores `image` (PNG, JPEG or WebP, at most `ProfileAvatar.maxBytes`) as the
    /// profile's avatar on the server and shows it at once.
    public func setAvatar(_ image: Data, for profile: String) async throws {
        guard let client else { throw GatewayClientError.notConnected }
        try await client.setProfileAvatar(profile: profile, image: image)
        avatars[profile] = image
        try? await refreshBots()
    }

    /// Removes the profile's avatar image from the server.
    public func removeAvatar(for profile: String) async throws {
        guard let client else { throw GatewayClientError.notConnected }
        try await client.clearProfileAvatar(profile: profile)
        avatars[profile] = nil
        try? await refreshBots()
    }
}
