import Foundation
import HermesProtocol
import Observation

/// One credential or setting in a profile's `.env`, from `GET /api/env?profile=`
/// (`hermes_cli/web_routers/config_env.py:259-325`). Values never come back, only whether
/// one is set and a redacted preview.
public struct ProviderEnvVar: Sendable, Hashable, Identifiable {
    public var key: String
    public var isSet: Bool
    public var redactedValue: String?
    public var description: String
    public var url: String?
    public var isPassword: Bool
    public var isAdvanced: Bool

    public var id: String { key }

    public init(key: String, isSet: Bool = false, redactedValue: String? = nil, description: String = "",
                url: String? = nil, isPassword: Bool = true, isAdvanced: Bool = false) {
        self.key = key
        self.isSet = isSet
        self.redactedValue = redactedValue
        self.description = description
        self.url = url
        self.isPassword = isPassword
        self.isAdvanced = isAdvanced
    }

    /// A key, rather than a URL or a region (`isKeyVar`, `apps/desktop/src/app/settings/credential-key-ui.tsx:28`).
    public var isKey: Bool {
        isPassword || key.hasSuffix("_API_KEY") || key.hasSuffix("_TOKEN") || key.hasSuffix("_KEY")
    }
}

/// A provider's card on the API Keys page: its main key, then its other settings (base
/// URL, region), as Desktop groups them (`buildProviderKeyGroups`, `providers-settings.tsx:74-144`).
public struct ProviderKeyGroup: Sendable, Hashable, Identifiable {
    public var name: String
    public var description: String
    public var docsURL: String?
    public var primary: ProviderEnvVar
    public var others: [ProviderEnvVar]

    public var id: String { name }

    public var hasAnySet: Bool { primary.isSet || others.contains(where: \.isSet) }

    /// The `provider` category rows of `GET /api/env`, by the catalog's provider label. A
    /// credential that serves several providers (`provider_profiles`) is on each one's
    /// card; rows with no provider label are left out, as Desktop's "Other" bucket is.
    /// Providers with a key set first, then by name.
    public static func groups(from env: JSONValue) -> [ProviderKeyGroup] {
        var buckets: [String: [(var: ProviderEnvVar, primary: Bool)]] = [:]
        var order: [String] = []
        for (key, info) in (env.objectValue ?? [:]).sorted(by: { $0.key < $1.key }) {
            guard info["category"]?.stringValue == "provider" else { continue }
            let base = ProviderEnvVar(key: key, isSet: info["is_set"]?.boolValue ?? false,
                                      redactedValue: info["redacted_value"]?.stringValue,
                                      description: info["description"]?.stringValue ?? "",
                                      url: info["url"]?.stringValue,
                                      isPassword: info["is_password"]?.boolValue ?? false,
                                      isAdvanced: info["advanced"]?.boolValue ?? false)
            var scoped: [(name: String, var: ProviderEnvVar, primary: Bool)] = []
            if let profiles = info["provider_profiles"]?.arrayValue, !profiles.isEmpty {
                for profile in profiles {
                    var row = base
                    if let text = profile["description"]?.stringValue, !text.isEmpty { row.description = text }
                    if let url = profile["url"]?.stringValue { row.url = url }
                    let name = Self.label(profile["provider_label"], profile["provider"])
                    scoped.append((name, row, profile["primary"]?.boolValue ?? false))
                }
            } else {
                scoped.append((Self.label(info["provider_label"], info["provider"]), base,
                               info["provider_primary"]?.boolValue ?? false))
            }
            for entry in scoped where !entry.name.isEmpty {
                if buckets[entry.name] == nil { order.append(entry.name) }
                buckets[entry.name, default: []].append((entry.var, entry.primary))
            }
        }
        var groups: [ProviderKeyGroup] = []
        for name in order {
            let entries = buckets[name] ?? []
            guard let primary = entries.first(where: { $0.primary && $0.var.isKey })?.var
                ?? entries.first(where: { !$0.var.isAdvanced && $0.var.isKey })?.var
                ?? entries.first(where: { $0.var.isKey })?.var
            else { continue }
            // Alias keys (ANTHROPIC_TOKEN beside ANTHROPIC_API_KEY) only show while set, so
            // they stay removable; no second "paste a key" field.
            let others = entries.map(\.var).filter { $0.key != primary.key && (!$0.isKey || $0.isSet) }
                .sorted { $0.key < $1.key }
            groups.append(ProviderKeyGroup(name: name, description: primary.description, docsURL: primary.url,
                                           primary: primary, others: others))
        }
        return groups.sorted { a, b in
            if a.hasAnySet != b.hasAnySet { return a.hasAnySet }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }

    private static func label(_ label: JSONValue?, _ provider: JSONValue?) -> String {
        let text = label?.stringValue?.trimmingCharacters(in: .whitespaces) ?? ""
        return text.isEmpty ? provider?.stringValue?.trimmingCharacters(in: .whitespaces) ?? "" : text
    }
}

/// A sign-in provider on the Accounts page, from `GET /api/providers/oauth?profile=`
/// (`hermes_cli/web_routers/oauth.py:671-690`).
public struct ProviderAccount: Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String
    /// `device_code` signs in from here; `external` is signed in with its own CLI.
    public var flow: String
    public var cliCommand: String?
    public var docsURL: String?
    public var isSignedIn: Bool
    /// Nous Portal's free tier counts as not connected (`providers-settings.tsx:185`).
    public var isFreeTier: Bool
    /// Where the credential is from (`Nous Portal`, `~/.codex/auth.json`).
    public var sourceLabel: String?
    public var tokenPreview: String?
    public var canDisconnect: Bool
    /// Why it can't be disconnected from here.
    public var disconnectHint: String?

