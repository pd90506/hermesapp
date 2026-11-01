import Foundation
import HermesProtocol
import Observation

/// A profile's installed capabilities, each with its on/off switch: Desktop's Capabilities
/// page without its catalogs (`apps/desktop/src/app/capabilities/`). Skills, toolsets and
/// MCP servers are read and switched over REST, as Desktop does; plugins over the
/// gateway's `plugins.manage` (`apps/desktop/src/store/agent-plugins.ts`).
public enum CapabilityKind: String, Sendable, CaseIterable, Identifiable {
    case skills, toolsets, mcp, plugins

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .skills: "Skills"
        case .toolsets: "Toolsets"
        case .mcp: "MCP Servers"
        case .plugins: "Plugins"
        }
    }
}

/// One row of a capability list.
public struct Capability: Sendable, Hashable, Identifiable {
    public var kind: CapabilityKind
    /// What the switch is addressed by: the skill, toolset or server name, the plugin's key.
    public var name: String
    public var title: String
    public var detail: String
    /// Where it comes from or what it holds (`bundled`, `hub`, `stdio`, `12 tools`, a version).
    public var tags: [String]
    public var isEnabled: Bool
    /// `nil` when the switch can flip; otherwise why not (a plugin's MCP server, a plugin
    /// row from a server too old to address it by key).
    public var lockedReason: String?
    /// A toolset whose keys aren't set yet: on, it still can't run (`_toolset_has_keys`).
    public var needsSetup: Bool

    public var id: String { "\(kind.rawValue):\(name)" }

    public init(kind: CapabilityKind, name: String, title: String? = nil, detail: String = "", tags: [String] = [],
                isEnabled: Bool, lockedReason: String? = nil, needsSetup: Bool = false) {
        self.kind = kind
        self.name = name
        self.title = title ?? name
        self.detail = detail
        self.tags = tags
        self.isEnabled = isEnabled
        self.lockedReason = lockedReason
        self.needsSetup = needsSetup
    }

    /// A `GET /api/skills` row (`hermes_cli/web_routers/skills.py:343-376`).
    static func skill(_ json: JSONValue) -> Capability? {
        guard let name = json["name"]?.stringValue, !name.isEmpty else { return nil }
        let tags = [json["category"]?.stringValue, json["provenance"]?.stringValue]
            .compactMap { $0 }.filter { !$0.isEmpty }
        return Capability(kind: .skills, name: name, detail: json["description"]?.stringValue ?? "", tags: tags,
                          isEnabled: json["enabled"]?.boolValue ?? true)
    }

    /// A `GET /api/tools/toolsets` row (`hermes_cli/web_routers/tools.py:223-270`).
    static func toolset(_ json: JSONValue) -> Capability? {
        guard let name = json["name"]?.stringValue, !name.isEmpty else { return nil }
        let tools = json["tools"]?.arrayValue?.count ?? 0
        return Capability(kind: .toolsets, name: name, title: json["label"]?.stringValue ?? name,
                          detail: json["description"]?.stringValue ?? "",
                          tags: tools > 0 ? [tools == 1 ? "1 tool" : "\(tools) tools"] : [],
                          isEnabled: json["enabled"]?.boolValue ?? false,
                          needsSetup: json["configured"]?.boolValue == false)
    }

    /// A `GET /api/mcp/servers` row (`hermes_cli/web_server_mcp.py::_mcp_server_summary`).
    /// A plugin's server is switched with its plugin: the route refuses it (409, `mcp.py:372-395`).
    static func mcpServer(_ json: JSONValue) -> Capability? {
        guard let name = json["name"]?.stringValue, !name.isEmpty else { return nil }
        let target = json["url"]?.stringValue
            ?? ([json["command"]?.stringValue].compactMap { $0 } + (json["args"]?.arrayValue?.compactMap(\.stringValue) ?? []))
                .joined(separator: " ")
        let plugin = json["plugin"]?.stringValue
        let tags = [json["transport"]?.stringValue].compactMap { $0 }.filter { $0 != "unknown" }
        return Capability(kind: .mcp, name: name, detail: target, tags: tags,
                          isEnabled: json["enabled"]?.boolValue ?? true,
                          lockedReason: plugin.map { "Provided by the \($0) plugin" })
    }

    /// A `plugins.manage` `list` row (`tui_gateway/methods_tools.py:1662-1700`), when the
    /// Plugins page lists it: plugins the user installed, plus the bundled ones that switch
    /// like them (`isDesktopRelevantPlugin`, `apps/desktop/src/store/agent-plugins.ts:111-132`).
    static func plugin(_ json: JSONValue) -> Capability? {
        guard let name = json["name"]?.stringValue, !name.isEmpty else { return nil }
        let key = json["key"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
        let source = json["source"]?.stringValue ?? ""
        if source == "bundled" {
            guard ["disk-cleanup", "security-guidance"].contains(key ?? name) else { return nil }
        } else if let key, ["dashboard_auth/", "model-providers/", "platforms/"].contains(where: key.hasPrefix) {
            return nil
        }
        let version = json["version"]?.stringValue.flatMap { $0.isEmpty ? nil : "v\($0)" }
        return Capability(kind: .plugins, name: key ?? name, title: name,
                          detail: json["description"]?.stringValue ?? "",
                          tags: [source.isEmpty ? nil : source, version].compactMap { $0 },
                          isEnabled: json["status"]?.stringValue == "enabled",
                          lockedReason: key == nil ? "Update Hermes to switch this plugin from here" : nil)
    }
}

/// What the Capabilities page shows for one profile.
@MainActor
@Observable
public final class CapabilitiesBoard {
    /// The profile the lists are of: `nil` until one is read.
    public internal(set) var profile: String?
    /// Each list once read; a kind not read yet is missing.
    public internal(set) var lists: [CapabilityKind: [Capability]] = [:]
    public internal(set) var errors: [CapabilityKind: String] = [:]
    public internal(set) var loading: Set<CapabilityKind> = []
    /// Rows whose switch is being saved, by `Capability.id`.
    public internal(set) var saving: Set<String> = []
    /// `false` when the connection has no REST access.
    public internal(set) var isAvailable = true
    @ObservationIgnored var tokens: [CapabilityKind: Int] = [:]

