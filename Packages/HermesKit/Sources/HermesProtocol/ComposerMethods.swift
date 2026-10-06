import Foundation

// Wire types for the composer: the model and reasoning pickers and image
// attachments. Schemas: `apps/shared/src/gateway-contract.openrpc.json`
// (ModelOptions*, ConfigGet*/ConfigSet*, ImageAttachBytesParams,
// AttachedImageResult, ImageDetach*). See `docs/protocol.md` §10.

extension GatewayMethod {
    /// Provider/model inventory for the picker (`tui_gateway/methods_complete.py:357-369`).
    public static let modelOptions = "model.options"
    /// One normalised config value (`tui_gateway/methods_config.py:258-270`).
    public static let configGet = "config.get"
    /// One config key, session-scoped for `model` / `reasoning` when a live
    /// `session_id` is given (`tui_gateway/methods_config_set.py:482-504`).
    public static let configSet = "config.set"
    /// Queues base64 image bytes for the next turn (`methods_prompt.py:886-914`).
    public static let imageAttachBytes = "image.attach_bytes"
    /// Drops a queued image before the turn is sent (`methods_prompt.py:998-1010`).
    public static let imageDetach = "image.detach"
}

// MARK: - model.options

public struct ModelOptionsParams: Sendable, Hashable, Codable {
    /// The live session whose agent's provider/model the inventory layers over.
    public var sessionID: String?
    public var profile: String?
    /// Only providers the user configured explicitly; Desktop's chat picker
    /// sends `true` (`apps/desktop/src/lib/model-options.ts:146-169`).
    public var explicitOnly: Bool?

    public init(sessionID: String? = nil, profile: String? = nil, explicitOnly: Bool? = true) {
        self.sessionID = sessionID
        self.profile = profile
        self.explicitOnly = explicitOnly
    }

    enum CodingKeys: String, CodingKey {
        case profile
        case sessionID = "session_id"
        case explicitOnly = "explicit_only"
    }
}

/// `{providers, model, provider}` (`hermes_cli/inventory.py:165`).
public struct ModelOptionsResult: Sendable, Hashable, Codable {
    public var providers: [ModelOptionProvider]
    /// The current model/provider of the session's agent (or the profile default).
    public var model: String?
    public var provider: String?

    public init(providers: [ModelOptionProvider], model: String? = nil, provider: String? = nil) {
        self.providers = providers
        self.model = model
        self.provider = provider
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        providers = try container.decodeIfPresent([ModelOptionProvider].self, forKey: .providers) ?? []
        model = try container.decodeIfPresent(String.self, forKey: .model)
        provider = try container.decodeIfPresent(String.self, forKey: .provider)
    }
}

/// One provider row (`ModelOptionProvider`; `hermes_cli/inventory.py:74-165`). Subset.
public struct ModelOptionProvider: Sendable, Hashable, Codable {
    public var slug: String
    public var name: String
    public var models: [String]
    public var isCurrent: Bool?
    public var authenticated: Bool?
    public var warning: String?
    /// Per model id: `{fast, reasoning, ultrafast?, can_disable_reasoning?}`
    /// (`hermes_cli/inventory.py:317-362`).
    public var capabilities: [String: ModelCapabilities]?

    public init(slug: String, name: String, models: [String], isCurrent: Bool? = nil,
                capabilities: [String: ModelCapabilities]? = nil) {
        self.slug = slug
        self.name = name
        self.models = models
        self.isCurrent = isCurrent
        self.capabilities = capabilities
    }

    enum CodingKeys: String, CodingKey {
        case slug, name, models, authenticated, warning, capabilities
        case isCurrent = "is_current"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        slug = try container.decode(String.self, forKey: .slug)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? slug
        models = try container.decodeIfPresent([String].self, forKey: .models) ?? []
        isCurrent = try container.decodeIfPresent(Bool.self, forKey: .isCurrent)
        authenticated = try container.decodeIfPresent(Bool.self, forKey: .authenticated)
        warning = try container.decodeIfPresent(String.self, forKey: .warning)
        // A malformed capabilities map must not hide the whole provider.
        capabilities = try? container.decodeIfPresent([String: ModelCapabilities].self, forKey: .capabilities)
    }
}

/// `ModelCapabilities` (`inventory.py::_apply_capabilities`). `reasoning`
/// defaults to true when the catalog is silent.
public struct ModelCapabilities: Sendable, Hashable, Codable {
    public var fast: Bool?
    public var reasoning: Bool?
    /// `false` on reasoning-mandatory models: thinking cannot be turned off.
    public var canDisableReasoning: Bool?

    public init(fast: Bool? = nil, reasoning: Bool? = nil, canDisableReasoning: Bool? = nil) {
        self.fast = fast
        self.reasoning = reasoning
        self.canDisableReasoning = canDisableReasoning
    }

