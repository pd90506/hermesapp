import HermesKit
import SwiftUI

/// The Servers tab, laid out like Mail's Accounts: the servers in a list on the left with
/// add and remove buttons under it, and the one picked on the right, its details in tabs.
/// The same settings as `ConnectionSettingsView` (the sheet and iOS), edited in place in
/// `AppModel`.
struct ServersSettingsPane: View {
    @Environment(AppModel.self) private var model
    @State private var confirmsRemoval = false

    var body: some View {
        @Bindable var model = model

        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 10) {
                List(selection: $model.selectedServerID) {
                    ForEach(model.servers) { server in
                        ServerListRow(server: server).tag(server.id)
                    }
                }
                .listStyle(.bordered)
                .alternatingRowBackgrounds(.disabled)

                ControlGroup {
                    Button("Add Server", systemImage: "plus") {
                        model.addServer()
                    }
                    Button("Remove Server", systemImage: "minus") {
                        confirmsRemoval = true
                    }
                    .disabled(model.selectedServer == nil)
                }
                .labelStyle(.iconOnly)
                .fixedSize()

                Toggle("Run Hermes on this Mac", isOn: Binding(
                    get: { model.localServer != nil },
                    set: { isOn in Task { await model.setRunsLocalBackend(isOn) } }))
            }
            .frame(width: 210)

            Group {
                if let server = model.selectedServer {
                    if server.isLocal {
                        LocalServerDetail(server: server)
                    } else {
                        ServerDetail(server: server)
                    }
                } else {
                    Text("No Server Selected")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .id(model.selectedServerID)
        }
        .padding(20)
        .frame(width: 760, height: 480)
        .confirmationDialog(removalTitle, isPresented: $confirmsRemoval) {
            if let server = model.selectedServer {
                Button(server.isLocal ? "Stop and Remove" : "Remove", role: .destructive) {
                    Task {
                        if server.isLocal {
                            await model.setRunsLocalBackend(false)
                        } else {
                            await model.removeServer(server)
                        }
                    }
                }
            }
        } message: {
            if model.selectedServer?.isLocal == true {
                Text("The app stops the Hermes it runs on this Mac. Chats stay in Hermes.")
            } else {
                Text("The app disconnects from it and forgets its sign-in. Chats stay on the server.")
            }
        }
        .onAppear {
            // Nothing to edit yet: start with a blank server.
            if model.servers.isEmpty { model.addServer() }
            if model.selectedServer == nil { model.selectedServerID = model.servers.first?.id }
        }
    }

    private var removalTitle: String {
        "Remove \(model.selectedServer?.name ?? "Server")?"
    }
}

/// A server in the list: an icon, its name, and what it is.
private struct ServerListRow: View {
    let server: ServerConnection

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: server.isLocal ? "desktopcomputer" : "globe")
                .uiFont(.title2)
                .foregroundStyle(.tint)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text(server.name)
                    .lineLimit(1)
                Text(server.isLocal ? "Local" : "Hermes Dashboard")
                    .uiFont(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 4)
    }
}

/// "Connected" with a colored dot, as Mail shows an account's status.
private struct ServerStatus: View {
    let server: ServerConnection

    var body: some View {
        LabeledContent("Status:") {
            HStack(spacing: 6) {
                Text(server.connection.state.statusText)
                    .lineLimit(2)
                Circle()
                    .fill(server.connection.state.statusColor)
                    .frame(width: 9, height: 9)
                    .accessibilityHidden(true)
            }
        }
    }
}

/// The error of the last connect, and the connect buttons, under a server's details.
private struct ServerActionBar<Actions: View>: View {
    let server: ServerConnection
    @ViewBuilder let actions: Actions

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            if let error = server.lastError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .lineLimit(3)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Spacer()
            }
            actions
        }
    }
}

/// A server the app connects to: its address on one tab, its sign-in on another.
private struct ServerDetail: View {
    @Bindable var server: ServerConnection
    @Environment(AppModel.self) private var model
    @State private var isWorking = false

