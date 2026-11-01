import HermesKit
import SwiftUI

/// Where a profile's models come from: accounts signed in with a device code, API keys,
/// and OpenAI-compatible endpoints. Desktop's Settings → Providers
/// (`apps/desktop/src/app/settings/providers-settings.tsx`, `custom-endpoints-settings.tsx`)
/// as one grouped form (asked for by the user, 2026-11-01).
struct ProvidersView: View {
    @Environment(AppModel.self) private var model
    @State private var scope = ProfileScope()
    /// Accounts, API keys or endpoints, as Desktop splits the page.
    @State private var page: Page = .accounts
    @State private var keyQuery = ""
    /// The key being typed in, and the value so far.
    @State private var editingKey: ProviderEnvVar?
    @State private var keyValue = ""
    @State private var removingKey: ProviderEnvVar?
    @State private var disconnecting: ProviderAccount?
    @State private var deletingEndpoint: CustomEndpoint?
    @State private var isAddingEndpoint = false
    @State private var openGroups: Set<String> = []
    /// The last change the server refused.
    @State private var actionError: String?

    private var server: ServerConnection? { model.servers.first { $0.id == scope.serverID } }

    private var board: ProvidersBoard? {
        guard let board = server?.connection.providers, board.profile == scope.profile else { return nil }
        return board
    }

