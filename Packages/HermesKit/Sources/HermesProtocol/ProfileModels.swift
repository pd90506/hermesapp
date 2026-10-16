import Foundation

// `profiles.list` — the roster a bot sidebar paints from.
// Contract: `tui_gateway/contracts/profiles_vault_complete_foreign_subagents.py:116-186`;
// handler: `tui_gateway/methods_profiles.py:281-302`. Everything except `name` is
// optional so older or newer gateways still decode.

public struct ProfilesListParams: Sendable, Hashable, Codable {
    /// Default true on the server: adds `last_session` / `worker_session` /
    /// `canonical_session` to each row (`methods_profiles.py:286`).
    public var includeSessions: Bool?

    public init(includeSessions: Bool? = nil) { self.includeSessions = includeSessions }

    enum CodingKeys: String, CodingKey { case includeSessions = "include_sessions" }
}

public struct ProfilesListResult: Sendable, Hashable, Codable {
    public var profiles: [ProfileRow]
}

/// One roster row (`ProfileRow`).
public struct ProfileRow: Sendable, Hashable, Codable, Identifiable {
    /// The profile name; pass it as `profile` on scoped calls.
    public var name: String
    public var isDefault: Bool?
    public var model: String?
    public var provider: String?
    public var description: String?
    /// Core display name from profile.yaml (presentation only).
    public var displayName: String?
    /// Newest human-facing session of the profile (`_latest_profile_session_rows`,
    /// `methods_profiles.py:198-228`). Not the bot's chat: never open it from the bot row.
    public var lastSession: ProfileSessionPreview?
    /// Newest kanban/tool worker row; its `last_active` is heartbeated at least
    /// every 60 s while the worker runs (`methods_profiles.py:199-206`).
    public var workerSession: ProfileWorkerSession?
    /// The profile's "Bot Chat" registry row, resolved server-side by title
    /// (`_canonical_session_row`, `methods_profiles.py:161-195`). `nil` = no Bot Chat yet.
    public var canonicalSession: ProfileCanonicalSession?
    /// Free-form per-plugin metadata from profile.yaml (`methods_profiles.py:256-278`).
    public var uiMeta: [String: JSONValue]?
    /// The profile has an `assets/avatar.*` image (`methods_profiles.py:278`); read it
    /// with `profiles.get_asset`.
    public var hasAvatar: Bool?

    public var id: String { name }

    public init(name: String, isDefault: Bool? = nil, displayName: String? = nil,
                canonicalSession: ProfileCanonicalSession? = nil, workerSession: ProfileWorkerSession? = nil,
                hasAvatar: Bool? = nil) {
        self.name = name
        self.isDefault = isDefault
        self.displayName = displayName
        self.canonicalSession = canonicalSession
        self.workerSession = workerSession
        self.hasAvatar = hasAvatar
    }

    enum CodingKeys: String, CodingKey {
        case name, model, provider, description
        case isDefault = "is_default"
        case displayName = "display_name"
        case lastSession = "last_session"
        case workerSession = "worker_session"
        case canonicalSession = "canonical_session"
        case uiMeta = "ui_meta"
        case hasAvatar = "has_avatar"
    }
}

/// `ProfileSessionPreview`. Times are Unix seconds.
public struct ProfileSessionPreview: Sendable, Hashable, Codable {
    public var id: String
    public var title: String?
    public var preview: String?
    public var startedAt: Double?
    public var lastActive: Double?
    public var messageCount: Int?

    enum CodingKeys: String, CodingKey {
        case id, title, preview
        case startedAt = "started_at"
        case lastActive = "last_active"
        case messageCount = "message_count"
    }
}

/// `ProfileWorkerSession`.
public struct ProfileWorkerSession: Sendable, Hashable, Codable {
    public var id: String
    public var source: String?
    public var title: String?
    public var lastActive: Double?

    public init(id: String, source: String? = nil, lastActive: Double? = nil) {
        self.id = id
        self.source = source
        self.lastActive = lastActive
    }

    enum CodingKeys: String, CodingKey {
        case id, source, title
        case lastActive = "last_active"
    }
}

/// `ProfileCanonicalSession`: `id` is the registry row, `resolvedID` the live
/// compression tip; `preview` is the newest user/assistant text of the tip,
/// at most 80 characters plus "..." (`methods_profiles.py:108-122,185-193`).
public struct ProfileCanonicalSession: Sendable, Hashable, Codable {
    public var id: String
    public var resolvedID: String?
    public var rootTitle: String?
    public var title: String?
    public var preview: String?
    public var startedAt: Double?
    public var lastActive: Double?
    public var messageCount: Int?
    public var liveMessageCount: Int?

    public init(id: String, resolvedID: String? = nil, preview: String? = nil, lastActive: Double? = nil) {
        self.id = id
        self.resolvedID = resolvedID
        self.preview = preview
        self.lastActive = lastActive
    }

    enum CodingKeys: String, CodingKey {
        case id, title, preview
        case resolvedID = "resolved_id"
        case rootTitle = "root_title"
        case startedAt = "started_at"
        case lastActive = "last_active"
        case messageCount = "message_count"
        case liveMessageCount = "live_message_count"
    }
}

// `profiles.set_asset` / `profiles.get_asset`: a profile's avatar image, stored on the
// server as `<profile>/assets/avatar.<ext>` (`tui_gateway/methods_profiles.py:411-463`).
// Hermes Desktop's Bots plugin reads and writes the same file (`plugins/hermes-bots/profile-ops.ts`).

public struct ProfileAssetParams: Sendable, Hashable, Codable {
    /// The profile name (`_resolve_profile`, `methods_profiles.py:72-84`).
    public var name: String
    /// `"avatar"` is the only asset (`methods_profiles.py:418-419`).
    public var asset: String
    /// `set_asset`: a data URL or bare base64 of a PNG, JPEG or WebP, at most 2 MB.
    public var data: String?
    /// `set_asset`: removes the asset instead.
    public var clear: Bool?

    public init(name: String, asset: String = "avatar", data: String? = nil, clear: Bool? = nil) {
        self.name = name
        self.asset = asset
        self.data = data
        self.clear = clear
    }
}

public struct ProfileSetAssetResult: Sendable, Hashable, Codable {
    public var ok: Bool?
    public var asset: String?
    public var size: Int?
    /// Files removed by a `clear`.
    public var removed: Int?
}

public struct ProfileGetAssetResult: Sendable, Hashable, Codable {
    /// `false` when the profile has no such asset; not an error (`methods_profiles.py:451`).
    public var found: Bool
    public var mime: String?
    public var size: Int?
    /// `data:<mime>;base64,…`.
    public var data: String?
}
