import Foundation

// Wire types for the composer: the model and reasoning pickers, image and file
// attachments, slash commands, steering a running turn, and side-chat
// management. Schemas: `apps/shared/src/gateway-contract.openrpc.json`
// (ModelOptions*, ConfigGet*/ConfigSet*, ImageAttachBytesParams,
// AttachedImageResult, ImageDetach*, FileAttach*, CommandsCatalog*, …) and
// `tui_gateway/contracts/`. See `docs/protocol.md` §10.

extension GatewayMethod {
    /// Stages a non-image file for an `@file:` reference (`methods_prompt.py:975-995`).
    public static let fileAttach = "file.attach"
    // Slash commands (`contracts/tools_commands.py:185-305`,
    // `contracts/profiles_vault_complete_foreign_subagents.py:50-67`).
    public static let commandsCatalog = "commands.catalog"
    public static let completeSlash = "complete.slash"
    public static let slashExec = "slash.exec"
    public static let commandDispatch = "command.dispatch"
    // Steering a running turn (`contracts/sessions.py:617-635`, `contracts/prompt_voice.py:221-235`).
    public static let sessionSteer = "session.steer"
    public static let sessionRedirect = "session.redirect"
    public static let promptBtw = "prompt.btw"
    // Slash commands Desktop runs as plain RPCs (`desktop-slash-commands.ts:259-313`).
    public static let promptBackground = "prompt.background"
    public static let sessionCompress = "session.compress"
    public static let sessionSave = "session.save"
    public static let sessionStatus = "session.status"
    public static let processStop = "process.stop"
    // Side-chat management (`contracts/sessions.py:294-303,337-352`).
    public static let sessionArchive = "session.archive"
    public static let sessionDelete = "session.delete"
    /// A copy of a stored session's whole transcript as a new session (`methods_session.py:489-493`).
    public static let sessionBranchStored = "session.branch_stored"
    /// A live session's first `count` visible turns as a new session (`methods_session.py:2202-2204`).
    public static let sessionBranch = "session.branch"
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

// MARK: - file.attach

/// `file.attach`: stage a non-image file (PDFs included) in the session's
/// attachments folder and get its `@file:` reference back
/// (`methods_prompt.py:975-995`, `prompt_attachments.py:187-248`). The app
/// sends the bytes as a `data_url`; `path` is only for gateway-visible files.
public struct FileAttachParams: Sendable, Hashable, Codable {
    public var sessionID: String
    public var name: String?
    public var dataURL: String?
    public var path: String?

    public init(sessionID: String, name: String?, dataURL: String?, path: String? = nil) {
        self.sessionID = sessionID
        self.name = name
        self.dataURL = dataURL
        self.path = path
    }

    enum CodingKeys: String, CodingKey {
        case name, path
        case sessionID = "session_id"
        case dataURL = "data_url"
    }
}

public struct FileAttachResult: Sendable, Hashable, Codable {
    public var attached: Bool
    public var name: String?
    public var path: String?
    public var refPath: String?
    /// `@file:<ref_path>`, quoted when needed; goes into the prompt text.
    public var refText: String?
    public var uploaded: Bool?

    enum CodingKeys: String, CodingKey {
        case attached, name, path, uploaded
        case refPath = "ref_path"
        case refText = "ref_text"
    }
}

// MARK: - Slash commands

/// Params of `commands.catalog` and `complete.slash`. `session_id` binds the
/// answer to that session's profile and workspace (`methods_tools.py:503-537`).
public struct SlashScopeParams: Sendable, Hashable, Codable {
    public var sessionID: String?
    public var profile: String?
    /// `complete.slash` only: the composer text, starting with `/`.
    public var text: String?

    public init(sessionID: String? = nil, profile: String? = nil, text: String? = nil) {
        self.sessionID = sessionID
        self.profile = profile
        self.text = text
    }

    enum CodingKeys: String, CodingKey {
        case profile, text
        case sessionID = "session_id"
    }
}

/// `CommandsCatalogResult` (`contracts/tools_commands.py:190-229`).
public struct CommandsCatalogResult: Sendable, Hashable, Codable {
    public struct Meta: Sendable, Hashable, Codable {
        /// `options` | `text` | `mixed`
        public var argumentMode: String?
        /// Desktop disposition: `hidden`, or why it is unavailable there
        /// (`terminal`, `messaging`, `settings`, `advanced`, `composer-voice`).
        public var desktop: String?
        public var desktopSubcommands: [String]?

        enum CodingKeys: String, CodingKey {
            case desktop
            case argumentMode = "argument_mode"
            case desktopSubcommands = "desktop_subcommands"
        }
    }

    public struct Category: Sendable, Hashable, Codable {
        public var name: String
        /// `[[command, description]]`
        public var pairs: [[String]]?
    }

    public struct Skill: Sendable, Hashable, Codable {
        public var usage: Int?
        public var origin: String?
    }

    /// Every command and skill as `[name, description]`; skills only appear here.
    public var pairs: [[String]]?
    public var canon: [String: String]?
    public var commands: [String: Meta]?
    public var categories: [Category]?
    public var skills: [String: Skill]?
    public var skillCount: Int?
    public var warning: String?