    var body: some View {
        VStack(spacing: 12) {
            TabView {
                information
                    .tabItem { Text("Server Information") }
                signIn
                    .tabItem { Text("Sign-in") }
            }

            ServerActionBar(server: server) {
                if server.isConnected {
                    Button("Disconnect") {
                        Task { await model.disconnect(server) }
                    }
                }
                Button {
                    Task {
                        isWorking = true
                        await model.connect(server)
                        isWorking = false
                    }
                } label: {
                    HStack(spacing: 6) {
                        if isWorking { ProgressView().controlSize(.small) }
                        Text(server.isConnected ? "Reconnect" : "Connect")
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!server.hasURL || isWorking)
            }
        }
    }

    private var information: some View {
        Form {
            ServerStatus(server: server)
            TextField("Name:", text: $server.config.name, prompt: Text(namePrompt))
                .autocorrectionDisabled()
            TextField("Server URL:", text: $server.config.serverURL,
                      prompt: Text("https://hermes.example.ts.net"))
                .autocorrectionDisabled()
            LabeledContent {
                VStack(alignment: .leading, spacing: 6) {
                    SettingsNote("The address of the Hermes dashboard (the same one the desktop app uses), e.g. a Tailscale HTTPS name.")
                    HStack(alignment: .firstTextBaseline) {
                        Button("Check Server") {
                            Task { await model.probe(server) }
                        }
                        .disabled(!server.hasURL)
                        if let probe = server.probeResult {
                            Text(probe)
                                .uiFont(.callout)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                    }
                }
            } label: {
                EmptyView()
            }
        }
        .formStyle(.columns)
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var signIn: some View {
        Form {
            Picker("Method:", selection: $server.config.authMode) {
                ForEach(AuthMode.allCases) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            if server.config.authMode == .password {
                TextField("Provider:", text: $server.config.provider)
                    .autocorrectionDisabled()
                TextField("Username:", text: $server.config.username)
                    .textContentType(.username)
                    .autocorrectionDisabled()
            }
            SecureField("\(server.config.authMode.secretLabel):", text: $server.secret)
                .textContentType(.password)
            if let help = server.config.authMode.help {
                LabeledContent {
                    SettingsNote(LocalizedStringKey(help))
                } label: {
                    EmptyView()
                }
            }
        }
        .formStyle(.columns)
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var namePrompt: String {
        ServerConfig(serverURL: server.config.serverURL).displayName
    }
}

/// "This Mac": the backend the app runs itself. Nothing to fill in.
private struct LocalServerDetail: View {
    let server: ServerConnection
    @Environment(AppModel.self) private var model
    @State private var isWorking = false

    var body: some View {
        VStack(spacing: 12) {
            TabView {
                Form {
                    ServerStatus(server: server)
                    if server.isConnected {
                        LabeledContent("Address:", value: server.config.serverURL)
                            .textSelection(.enabled)
                    }
                    LabeledContent {
                        SettingsNote("The app runs `hermes serve` on this Mac, as Hermes Desktop does: on a free port, with a new token each time. It stops when you quit the app.")
                    } label: {
                        EmptyView()
                    }
                }
                .formStyle(.columns)
                .padding(20)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .tabItem { Text("This Mac") }
            }

            ServerActionBar(server: server) {
                if server.isConnected {
                    Button("Stop Hermes") {
                        Task { await model.disconnect(server) }
                    }
                }
                Button {
                    Task {
                        isWorking = true
                        if server.isConnected { await model.disconnect(server) }
                        await model.connect(server)
                        isWorking = false
                    }
                } label: {
                    HStack(spacing: 6) {
                        if isWorking || server.isConnecting { ProgressView().controlSize(.small) }
                        Text(server.isConnected ? "Restart Hermes" : "Start Hermes")
                    }
                }
                .disabled(isWorking || server.isConnecting)
            }
        }
    }
}
