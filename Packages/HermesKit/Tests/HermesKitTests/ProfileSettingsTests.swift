import Foundation
import HermesProtocol
import Synchronization
import Testing

@testable import HermesKit

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// A dashboard answering `"METHOD path"` from a script, recording every call.
final class FakeDashboardAPI: DashboardAPI, @unchecked Sendable {
    struct Call: Sendable, Equatable {
        var method: String
        var path: String
        var query: [String: String]
        var body: JSONValue?
    }

    private let state: Mutex<(answers: [String: [Result<JSONValue, CronRequestError>]], calls: [Call])>

    init(_ answers: [String: JSONValue] = [:]) {
        state = Mutex((answers.mapValues { [.success($0)] }, []))
    }

    /// Queues answers for a call; the last one repeats.
    func on(_ call: String, _ answers: Result<JSONValue, CronRequestError>...) {
        state.withLock { $0.answers[call] = answers }
    }

    var calls: [Call] { state.withLock { $0.calls } }
    func calls(_ method: String) -> [Call] { calls.filter { $0.method == method } }

    func send(_ method: String, _ path: String, query: [URLQueryItem], body: JSONValue?,
              timeout: TimeInterval?) async throws -> JSONValue {
        let answer = state.withLock { state -> Result<JSONValue, CronRequestError>? in
            state.calls.append(Call(method: method, path: path,
                                    query: Dictionary(query.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { $1 }),
                                    body: body))
            let key = "\(method) \(path)"
            guard var queue = state.answers[key], !queue.isEmpty else { return nil }
            let next = queue.count > 1 ? queue.removeFirst() : queue[0]
            state.answers[key] = queue
            return next
        }
        guard let answer else { throw CronRequestError(status: 404, detail: "unscripted \(method) \(path)") }
        return try answer.get()
    }
}

@MainActor
private func connect(_ api: FakeDashboardAPI, gateway: ScriptedGateway = ScriptedGateway()) async throws -> GatewayConnection {
    let connection = try await gateway.withDefaults().connect(dashboard: api)
    try #require(await eventually { connection.listsRefreshTask == nil && !connection.listsRefreshQueued })
    return connection
}