    enum CodingKeys: String, CodingKey {
        case pairs, canon, commands, categories, skills, warning
        case skillCount = "skill_count"
    }
}

/// `CompletionItem` (`contracts/profiles_vault_complete_foreign_subagents.py:23-29`).
public struct SlashCompletionItem: Sendable, Hashable, Codable {
    /// Full `/command` at the command stage; only the argument stub after it.
    public var text: String
    public var display: String?
    public var meta: String?
    /// `command` | `skill`
    public var kind: String?

    public init(text: String, display: String? = nil, meta: String? = nil, kind: String? = nil) {
        self.text = text
        self.display = display
        self.meta = meta
        self.kind = kind
    }
}

/// `CompleteSlashResult` (`…complete_foreign_subagents.py:59-63`, `methods_complete.py:278-331`).
public struct CompleteSlashResult: Sendable, Hashable, Codable {
    public var items: [SlashCompletionItem]
    /// The column the accepted item replaces from: 1 at the command stage,
    /// after the last space at the argument stage.
    public var replaceFrom: Int?

    public init(items: [SlashCompletionItem], replaceFrom: Int? = nil) {
        self.items = items
        self.replaceFrom = replaceFrom
    }

    enum CodingKeys: String, CodingKey {
        case items
        case replaceFrom = "replace_from"
    }
}

/// `slash.exec` (`contracts/tools_commands.py:283-305`).
public struct SlashExecParams: Sendable, Hashable, Codable {
    public var sessionID: String
    /// The command line without its leading `/`.
    public var command: String

    public init(sessionID: String, command: String) {
        self.sessionID = sessionID
        self.command = command
    }

    enum CodingKeys: String, CodingKey {
        case command
        case sessionID = "session_id"
    }
}

/// `command.dispatch` (`contracts/tools_commands.py:247-280`).
public struct CommandDispatchParams: Sendable, Hashable, Codable {
    public var name: String
    public var arg: String?
    public var sessionID: String?

    public init(name: String, arg: String?, sessionID: String?) {
        self.name = name
        self.arg = arg
        self.sessionID = sessionID
    }

    enum CodingKeys: String, CodingKey {
        case name, arg
        case sessionID = "session_id"
    }
}

/// The result of `slash.exec` and `command.dispatch`: plain `output`
/// (+`warning`), or a directive when `type` is set
/// (`SlashExecResult` / `CommandDispatchResult`, `contracts/tools_commands.py:262-305`).
public struct SlashCommandResult: Sendable, Hashable, Codable {
    /// `exec` | `alias` | `plugin` | `send` | `skill` | `prefill`
    public var type: String?
    public var output: String?
    public var warning: String?
    public var target: String?
    /// `send`/`skill`/`prefill`: the text to submit or prefill. For a skill this
    /// is the expanded skill body; UIs show `display`, never `message`.
    public var message: String?
    public var notice: String?
    public var display: String?
    public var name: String?
    public var status: String?

    public init(type: String? = nil, output: String? = nil, message: String? = nil, display: String? = nil) {
        self.type = type
        self.output = output
        self.message = message
        self.display = display
    }
}

// MARK: - Steering

/// `session.steer` / `session.redirect` (`SessionCorrectionParams`, `contracts/sessions.py:623-635`)
/// and `prompt.btw` (`SideAgentParams`, `contracts/prompt_voice.py:221-235`).
public struct SessionTextParams: Sendable, Hashable, Codable {
    public var sessionID: String
    public var text: String

    public init(sessionID: String, text: String) {
        self.sessionID = sessionID
        self.text = text
    }

    enum CodingKeys: String, CodingKey {
        case text
        case sessionID = "session_id"
    }
}

/// `SessionCorrectionResult` (`contracts/sessions.py:617-631`).
public struct SessionCorrectionResult: Sendable, Hashable, Codable {
    /// `queued` | `redirected` | `rejected` (no turn is running: send it as a prompt).
    public var status: String
    public var text: String?
}

/// `TaskIdResult` (`contracts/prompt_voice.py:225-229`).
public struct TaskIDResult: Sendable, Hashable, Codable {
    public var taskID: String

    enum CodingKeys: String, CodingKey { case taskID = "task_id" }
}

// MARK: - Slash commands that are plain RPCs

/// `session.compress` (`SessionCompressParams`, `contracts/sessions.py:565-566`).
public struct SessionCompressParams: Sendable, Hashable, Codable {
    public var sessionID: String
    public var focusTopic: String?

    public init(sessionID: String, focusTopic: String?) {
        self.sessionID = sessionID
        self.focusTopic = focusTopic
    }

    enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case focusTopic = "focus_topic"
    }
}

/// `SessionCompressResult` (`contracts/sessions.py:553-591`). Subset.
public struct SessionCompressResult: Sendable, Hashable, Codable {
    /// `CompressionSummary` (`contracts/sessions.py:553-563`).
    public struct Summary: Sendable, Hashable, Codable {
        public var noop: Bool?
        public var aborted: Bool?
        public var headline: String?
        public var tokenLine: String?
        public var note: String?