    var body: some View {
        ThemedForm {
            Section {
                ProfileScopePicker(scope: $scope)
                if let model = board?.currentModel {
                    LabeledContent("Default model") {
                        Text(board?.currentProvider.map { "\(ModelLabel.displayName(model)) · \($0)" } ?? ModelLabel.displayName(model))
                    }
                }
            } footer: {
                if let error = actionError ?? board?.error {
                    Text(error).foregroundStyle(.red).accessibilityIdentifier("providers.error")
                }
            }
            if let board, board.hasLoaded {
                Section {
                    Picker("Show", selection: $page) {
                        ForEach(Page.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .accessibilityIdentifier("providers.page")
                }
                switch page {
                case .accounts: accounts(board)
                case .keys: keys(board)
                case .endpoints: endpoints(board)
                }
            } else if server?.isConnected != true {
                Section { Text("Connect to the server to set up its providers.").foregroundStyle(.secondary) }
            } else if board?.isAvailable == false {
                Section { Text("This connection can't read the profile's settings.").foregroundStyle(.secondary) }
            } else {
                Section { ProgressView().frame(maxWidth: .infinity) }
            }
        }
        #if os(iOS)
        .navigationTitle("Providers")
        .refreshable { await refresh() }
        #endif
        .onAppear { if scope.serverID == nil { scope = ProfileScopePicker.initial(model) } }
        .task(id: TaskKey(scope: scope, isConnected: server?.isConnected == true)) { await refresh() }
        .sheet(isPresented: Binding(get: { board?.signIn != nil }, set: { if !$0 { server?.connection.cancelProviderSignIn() } })) {
            if let signIn = board?.signIn { SignInSheet(signIn: signIn) { server?.connection.cancelProviderSignIn() } }
        }
        .sheet(isPresented: $isAddingEndpoint) {
            if let server { EndpointEditor(server: server) }
        }
        .alert(editingKey.map { "Set \($0.key)" } ?? "", isPresented: Binding(get: { editingKey != nil },
                                                                               set: { if !$0 { editingKey = nil } })) {
            if editingKey?.isKey == true {
                SecureField("Value", text: $keyValue)
            } else {
                TextField("Value", text: $keyValue)
            }
            Button("Cancel", role: .cancel) { editingKey = nil }
            Button("Save") { saveKey() }
                .disabled(keyValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        } message: {
            Text(editingKey?.description ?? "")
        }
        .confirmationDialog(removingKey.map { "Remove \($0.key)?" } ?? "",
                            isPresented: Binding(get: { removingKey != nil }, set: { if !$0 { removingKey = nil } }),
                            titleVisibility: .visible) {
            Button("Remove", role: .destructive) {
                if let key = removingKey { perform { try await $0.removeProviderKey(key.key) } }
                removingKey = nil
            }
        } message: {
            Text("The key is deleted from the profile's .env, with any copy of it in config.yaml.")
        }
        .confirmationDialog(disconnecting.map { "Disconnect \($0.name)?" } ?? "",
                            isPresented: Binding(get: { disconnecting != nil }, set: { if !$0 { disconnecting = nil } }),
                            titleVisibility: .visible) {
            Button("Disconnect", role: .destructive) {
                if let account = disconnecting { perform { try await $0.disconnectProvider(account) } }
                disconnecting = nil
            }
        } message: {
            Text("Hermes forgets this account's sign-in. Models from it stop working until you sign in again.")
        }
        .confirmationDialog(deletingEndpoint.map { "Delete “\($0.name)”?" } ?? "",
                            isPresented: Binding(get: { deletingEndpoint != nil }, set: { if !$0 { deletingEndpoint = nil } }),
                            titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                if let endpoint = deletingEndpoint { perform { try await $0.deleteCustomEndpoint(endpoint) } }
                deletingEndpoint = nil
            }
        }
    }

    // MARK: Accounts

    private func accounts(_ board: ProvidersBoard) -> some View {
        Section {
            ForEach(board.accounts) { account in
                LabeledContent {
                    accountAction(account, board)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(account.name)
                        Text(accountStatus(account))
                            .uiFont(.caption)
                            .foregroundStyle(account.isConnected ? AnyShapeStyle(.green) : AnyShapeStyle(.secondary))
                            .textSelection(.enabled)
                    }
                }
                .accessibilityIdentifier("providerAccount.\(account.id)")
            }
        } header: {
            Text("Accounts")
        } footer: {
            Text("Sign in with a subscription. The code is entered in any browser; Hermes keeps the sign-in.")
        }
    }

    @ViewBuilder private func accountAction(_ account: ProviderAccount, _ board: ProvidersBoard) -> some View {
        if board.saving.contains(account.id) {
            ProgressView().controlSize(.small)
        } else if account.isConnected {
            if account.canDisconnect {
                Button("Disconnect") { disconnecting = account }
            }
        } else if account.signsInHere {
            Button("Sign In") { perform { try await $0.startProviderSignIn(account) } }
                .accessibilityIdentifier("providerSignIn.\(account.id)")
        }
    }

    private func accountStatus(_ account: ProviderAccount) -> String {
        if account.isConnected {
            return ["Connected", account.sourceLabel, account.tokenPreview].compactMap { $0 }.joined(separator: " · ")
        }
        if account.isFreeTier { return "Free tier · sign in for your account" }
        if !account.signsInHere, let command = account.cliCommand { return "Sign in on the server: \(command)" }
        return "Not connected"
    }

    // MARK: API keys

    private func keys(_ board: ProvidersBoard) -> some View {
        Section {
            TextField("Search", text: $keyQuery, prompt: Text("Search providers"))
                .accessibilityIdentifier("providerKeys.search")
            ForEach(shownGroups(board)) { group in
                DisclosureGroup(isExpanded: Binding(get: { openGroups.contains(group.name) || !keyQuery.isEmpty },
                                                    set: { if $0 { openGroups.insert(group.name) } else { openGroups.remove(group.name) } })) {
                    if !group.description.isEmpty {
                        Text(group.description).uiFont(.caption).foregroundStyle(.secondary)
                    }
                    ForEach([group.primary] + group.others) { variable in
                        keyRow(variable, board)
                    }
                    if let docs = group.docsURL.flatMap(URL.init(string:)) {
                        Link("Get a key", destination: docs).uiFont(.caption)
                    }
                } label: {
                    HStack {
                        Text(group.name)
                        Spacer()
                        if group.hasAnySet {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                                .accessibilityLabel("Key set")
                        }
                    }
                }
                .accessibilityIdentifier("providerKeys.\(group.name)")
            }
        } header: {
            Text("API Keys")
        } footer: {
            Text("Keys are saved in the profile's .env on the server and never shown again.")
        }
    }

    private func shownGroups(_ board: ProvidersBoard) -> [ProviderKeyGroup] {
        let words = keyQuery.trimmingCharacters(in: .whitespaces)
        guard !words.isEmpty else { return board.keyGroups }
        return board.keyGroups.filter { group in
            ([group.name, group.description] + ([group.primary] + group.others).map(\.key))
                .contains { $0.localizedStandardContains(words) }
        }
    }

    private func keyRow(_ variable: ProviderEnvVar, _ board: ProvidersBoard) -> some View {
        LabeledContent {
            HStack(spacing: 8) {
                if board.saving.contains(variable.key) {
                    ProgressView().controlSize(.small)
                } else {
                    if variable.isSet {
                        Button("Remove", role: .destructive) { removingKey = variable }
                            .buttonStyle(.borderless)
                    }
                    Button(variable.isSet ? "Change…" : "Set…") {
                        keyValue = ""
                        editingKey = variable
                    }
                    .buttonStyle(.borderless)
                    .accessibilityIdentifier("providerKey.set.\(variable.key)")
                }
            }
        } label: {
            VStack(alignment: .leading, spacing: 1) {
                Text(variable.key).monospaced().uiFont(.callout)
                Text(variable.isSet ? (variable.redactedValue ?? "Set") : "Not set")
                    .uiFont(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func saveKey() {
        guard let variable = editingKey else { return }
        let value = keyValue
        editingKey = nil
        keyValue = ""
        perform { try await $0.setProviderKey(variable.key, value: value) }
    }

    // MARK: Custom endpoints

    private func endpoints(_ board: ProvidersBoard) -> some View {
        Section {
            ForEach(board.endpoints) { endpoint in
                LabeledContent {
                    if board.saving.contains(endpoint.id) {
                        ProgressView().controlSize(.small)
                    } else {
                        Menu {
                            Button("Make Default", systemImage: "checkmark.circle") {
                                perform { try await $0.activateCustomEndpoint(endpoint) }
                            }
                            .disabled(endpoint.isCurrent)
                            Button("Delete…", systemImage: "trash", role: .destructive) { deletingEndpoint = endpoint }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                        .menuStyle(.button)
                        .buttonStyle(.borderless)
                        .menuIndicator(.hidden)
                        .fixedSize()
                        .accessibilityLabel("More actions")
                    }
                } label: {
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 6) {
                            Text(endpoint.name)
                            if endpoint.isCurrent {
                                Text("Default")
                                    .uiFont(.caption2, weight: .semibold)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 1)
                                    .background(.tint.opacity(0.15), in: .capsule)
                                    .foregroundStyle(.tint)
                            }
                        }
                        Text([endpoint.baseURL, endpoint.model].filter { !$0.isEmpty }.joined(separator: " · "))
                            .uiFont(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .textSelection(.enabled)
                    }
                }
                .accessibilityIdentifier("customEndpoint.\(endpoint.id)")
            }
            Button("Add Endpoint…", systemImage: "plus") { isAddingEndpoint = true }
                .accessibilityIdentifier("customEndpoint.add")
        } header: {
            Text("Custom Endpoints")
        } footer: {
            Text("Any OpenAI-compatible server, such as a local model or a gateway.")
        }
    }

    // MARK: Plumbing

    private func perform(_ action: @escaping @MainActor (GatewayConnection) async throws -> Void) {
        guard let server else { return }
        Task {
            do {
                try await action(server.connection)
                actionError = nil
            } catch {
                actionError = model.describe(error, on: server)
            }
        }
    }

    private func refresh() async {
        guard let server, server.isConnected, let profile = scope.profile else { return }
        await server.connection.refreshProviders(profile: profile)
    }

    private struct TaskKey: Equatable {
        var scope: ProfileScope
        var isConnected: Bool
    }

    enum Page: String, CaseIterable, Identifiable {
        case accounts, keys, endpoints

        var id: String { rawValue }

        var title: String {
            switch self {
            case .accounts: "Accounts"
            case .keys: "API Keys"
            case .endpoints: "Endpoints"
            }
        }
    }
}

/// The device code to enter at the provider's page, while Hermes waits for the sign-in.
private struct SignInSheet: View {
    let signIn: ProviderSignIn
    let close: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Text("Sign in to \(signIn.providerName)").uiFont(.title2, weight: .semibold)
            switch signIn.status {
            case .waiting:
                Text("Open the sign-in page and enter this code:")
                    .foregroundStyle(.secondary)
                Text(signIn.userCode)
                    .uiFont(.largeTitle, weight: .semibold, design: .monospaced)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("providerSignIn.code")
                HStack {
                    if let url = signIn.verificationURL {
                        Link(destination: url) { Label("Open Sign-In Page", systemImage: "safari") }
                            .buttonStyle(.borderedProminent)
                    }
                    Button("Copy Code", systemImage: "doc.on.doc") { Clipboard.copy(signIn.userCode) }
                        .buttonStyle(.bordered)
                }
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Waiting for you to approve…").foregroundStyle(.secondary)
                }
                .uiFont(.callout)
                Button("Cancel", action: close)
            case .approved:
                Label("Signed in", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .uiFont(.title3)
                Button("Done", action: close).buttonStyle(.borderedProminent)
            case .failed(let reason):
                Label(reason, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                Button("Done", action: close).buttonStyle(.borderedProminent)
            }
        }
        .padding(28)
        .frame(minWidth: 360)
        .presentationDetents([.medium])
    }
}

/// Add Endpoint: a name, its OpenAI-compatible base URL, a model, and its key if it needs one.
private struct EndpointEditor: View {
    let server: ServerConnection
    @Environment(\.dismiss) private var dismiss
    @State private var draft = CustomEndpointDraft()
    @State private var isSaving = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            ThemedForm {
                Section {
                    TextField("Name", text: $draft.name, prompt: Text("Local server"))
                    TextField("Base URL", text: $draft.baseURL, prompt: Text("http://127.0.0.1:8000/v1"))
                        .accessibilityIdentifier("endpointEditor.baseURL")
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                        #endif
                    TextField("Model", text: $draft.model, prompt: Text("qwen3-coder"))
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif
                    SecureField("API Key", text: $draft.apiKey, prompt: Text("Optional"))
                    Toggle("Make it the default", isOn: $draft.makeDefault)
                } footer: {
                    if let error { Text(error).foregroundStyle(.red) }
                }
            }
            .navigationTitle("Add Endpoint")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(isSaving) }
                ToolbarItem(placement: .confirmationAction) {
                    if isSaving {
                        ProgressView().controlSize(.small)
                    } else {
                        Button("Add", action: save).disabled(!draft.canSave)
                    }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 460, minHeight: 340)
        #endif
    }

    private func save() {
        isSaving = true
        error = nil
        Task {
            defer { isSaving = false }
            do {
                try await server.connection.addCustomEndpoint(draft)
                dismiss()
            } catch {
                self.error = GatewayConnection.describe(error)
            }
        }
    }
}