    public init() {}

    func reset(to profile: String?) {
        self.profile = profile
        lists = [:]
        errors = [:]
        loading = []
        saving = []
        tokens = tokens.mapValues { $0 + 1 }
    }

    func replace(_ row: Capability) {
        guard let index = lists[row.kind]?.firstIndex(where: { $0.name == row.name }) else { return }
        lists[row.kind]?[index] = row
    }
}

extension GatewayConnection {
    /// Reads one list of `profile`'s capabilities. Another profile's lists are dropped first.
    public func refreshCapabilities(_ kind: CapabilityKind, profile: String) async {
        let board = capabilities
        if board.profile != profile { board.reset(to: profile) }
        let token = (board.tokens[kind] ?? 0) + 1
        board.tokens[kind] = token
        board.loading.insert(kind)
        defer { if board.tokens[kind] == token { board.loading.remove(kind) } }
        do {
            let rows = try await readCapabilities(kind, profile: profile)
            guard board.tokens[kind] == token, board.profile == profile else { return }
            board.isAvailable = true
            board.lists[kind] = rows.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
            board.errors[kind] = nil
        } catch GatewayClientError.notConnected where kind != .plugins && dashboardAPI == nil {
            board.isAvailable = false
        } catch {
            guard board.tokens[kind] == token, board.profile == profile else { return }
            board.errors[kind] = Self.describe(error)
        }
    }

    /// Turns a capability on or off. The row flips at once and flips back if the server refuses.
    public func setCapability(_ row: Capability, enabled: Bool) async throws {
        let board = capabilities
        guard let profile = board.profile, row.lockedReason == nil, !board.saving.contains(row.id) else { return }
        board.saving.insert(row.id)
        defer { board.saving.remove(row.id) }
        var flipped = row
        flipped.isEnabled = enabled
        board.replace(flipped)
        do {
            try await writeCapability(row, enabled: enabled, profile: profile)
        } catch {
            if board.profile == profile { board.replace(row) }
            throw error
        }
    }

    private func readCapabilities(_ kind: CapabilityKind, profile: String) async throws -> [Capability] {
        if kind == .plugins {
            guard let client else { throw GatewayClientError.notConnected }
            let answer = try await client.call("plugins.manage", params: ["action": "list", "profile": .string(profile)])
            return answer["plugins"]?.arrayValue?.compactMap(Capability.plugin) ?? []
        }
        guard let api = dashboardAPI else { throw GatewayClientError.notConnected }
        switch kind {
        case .skills:
            return try await api.get("/api/skills", profile: profile).arrayValue?.compactMap(Capability.skill) ?? []
        case .toolsets:
            return try await api.get("/api/tools/toolsets", profile: profile).arrayValue?.compactMap(Capability.toolset) ?? []
        case .mcp:
            return try await api.get("/api/mcp/servers", profile: profile)["servers"]?.arrayValue?
                .compactMap(Capability.mcpServer) ?? []
        case .plugins:
            return []
        }
    }

    /// Desktop's switches: `PUT /api/skills/toggle` (`skills.py:379-394`), `PUT
    /// /api/tools/toolsets/{name}` (`tools.py:273-335`), `PUT /api/mcp/servers/{name}/enabled`
    /// (`mcp.py:372-395`), `plugins.manage` `toggle` by key (`methods_tools.py:1737-1754`).
    private func writeCapability(_ row: Capability, enabled: Bool, profile: String) async throws {
        if row.kind == .plugins {
            guard let client else { throw GatewayClientError.notConnected }
            let answer = try await client.call("plugins.manage", params: [
                "action": "toggle", "key": .string(row.name), "enable": .bool(enabled), "profile": .string(profile),
            ])
            guard answer["ok"]?.boolValue != false else { throw RPCError(code: 5026, message: "The plugin couldn't be switched.") }
            return
        }
        guard let api = dashboardAPI else { throw GatewayClientError.notConnected }
        let segment = DashboardPath.segment(row.name)
        switch row.kind {
        case .skills:
            _ = try await api.put("/api/skills/toggle", profile: profile,
                                  body: ["name": .string(row.name), "enabled": .bool(enabled)])
        case .toolsets:
            _ = try await api.put("/api/tools/toolsets/\(segment)", profile: profile, body: ["enabled": .bool(enabled)])
        case .mcp:
            _ = try await api.put("/api/mcp/servers/\(segment)/enabled", profile: profile, body: ["enabled": .bool(enabled)])
        case .plugins:
            break
        }
    }
}