        enum CodingKeys: String, CodingKey {
            case noop, aborted, headline, note
            case tokenLine = "token_line"
        }
    }

    /// `compressed` | `aborted` | `pending` (still running on a compute host).
    public var status: String?
    public var removed: Int?
    public var summary: Summary?
    public var compressed: Bool?
    public var message: String?
    public var info: SessionLiveInfo?
}

/// `session.save` result (`contracts/sessions.py:461-465`).
public struct SessionSaveResult: Sendable, Hashable, Codable {
    public var file: String?
}

/// `session.status` result (`contracts/sessions.py:476-477`).
public struct SessionStatusResult: Sendable, Hashable, Codable {
    public var output: String
}

// MARK: - process.stop

/// `process.stop` (`contracts/tools_commands.py:54-64`, `methods_tools.py:265`): kills
/// every background process in the registry; the params are ignored, Desktop sends `{}`.
public struct ProcessStopResult: Sendable, Hashable, Codable {
    /// How many processes were killed.
    public var killed: Int
}

// MARK: - Session management

/// `session.archive` (`contracts/sessions.py:337-352`, `methods_session.py:1252-1279`):
/// `session_id` is a live runtime id first, else a stored id in `profile`'s db.
public struct SessionArchiveParams: Sendable, Hashable, Codable {
    public var sessionID: String
    public var archived: Bool
    public var profile: String?

    public init(sessionID: String, archived: Bool, profile: String?) {
        self.sessionID = sessionID
        self.archived = archived
        self.profile = profile
    }

    enum CodingKeys: String, CodingKey {
        case archived, profile
        case sessionID = "session_id"
    }
}

public struct SessionArchiveResult: Sendable, Hashable, Codable {
    public var archived: Bool
    public var sessionKey: String?

    enum CodingKeys: String, CodingKey {
        case archived
        case sessionKey = "session_key"
    }
}

/// `session.delete` (`contracts/sessions.py:294-303`, `methods_session.py:1175-1198`):
/// `session_id` is the STORED id; refused with 4023 while the session is live in the gateway.
public struct SessionDeleteParams: Sendable, Hashable, Codable {
    public var sessionID: String
    public var profile: String?

    public init(sessionID: String, profile: String?) {
        self.sessionID = sessionID
        self.profile = profile
    }

    enum CodingKeys: String, CodingKey {
        case profile
        case sessionID = "session_id"
    }
}

public struct SessionDeleteResult: Sendable, Hashable, Codable {
    /// The stored id that was deleted.
    public var deleted: String
}

/// `session.branch_stored` (`methods_session.py:330-493`): the gateway copies the
/// parent's visible user/assistant turns server-side into a new session, saves its row
/// at once under the parent's next lineage title (`_seed_branch_row`, `_branch_title`),
/// and answers without the transcript (`messages_omitted`).
public struct SessionBranchStoredParams: Sendable, Hashable, Codable {
    /// The parent's stored id, in `profile`'s db.
    public var parentSessionID: String
    public var profile: String?
    public var source: String?

    public init(parentSessionID: String, profile: String?, source: String? = nil) {
        self.parentSessionID = parentSessionID
        self.profile = profile
        self.source = source
    }

    enum CodingKeys: String, CodingKey {
        case profile, source
        case parentSessionID = "parent_session_id"
    }
}

/// `session.branch` (`tui_gateway/methods_session_branch.py:84-139`): the gateway copies the
/// live session's visible user/assistant turns (`_visible_branch_history`, :21-25), the first
/// `count` of them when given, into a new session, saves its row at once under the parent's
/// next lineage title (`_persist_branch`, `_branch_title`) and starts its runtime on this
/// socket. Desktop's "Branch in new chat" on a reply sends the turns up to that reply
/// (`apps/desktop/src/app/session/hooks/use-session-actions/index.ts:2716-2745,2994-3002`).
public struct SessionBranchParams: Sendable, Hashable, Codable {
    /// The parent's runtime id.
    public var sessionID: String
    public var count: Int?
    /// A retry with the same key gets the same branch, not a second one (`:85-99`).
    public var idempotencyKey: String?

    public init(sessionID: String, count: Int?, idempotencyKey: String? = nil) {
        self.sessionID = sessionID
        self.count = count
        self.idempotencyKey = idempotencyKey
    }

    enum CodingKeys: String, CodingKey {
        case count
        case sessionID = "session_id"
        case idempotencyKey = "idempotency_key"
    }
}

/// The answer of `session.branch_stored` (`session.create`'s shape without `messages`) and
/// of `session.branch` (with them, which the package does not read).
public struct SessionBranchResult: Sendable, Hashable, Codable {
    /// The new session's runtime id.
    public var sessionID: String
    /// The new session's stored id; its row already exists.
    public var storedSessionID: String
    public var messageCount: Int?

    enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case storedSessionID = "stored_session_id"
        case messageCount = "message_count"
    }
}