@Suite struct CapabilityRowTests {
    @Test func skillsToolsetsAndServers() throws {
        let skill = try #require(Capability.skill(["name": "arxiv", "description": "Papers", "category": "research",
                                                   "enabled": false, "usage": 3, "provenance": "bundled"]))
        #expect(skill.tags == ["research", "bundled"])
        #expect(!skill.isEnabled)

        let toolset = try #require(Capability.toolset([
            "name": "web", "label": "Web Search", "description": "Search", "platform": "cli",
            "enabled": true, "available": true, "configured": false, "tools": ["web_search", "web_extract"],
        ]))
        #expect(toolset.title == "Web Search")
        #expect(toolset.tags == ["2 tools"])
        #expect(toolset.needsSetup)

        let stdio = try #require(Capability.mcpServer([
            "name": "files", "transport": "stdio", "url": nil, "command": "npx", "args": ["-y", "server-files"],
            "enabled": true, "source": "config", "plugin": nil,
        ]))
        #expect(stdio.detail == "npx -y server-files")
        #expect(stdio.lockedReason == nil)
        let fromPlugin = try #require(Capability.mcpServer(["name": "meshy", "url": "http://127.0.0.1:9", "transport": "http",
                                                           "enabled": true, "source": "plugin", "plugin": "meshy"]))
        #expect(fromPlugin.lockedReason == "Provided by the meshy plugin")
    }

    /// `isDesktopRelevantPlugin` (`apps/desktop/src/store/agent-plugins.ts:111-132`).
    @Test func pluginsTheUserManages() {
        func row(_ name: String, key: String?, source: String, status: String = "enabled") -> JSONValue {
            ["name": .string(name), "key": key.map(JSONValue.string) ?? .null, "version": "1.2", "description": "",
             "source": .string(source), "status": .string(status)]
        }
        #expect(Capability.plugin(row("kanban", key: "kanban", source: "user"))?.name == "kanban")
        #expect(Capability.plugin(row("kanban", key: "kanban", source: "user"))?.tags == ["user", "v1.2"])
        #expect(Capability.plugin(row("disk-cleanup", key: "disk-cleanup", source: "bundled", status: "not enabled"))?
            .isEnabled == false)
        #expect(Capability.plugin(row("fal", key: "image_gen/fal", source: "bundled")) == nil)
        #expect(Capability.plugin(row("telegram", key: "platforms/telegram", source: "git")) == nil)
        #expect(Capability.plugin(row("old", key: nil, source: "user"))?.lockedReason != nil,
                "a row without a key can't be addressed safely")
    }
}

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct CapabilitiesBoardTests {
    @Test func readsAndSwitchesOverRESTAndTheGateway() async throws {
        let api = FakeDashboardAPI([
            "GET /api/skills": [["name": "b-skill", "enabled": true], ["name": "a-skill", "enabled": false]],
            "PUT /api/skills/toggle": ["ok": true, "name": "a-skill", "enabled": true],
            "GET /api/mcp/servers": ["servers": [["name": "my files", "command": "npx", "enabled": true]]],
            "PUT /api/mcp/servers/my%20files/enabled": ["ok": true],
        ])
        let gateway = ScriptedGateway()
        gateway.on("plugins.manage") { params in
            params["action"] == "toggle"
                ? .result(["ok": true, "name": "kanban"])
                : .result(["plugins": [["name": "kanban", "key": "kanban", "source": "user", "status": "disabled"]]])
        }
        let connection = try await connect(api, gateway: gateway)

        await connection.refreshCapabilities(.skills, profile: "coder")
        let board = connection.capabilities
        #expect(board.lists[.skills]?.map(\.name) == ["a-skill", "b-skill"])
        try await connection.setCapability(try #require(board.lists[.skills]?.first), enabled: true)
        #expect(board.lists[.skills]?.first?.isEnabled == true)
        #expect(api.calls("PUT").last == .init(method: "PUT", path: "/api/skills/toggle", query: ["profile": "coder"],
                                               body: ["name": "a-skill", "enabled": true]))

        await connection.refreshCapabilities(.mcp, profile: "coder")
        try await connection.setCapability(try #require(board.lists[.mcp]?.first), enabled: false)
        #expect(api.calls("PUT").last?.path == "/api/mcp/servers/my%20files/enabled")
        #expect(board.lists[.mcp]?.first?.isEnabled == false)

        await connection.refreshCapabilities(.plugins, profile: "coder")
        try await connection.setCapability(try #require(board.lists[.plugins]?.first), enabled: true)
        #expect(gateway.params("plugins.manage").last == ["action": "toggle", "key": "kanban", "enable": true,
                                                           "profile": "coder"])
        #expect(board.lists[.plugins]?.first?.isEnabled == true)
    }

    @Test func aRefusalFlipsTheSwitchBack() async throws {
        let api = FakeDashboardAPI(["GET /api/tools/toolsets": [["name": "web", "enabled": true, "tools": []]]])
        api.on("PUT /api/tools/toolsets/web", .failure(CronRequestError(status: 400, detail: "Unknown toolset")))
        let connection = try await connect(api)
        await connection.refreshCapabilities(.toolsets, profile: "default")
        let row = try #require(connection.capabilities.lists[.toolsets]?.first)
        await #expect(throws: CronRequestError(status: 400, detail: "Unknown toolset")) {
            try await connection.setCapability(row, enabled: false)
        }
        #expect(connection.capabilities.lists[.toolsets]?.first?.isEnabled == true)
        #expect(connection.capabilities.saving.isEmpty)
    }

    @Test func anotherProfileStartsEmpty() async throws {
        let api = FakeDashboardAPI(["GET /api/skills": [["name": "x"]]])
        let connection = try await connect(api)
        await connection.refreshCapabilities(.skills, profile: "coder")
        #expect(connection.capabilities.lists[.skills]?.count == 1)
        api.on("GET /api/skills", .failure(CronRequestError(status: 500, detail: "boom")))
        await connection.refreshCapabilities(.skills, profile: "default")
        #expect(connection.capabilities.lists[.skills] == nil)
        #expect(connection.capabilities.errors[.skills] == "boom")
    }
}

/// `GET /api/env` rows (`hermes_cli/web_routers/config_env.py:266-325`).
private let envRows: JSONValue = [
    "ANTHROPIC_API_KEY": ["is_set": true, "redacted_value": "sk-…abcd", "description": "Anthropic API key",
                          "url": "https://console.anthropic.com", "category": "provider", "is_password": true,
                          "advanced": false, "provider": "anthropic", "provider_label": "Anthropic",
                          "provider_profiles": [], "provider_primary": true],
    "ANTHROPIC_TOKEN": ["is_set": false, "category": "provider", "is_password": true, "provider": "anthropic",
                        "provider_label": "Anthropic"],
    "ANTHROPIC_BASE_URL": ["is_set": false, "category": "provider", "is_password": false, "advanced": true,
                           "provider": "anthropic", "provider_label": "Anthropic"],
    "DASHSCOPE_API_KEY": ["is_set": false, "category": "provider", "is_password": true, "provider": "alibaba",
                          "provider_label": "Alibaba",
                          "provider_profiles": [
                            ["provider": "alibaba", "provider_label": "Alibaba", "description": "Qwen", "primary": true],
                            ["provider": "alibaba-coding", "provider_label": "Alibaba Coding Plan", "description": "Coding",
                             "primary": false],
                          ]],
    "MYSTERY_KEY": ["is_set": false, "category": "provider", "is_password": true],
    "GITHUB_TOKEN": ["is_set": true, "category": "tool", "is_password": true],
]

