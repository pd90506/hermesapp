#if os(iOS)
import HermesKit
import SwiftUI

/// Settings ▸ Connections: every server, with its status, and Add Server. A server
/// opens its own page (`ServerSettingsView`). Everything edits `AppModel` in place
/// (leaving a page never loses or reverts an edit; Connect saves). The macOS Settings
/// window has its own layout of the same settings (`ServersSettingsPane`).
struct ConnectionsSettingsView: View {
    @Binding var path: [SettingsPage]
    @Environment(AppModel.self) private var model

    var body: some View {
        ThemedForm {
            Section {
                ForEach(model.servers) { server in
                    NavigationLink(value: SettingsPage.server(server.id)) {
                        ServerRow(server: server)
                    }
                    .accessibilityIdentifier("serverRow")
                }
                Button("Add Server", systemImage: "plus") {
                    let server = model.addServer()
                    path.append(.server(server.id))
                }
            } header: {
                Text("Servers")
            } footer: {
                Text("The app stays connected to every server at once; the profile rail groups profiles by server.")
            }
        }
        .navigationTitle("Connections")
    }
}

/// A server in Connections: its name, address and status.
private struct ServerRow: View {
    let server: ServerConnection

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(server.hasURL ? server.name : "New Server")
                Text(detail)
                    .uiFont(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var statusColor: Color {
        let state = server.connection.state
        return state != .connected && server.lastError != nil ? .red : state.statusColor
    }

    private var detail: String {
        let state = server.connection.state
        let status = state == .connected ? state.statusText : server.lastError ?? state.statusText
        let address = server.config.serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        return address.isEmpty ? status : "\(status) · \(address)"
    }
}

/// Settings ▸ Connections ▸ a server: its address, sign-in and actions.
struct ServerSettingsView: View {
    let serverID: UUID
    @Binding var path: [SettingsPage]
    @Environment(AppModel.self) private var model

    var body: some View {
        if let server = model.server(serverID) {
            ThemedForm {
                ServerSettingsSection(server: server, removed: { path.removeLast() })
            }
            .navigationTitle(server.hasURL ? server.name : "New Server")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear { model.selectedServerID = server.id }
        } else {
            ContentUnavailableView("Server Removed", systemImage: "server.rack")
        }
    }
}

/// One server's address, sign-in and actions.
private struct ServerSettingsSection: View {
    @Bindable var server: ServerConnection
    /// Back to Connections, once the server is removed.
    let removed: () -> Void
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
                .textContentType(.URL)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
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
                    .textInputAutocapitalization(.never)
                TextField("Username", text: $server.config.username)
                    .textContentType(.username)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
            }
            if server.config.authMode == .browser {
                BrowserSignInButton(server: server)
            } else {
                SecureField(server.config.authMode.secretLabel, text: $server.secret)
                    .textContentType(.password)
            }
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
                    // Connected, it closes the whole sheet (`AppModel.connectFromSettings`).
                    await model.connectFromSettings(server)
                    isWorking = false
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
                    removed()
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
#endif