    public init(id: String, name: String, flow: String = "device_code", cliCommand: String? = nil,
                docsURL: String? = nil, isSignedIn: Bool = false, isFreeTier: Bool = false, sourceLabel: String? = nil,
                tokenPreview: String? = nil, canDisconnect: Bool = true, disconnectHint: String? = nil) {
        self.id = id
        self.name = name
        self.flow = flow
        self.cliCommand = cliCommand
        self.docsURL = docsURL
        self.isSignedIn = isSignedIn
        self.isFreeTier = isFreeTier
        self.sourceLabel = sourceLabel
        self.tokenPreview = tokenPreview
        self.canDisconnect = canDisconnect
        self.disconnectHint = disconnectHint
    }

    public var isConnected: Bool { isSignedIn && !isFreeTier }
    public var signsInHere: Bool { flow == "device_code" }

    static func from(_ json: JSONValue) -> ProviderAccount? {
        guard let id = json["id"]?.stringValue, !id.isEmpty else { return nil }
        let status = json["status"]
        func text(_ value: JSONValue?) -> String? {
            value?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
        }
        return ProviderAccount(id: id, name: text(json["name"]) ?? id, flow: text(json["flow"]) ?? "external",
                               cliCommand: text(json["cli_command"]), docsURL: text(json["docs_url"]),
                               isSignedIn: status?["logged_in"]?.boolValue ?? false,
                               isFreeTier: status?["free_tier"]?.boolValue ?? false,
                               sourceLabel: text(status?["source_label"]), tokenPreview: text(status?["token_preview"]),
                               canDisconnect: json["disconnectable"]?.boolValue ?? false,
                               disconnectHint: text(json["disconnect_hint"]))
    }
}

/// A device-code sign-in in progress: the code to enter at the provider's page
/// (`POST /api/providers/oauth/{id}/start`, `oauth.py:144-155,794-844`).
public struct ProviderSignIn: Sendable, Hashable {
    public enum Status: Sendable, Hashable {
        case waiting, approved, failed(String)
    }

    public var provider: String
    public var providerName: String
    public var sessionID: String
    public var userCode: String
    public var verificationURL: URL?
    public var status: Status
}

/// An OpenAI-compatible endpoint the profile can use as a provider, from `GET
/// /api/providers/custom-endpoints?profile=` (`config_env.py:450-462,728-738`).
public struct CustomEndpoint: Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String
    public var baseURL: String
    public var model: String
    public var models: [String]
    public var hasAPIKey: Bool
    public var apiKeyPreview: String?
    /// The profile's default model runs on it.
    public var isCurrent: Bool

    public init(id: String, name: String, baseURL: String, model: String = "", models: [String] = [],
                hasAPIKey: Bool = false, apiKeyPreview: String? = nil, isCurrent: Bool = false) {
        self.id = id
        self.name = name
        self.baseURL = baseURL
        self.model = model
        self.models = models
        self.hasAPIKey = hasAPIKey
        self.apiKeyPreview = apiKeyPreview
        self.isCurrent = isCurrent
    }

    static func from(_ json: JSONValue) -> CustomEndpoint? {
        guard let id = json["id"]?.stringValue, let baseURL = json["base_url"]?.stringValue else { return nil }
        return CustomEndpoint(id: id, name: json["name"]?.stringValue ?? id, baseURL: baseURL,
                              model: json["model"]?.stringValue ?? "",
                              models: json["models"]?.arrayValue?.compactMap(\.stringValue) ?? [],
                              hasAPIKey: json["has_api_key"]?.boolValue ?? false,
                              apiKeyPreview: json["api_key_preview"]?.stringValue,
                              isCurrent: json["is_current"]?.boolValue ?? false)
    }
}