@Suite struct ProviderRowTests {
    /// `buildProviderKeyGroups` (`apps/desktop/src/app/settings/providers-settings.tsx:74-144`).
    @Test func keyGroups() throws {
        let groups = ProviderKeyGroup.groups(from: envRows)
        #expect(groups.map(\.name) == ["Anthropic", "Alibaba", "Alibaba Coding Plan"])
        let anthropic = groups[0]
        #expect(anthropic.primary.key == "ANTHROPIC_API_KEY")
        #expect(anthropic.others.map(\.key) == ["ANTHROPIC_BASE_URL"], "an unset alias key gets no second field")
        #expect(anthropic.hasAnySet)
        #expect(groups[2].primary.key == "DASHSCOPE_API_KEY")
        #expect(groups[2].description == "Coding")
    }

    @Test func accounts() throws {
        let row: JSONValue = [
            "id": "nous", "name": "Nous Portal", "flow": "device_code", "cli_command": "hermes auth add nous",
            "docs_url": "", "disconnect_hint": nil, "disconnect_command": nil, "disconnectable": true,
            "status": ["logged_in": true, "source": "nous_portal", "source_label": "Nous Portal",
                       "token_preview": "…9f2a", "expires_at": nil, "has_refresh_token": true, "free_tier": true],
        ]
        let account = try #require(ProviderAccount.from(row))
        #expect(account.signsInHere)
        #expect(account.isSignedIn && !account.isConnected, "the free tier isn't a connected account")
        #expect(account.docsURL == nil)
    }
}

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct ProvidersBoardTests {
    private func api() -> FakeDashboardAPI {
        FakeDashboardAPI([
            "GET /api/env": envRows,
            "GET /api/providers/oauth": ["providers": [
                ["id": "openai-codex", "name": "ChatGPT", "flow": "device_code", "disconnectable": true,
                 "status": ["logged_in": false]],
            ]],
            "GET /api/providers/custom-endpoints": [
                "endpoints": [["id": "lab", "name": "Lab", "base_url": "http://lab.example:8000/v1", "model": "qwen",
                               "models": ["qwen"], "has_api_key": false, "is_current": true]],
                "current": ["provider": "lab", "model": "qwen", "base_url": "http://lab.example:8000/v1"],
            ],
            "PUT /api/env": ["ok": true],
            "DELETE /api/env": ["ok": true, "found": true],
            "POST /api/providers/custom-endpoints/lab/activate": ["ok": true],
        ])
    }

    @Test func readsThePage() async throws {
        let api = api()
        let connection = try await connect(api)
        await connection.refreshProviders(profile: "coder")
        let board = connection.providers
        #expect(board.keyGroups.count == 3)
        #expect(board.accounts.map(\.id) == ["openai-codex"])
        #expect(board.endpoints.first?.isCurrent == true)
        #expect(board.currentModel == "qwen")
        #expect(Set(api.calls.map { $0.query["profile"] ?? "" }) == ["coder"])
    }

    @Test func keysAreSavedAndRemoved() async throws {
        let api = api()
        let connection = try await connect(api)
        await connection.refreshProviders(profile: "coder")
        try await connection.setProviderKey("ANTHROPIC_API_KEY", value: " sk-new \n")
        #expect(api.calls("PUT").last?.body == ["key": "ANTHROPIC_API_KEY", "value": "sk-new", "provider_setup": true])
        try await connection.removeProviderKey("ANTHROPIC_API_KEY")
        #expect(api.calls("DELETE").last?.body == ["key": "ANTHROPIC_API_KEY"])
        try await connection.activateCustomEndpoint(try #require(connection.providers.endpoints.first))
        #expect(api.calls.filter { $0.path == "/api/env" && $0.method == "GET" }.count == 4, "each write re-reads the page")
    }

    /// `start` gives the code; `poll?wait=` long-polls until the session leaves `pending`
    /// (`hermes_cli/web_routers/oauth.py:794-905`).
    @Test func deviceCodeSignIn() async throws {
        let api = api()
        api.on("POST /api/providers/oauth/openai-codex/start",
               .success(["session_id": "s1", "flow": "device_code", "user_code": "ABCD-1234",
                         "verification_url": "https://auth.example.com/device", "expires_in": 900, "poll_interval": 5]))
        api.on("GET /api/providers/oauth/openai-codex/poll/s1",
               .success(["session_id": "s1", "status": "pending"]),
               .success(["session_id": "s1", "status": "approved"]))
        let connection = try await connect(api)
        await connection.refreshProviders(profile: "coder")
        try await connection.startProviderSignIn(try #require(connection.providers.accounts.first))
        #expect(connection.providers.signIn?.userCode == "ABCD-1234")
        #expect(connection.providers.signIn?.verificationURL?.host == "auth.example.com")
        try #require(await eventually { connection.providers.signIn?.status == .approved })
        let polls = api.calls.filter { $0.path.hasSuffix("/poll/s1") }
        #expect(polls.count == 2)
        #expect(polls.first?.query == ["profile": "coder", "wait": "25"])
        connection.cancelProviderSignIn()
        #expect(connection.providers.signIn == nil)
    }
}
