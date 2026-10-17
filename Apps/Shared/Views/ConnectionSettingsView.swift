import HermesKit
import SwiftUI

/// The servers, and the URL and credentials of the one picked, edited in place in
/// `AppModel` (closing it never loses or reverts an edit; Connect saves). A sheet from
/// the gear or on launch (`SettingsPresentation`), and iOS. The macOS Settings window has
/// its own layout of the same settings (`MacSettingsView`).
struct ConnectionSettingsView: View {
    /// Shown as a sheet from the gear or on launch.
    var isSheet = false
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    #if os(iOS)
    private let isIOS = true
    #else
    private let isIOS = false
    #endif

    var body: some View {
        @Bindable var model = model

        Form {
            Section {
                if model.servers.count > 1 {
                    Picker("Server", selection: $model.selectedServerID) {
                        ForEach(model.servers) { server in
                            Text(server.name).tag(Optional(server.id))
                        }
                    }
                }
                Button("Add Server", systemImage: "plus") {
                    model.addServer()
                }
                #if os(macOS)
                Toggle("Run Hermes on this Mac", isOn: Binding(
                    get: { model.localServer != nil },
                    set: { isOn in Task { await model.setRunsLocalBackend(isOn) } }))
                #endif
            } header: {
                Text("Servers")
            } footer: {
                Text("The app stays connected to every server at once; the profile rail groups profiles by server.")
            }

            if let server = model.selectedServer {
                if server.isLocal {
                    LocalServerSection(server: server)
                        .id(server.id)
                } else {
                    ServerSettingsSection(server: server, dismiss: { dismiss() })
                        .id(server.id)
                }
            }

            // The macOS Settings window has its own tab for these.
            if isSheet || isIOS {
                Section {
                    NavigationLink("Session Sources") {
                        SessionSourcesSettingsView()
                    }
                    NavigationLink("Appearance") {
                        AppearanceSettingsView()
                    }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Connection")
        .onAppear {
            // Nothing to edit yet: start with a blank server.
            if model.servers.isEmpty { model.addServer() }
            if model.selectedServer == nil { model.selectedServerID = model.servers.first?.id }
        }
        .toolbar {
            #if os(iOS)
            ToolbarItem(placement: .cancellationAction) {
                Button("Close") { dismiss() }
            }
            #else
            if isSheet {
                ToolbarItem(placement: .confirmationAction) {
                    // Esc closes it too (`.cancelAction`), as before.
                    Button("Done") { dismiss() }
                        .keyboardShortcut(.cancelAction)
                }
            }
            #endif
        }
        #if os(macOS)
        .background {
            if isSheet {
                // A sheet blocks the window's File ▸ Close, so Command-W gets its own key here.
                Button("Close") { dismiss() }
                    .keyboardShortcut("w", modifiers: .command)
                    .opacity(0)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        #endif
    }
}

/// One server's address, sign-in and actions.
private struct ServerSettingsSection: View {
    @Bindable var server: ServerConnection
    let dismiss: () -> Void
    @Environment(AppModel.self) private var model
    @State private var isWorking = false
    @State private var confirmsRemoval = false

    var body: some View {
        Section {
            TextField("Name", text: $server.config.name, prompt: Text(namePrompt))
                .autocorrectionDisabled()
            TextField("Server URL", text: $server.config.serverURL,
                      prompt: Text("https://hermes.example.ts.net"))
                .autocorrectionDisabled()
                #if os(iOS)
                .textContentType(.URL)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                #endif
            Button("Check Server") {
                Task { await model.probe(server) }
            }
            .disabled(!server.hasURL)
            if let probe = server.probeResult {
                Text(probe).uiFont(.footnote).foregroundStyle(.secondary)
            }
        } header: {
            Text("Hermes Dashboard")
        } footer: {
            Text("The address of the Hermes dashboard (the same one the desktop app uses), e.g. a Tailscale HTTPS name.")
        }

        Section("Sign-in") {
            Picker("Method", selection: $server.config.authMode) {
                ForEach(AuthMode.allCases) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            if server.config.authMode == .password {
                TextField("Provider", text: $server.config.provider)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif
                TextField("Username", text: $server.config.username)
                    .textContentType(.username)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif
            }
            SecureField(server.config.authMode.secretLabel, text: $server.secret)
                .textContentType(.password)
            if let help = server.config.authMode.help {
                Text(help).uiFont(.footnote).foregroundStyle(.secondary)
            }
        }

        if let error = server.lastError {
            Section {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
            }
        }

        Section {
            Button {
                Task {
                    isWorking = true
                    await model.connectFromSettings(server)
                    isWorking = false
                    if server.isConnected, server.lastError == nil { dismiss() }
                }
            } label: {
                HStack {
                    Text(server.isConnected ? "Reconnect" : "Connect")
                    if isWorking {
                        Spacer()
                        ProgressView().controlSize(.small)
                    }
                }
            }
            .disabled(!server.hasURL || isWorking)

            if server.isConnected {
                Button("Disconnect") {
                    Task { await model.disconnect(server) }
                }
            }
            Button("Remove Server", role: .destructive) {
                confirmsRemoval = true
            }
            .confirmationDialog("Remove \(server.name)?", isPresented: $confirmsRemoval) {
                Button("Remove", role: .destructive) {
                    Task { await model.removeServer(server) }
                }
            } message: {
                Text("The app disconnects from it and forgets its sign-in. Chats stay on the server.")
            }
        }
    }

    private var namePrompt: String {
        ServerConfig(serverURL: server.config.serverURL).displayName
    }
}

/// "This Mac": the backend the app runs itself. Nothing to fill in.
private struct LocalServerSection: View {
    let server: ServerConnection
    @Environment(AppModel.self) private var model
    @State private var isWorking = false

    var body: some View {
        Section {
            LabeledContent("Status", value: server.connection.state.statusText)
            if server.isConnected {
                LabeledContent("Address", value: server.config.serverURL)
                    .textSelection(.enabled)
            }
        } header: {
            Text("This Mac")
        } footer: {
            Text("The app runs `hermes serve` on this Mac, as Hermes Desktop does: on a free port, with a new token each time. It stops when you quit the app.")
        }

        if let error = server.lastError {
            Section {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }
        }

        Section {
            Button {
                Task {
                    isWorking = true
                    if server.isConnected { await model.disconnect(server) }
                    await model.connect(server)
                    isWorking = false
                }
            } label: {
                HStack {
                    Text(server.isConnected ? "Restart Hermes" : "Start Hermes")
                    if isWorking || server.isConnecting {
                        Spacer()
                        ProgressView().controlSize(.small)
                    }
                }
            }
            .disabled(isWorking || server.isConnecting)
            if server.isConnected {
                Button("Stop Hermes") {
                    Task { await model.disconnect(server) }
                }
            }
        }
    }
}