    enum CodingKeys: String, CodingKey {
        case fast, reasoning
        case canDisableReasoning = "can_disable_reasoning"
    }
}

// MARK: - config.get / config.set

public struct ConfigGetParams: Sendable, Hashable, Codable {
    public var key: String
    /// With `key: "reasoning"`, answers with the session's live pin
    /// (`methods_config.py:206-224`).
    public var sessionID: String?
    public var profile: String?

    public init(key: String, sessionID: String? = nil, profile: String? = nil) {
        self.key = key
        self.sessionID = sessionID
        self.profile = profile
    }

    enum CodingKeys: String, CodingKey {
        case key, profile
        case sessionID = "session_id"
    }
}

/// `ConfigGetResult` subset: `reasoning` answers `{value, display}`.
public struct ConfigGetResult: Sendable, Hashable, Codable {
    public var value: String?
    public var display: String?

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        value = try? container.decodeIfPresent(String.self, forKey: .value)
        display = try? container.decodeIfPresent(String.self, forKey: .display)
    }
}

public struct ConfigSetParams: Sendable, Hashable, Codable {
    public var key: String
    public var value: String
    public var sessionID: String?
    public var profile: String?
    /// `global` widens `reasoning` to the profile config. Never sent by this client.
    public var scope: String?
    /// Resend of a model switch the gateway asked to confirm.
    public var confirmExpensiveModel: Bool?

    public init(key: String, value: String, sessionID: String? = nil, profile: String? = nil,
                scope: String? = nil, confirmExpensiveModel: Bool? = nil) {
        self.key = key
        self.value = value
        self.sessionID = sessionID
        self.profile = profile
        self.scope = scope
        self.confirmExpensiveModel = confirmExpensiveModel
    }

    enum CodingKeys: String, CodingKey {
        case key, value, profile, scope
        case sessionID = "session_id"
        case confirmExpensiveModel = "confirm_expensive_model"
    }
}

/// `ConfigSetResult` subset. A model switch answers `{key, value, warning,
/// confirm_required, confirm_message, scope}` and, mid-turn, `deferred`
/// (`methods_config_set.py:62-90,161-163`); `reasoning` answers `{key, value}` (:336).
public struct ConfigSetResult: Sendable, Hashable, Codable {
    public var key: String?
    /// A string for `model` / `reasoning`; a bool only for display toggles.
    public var value: JSONValue?
    public var warning: String?
    /// The switch was NOT applied; resend with `confirm_expensive_model: true` to apply it.
    public var confirmRequired: Bool?
    public var confirmMessage: String?
    public var scope: String?
    /// Picked during a running turn: applied when the next turn starts.
    public var deferred: Bool?

    public init(key: String? = nil, value: JSONValue? = nil) {
        self.key = key
        self.value = value
    }

    enum CodingKeys: String, CodingKey {
        case key, value, warning, scope, deferred
        case confirmRequired = "confirm_required"
        case confirmMessage = "confirm_message"
    }
}

// MARK: - image.attach_bytes / image.detach

public struct ImageAttachBytesParams: Sendable, Hashable, Codable {
    public var sessionID: String
    public var profile: String?
    public var contentBase64: String
    /// Its extension decides the stored type; it must be one Hermes accepts
    /// (`prompt_attachments.py:64-79`), else the call fails with 4016.
    public var filename: String?

    public init(sessionID: String, profile: String? = nil, contentBase64: String, filename: String?) {
        self.sessionID = sessionID
        self.profile = profile
        self.contentBase64 = contentBase64
        self.filename = filename
    }

    enum CodingKeys: String, CodingKey {
        case profile, filename
        case sessionID = "session_id"
        case contentBase64 = "content_base64"
    }
}

/// `AttachedImageResult` (`methods_prompt.py:1222-1226` + `server.py:861-870`).
public struct AttachedImageResult: Sendable, Hashable, Codable {
    public var attached: Bool
    /// The gateway-side path; `image.detach` takes it back.
    public var path: String?
    public var name: String?
    public var width: Int?
    public var height: Int?
    public var tokenEstimate: Int?
    /// Images queued for the next turn, this one included.
    public var count: Int?
    public var bytes: Int?
    /// Why nothing was attached (`attached: false`).
    public var message: String?

    enum CodingKeys: String, CodingKey {
        case attached, path, name, width, height, count, bytes, message
        case tokenEstimate = "token_estimate"
    }
}

public struct ImageDetachParams: Sendable, Hashable, Codable {
    public var sessionID: String
    public var profile: String?
    public var path: String

    public init(sessionID: String, profile: String? = nil, path: String) {
        self.sessionID = sessionID
        self.profile = profile
        self.path = path
    }

    enum CodingKeys: String, CodingKey {
        case profile, path
        case sessionID = "session_id"
    }
}

public struct ImageDetachResult: Sendable, Hashable, Codable {
    public var detached: Bool
    public var count: Int
}