/// The New Endpoint form (`CustomEndpointUpdate`, `hermes_cli/web_models.py:46-58`).
public struct CustomEndpointDraft: Sendable, Hashable {
    public var name = ""
    public var baseURL = ""
    public var model = ""
    public var apiKey = ""
    public var makeDefault = false

    public init() {}

    public var canSave: Bool {
        ![name, baseURL, model].contains { $0.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    var body: JSONValue {
        var body: [String: JSONValue] = [
            "name": .string(name.trimmingCharacters(in: .whitespaces)),
            "base_url": .string(baseURL.trimmingCharacters(in: .whitespaces)),
            "model": .string(model.trimmingCharacters(in: .whitespaces)),
            "make_default": .bool(makeDefault),
        ]
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !key.isEmpty { body["api_key"] = .string(key) }
        return .object(body)
    }
}

/// What the Providers page shows for one profile.
@MainActor
@Observable
public final class ProvidersBoard {
    public internal(set) var profile: String?
    public internal(set) var keyGroups: [ProviderKeyGroup] = []
    public internal(set) var accounts: [ProviderAccount] = []
    public internal(set) var endpoints: [CustomEndpoint] = []
    /// The profile's default model and its provider (`custom-endpoints`' `current`).
    public internal(set) var currentModel: String?
    public internal(set) var currentProvider: String?
    public internal(set) var isLoading = false
    public internal(set) var hasLoaded = false
    public internal(set) var error: String?
    /// `false` when the connection has no REST access.
    public internal(set) var isAvailable = true
    /// The sign-in on show, until it's dismissed.
    public internal(set) var signIn: ProviderSignIn?
    /// Rows being saved: env keys, account ids, endpoint ids.
    public internal(set) var saving: Set<String> = []
    @ObservationIgnored var token = 0
    @ObservationIgnored var signInTask: Task<Void, Never>?

    public init() {}

    func reset(to profile: String?) {
        token += 1
        self.profile = profile
        keyGroups = []
        accounts = []
        endpoints = []
        currentModel = nil
        currentProvider = nil
        hasLoaded = false
        error = nil
        saving = []
    }
}

extension GatewayConnection {
    /// Reads `profile`'s keys, accounts and endpoints. Another profile's are dropped first.
    public func refreshProviders(profile: String) async {
        let board = providers
        if board.profile != profile { board.reset(to: profile) }
        guard let api = dashboardAPI else {
            board.isAvailable = false
            return
        }
        board.isAvailable = true
        board.token += 1
        let token = board.token
        board.isLoading = true
        defer { if token == board.token { board.isLoading = false } }
        async let env = api.get("/api/env", profile: profile)
        // Accounts and endpoints are best effort, as in Desktop: a failure hides the section.
        async let accounts = try? api.get("/api/providers/oauth", profile: profile)
        async let endpoints = try? api.get("/api/providers/custom-endpoints", profile: profile)
        do {
            let groups = ProviderKeyGroup.groups(from: try await env)
            let (accountRows, endpointRows) = await (accounts, endpoints)
            guard token == board.token, board.profile == profile else { return }
            board.keyGroups = groups
            if let accountRows { board.accounts = accountRows["providers"]?.arrayValue?.compactMap(ProviderAccount.from) ?? [] }
            if let endpointRows { applyEndpoints(endpointRows) }
            board.error = nil
            board.hasLoaded = true
        } catch {
            guard token == board.token, board.profile == profile else { return }
            board.error = Self.describe(error)
            board.hasLoaded = true
        }
    }

    /// Saves a key to the profile's `.env` (`PUT /api/env`, `config_env.py:328-339`), which
    /// also replaces any stale copy of it in `config.yaml`.
    public func setProviderKey(_ key: String, value: String) async throws {
        try await changeProviders(key) { api, profile in
            _ = try await api.put("/api/env", profile: profile, body: [
                "key": .string(key), "value": .string(value.trimmingCharacters(in: .whitespacesAndNewlines)),
                "provider_setup": true,
            ])
        }
    }

    /// Removes a key and every copy of it (`DELETE /api/env`, `config_env.py:1067-1082`).
    public func removeProviderKey(_ key: String) async throws {
        try await changeProviders(key) { api, profile in
            _ = try await api.delete("/api/env", profile: profile, body: ["key": .string(key)])
        }
    }

    /// Signs out of a provider (`DELETE /api/providers/oauth/{id}`, `oauth.py:727-777`).
    public func disconnectProvider(_ account: ProviderAccount) async throws {
        try await changeProviders(account.id) { api, profile in
            _ = try await api.delete("/api/providers/oauth/\(DashboardPath.segment(account.id))", profile: profile)
        }
    }

    /// Starts a device-code sign-in and waits for it in the background: `providers.signIn`
    /// shows the code to enter, and turns approved or failed (`oauth.py:794-905`). The
    /// session is the server's, so the code works from any browser.
    public func startProviderSignIn(_ account: ProviderAccount) async throws {
        let board = providers
        guard let profile = board.profile, let api = dashboardAPI else { throw GatewayClientError.notConnected }
        cancelProviderSignIn()
        board.saving.insert(account.id)
        defer { board.saving.remove(account.id) }
        let start = try await api.post("/api/providers/oauth/\(DashboardPath.segment(account.id))/start", profile: profile)
        guard let sessionID = start["session_id"]?.stringValue else {
            throw DashboardError.invalidResponse("no sign-in session")
        }
        let signIn = ProviderSignIn(provider: account.id, providerName: account.name, sessionID: sessionID,
                                    userCode: start["user_code"]?.stringValue ?? "",
                                    verificationURL: start["verification_url"]?.stringValue.flatMap(URL.init(string:)),
                                    status: .waiting)
        board.signIn = signIn
        board.signInTask = Task { [weak self] in
            await self?.waitForProviderSignIn(signIn, profile: profile, api: api)
        }
    }

    /// Stops waiting and drops the server's sign-in session.
    public func cancelProviderSignIn() {
        let board = providers
        board.signInTask?.cancel()
        board.signInTask = nil
        guard let signIn = board.signIn else { return }
        board.signIn = nil
        guard signIn.status == .waiting, let api = dashboardAPI, let profile = board.profile else { return }
        Task {
            _ = try? await api.delete("/api/providers/oauth/sessions/\(DashboardPath.segment(signIn.sessionID))",
                                      profile: profile)
        }
    }

    /// Long-polls until the session leaves `pending` (the route waits up to 25 s each time).
    private func waitForProviderSignIn(_ signIn: ProviderSignIn, profile: String, api: any DashboardAPI) async {
        let path = "/api/providers/oauth/\(DashboardPath.segment(signIn.provider))/poll/\(DashboardPath.segment(signIn.sessionID))"
        var failures = 0
        while !Task.isCancelled {
            let answer: JSONValue
            do {
                answer = try await api.get(path, profile: profile, query: [URLQueryItem(name: "wait", value: "25")],
                                           timeout: 40)
                failures = 0
            } catch {
                failures += 1
                if failures >= 3 || (error as? CronRequestError)?.status == 404 {
                    finishProviderSignIn(signIn, .failed(Self.describe(error)))
                    return
                }
                try? await Task.sleep(for: .seconds(2))
                continue
            }
            switch answer["status"]?.stringValue ?? "pending" {
            case "pending": continue
            case "approved":
                finishProviderSignIn(signIn, .approved)
                await refreshProviders(profile: profile)
                return
            default:
                finishProviderSignIn(signIn, .failed(answer["error_message"]?.stringValue ?? "The sign-in didn't finish."))
                return
            }
        }
    }

    private func finishProviderSignIn(_ signIn: ProviderSignIn, _ status: ProviderSignIn.Status) {
        guard providers.signIn?.sessionID == signIn.sessionID else { return }
        providers.signIn?.status = status
        providers.signInTask = nil
    }

    /// Adds an endpoint (`POST /api/providers/custom-endpoints`, `config_env.py:741-769`).
    public func addCustomEndpoint(_ draft: CustomEndpointDraft) async throws {
        try await changeProviders("endpoint:new") { api, profile in
            _ = try await api.post("/api/providers/custom-endpoints", profile: profile, body: draft.body)
        }
    }

    /// Makes an endpoint the profile's default provider (`config_env.py:772-821`).
    public func activateCustomEndpoint(_ endpoint: CustomEndpoint) async throws {
        try await changeProviders(endpoint.id) { api, profile in
            _ = try await api.post("/api/providers/custom-endpoints/\(DashboardPath.segment(endpoint.id))/activate",
                                   profile: profile)
        }
    }

    public func deleteCustomEndpoint(_ endpoint: CustomEndpoint) async throws {
        try await changeProviders(endpoint.id) { api, profile in
            _ = try await api.delete("/api/providers/custom-endpoints/\(DashboardPath.segment(endpoint.id))",
                                     profile: profile)
        }
    }

    private func applyEndpoints(_ answer: JSONValue) {
        providers.endpoints = answer["endpoints"]?.arrayValue?.compactMap(CustomEndpoint.from) ?? []
        providers.currentModel = answer["current"]?["model"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
        providers.currentProvider = answer["current"]?["provider"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
    }

    /// One write, then a fresh read of the page.
    private func changeProviders(_ id: String,
                                 _ write: (any DashboardAPI, String) async throws -> Void) async throws {
        let board = providers
        guard let profile = board.profile, let api = dashboardAPI else { throw GatewayClientError.notConnected }
        board.saving.insert(id)
        defer { board.saving.remove(id) }
        try await write(api, profile)
        await refreshProviders(profile: profile)
    }
}
