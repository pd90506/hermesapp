#if os(iOS)
import HermesKit
import SwiftUI

/// The settings sheet on iOS, laid out like the system's Settings: a page with
/// Connections, Session Sources and Appearance, each opening its own page. The macOS
/// Settings window has the same three as tabs (`MacSettingsView`).
///
/// Opened by the app because it must connect (`SettingsPresentation.isRequired`), it
/// starts on the server to fix, one Back from the rest.
struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var path: [SettingsPage] = []

    var body: some View {
        NavigationStack(path: $path) {
            ThemedForm {
                Section {
                    NavigationLink(value: SettingsPage.connections) {
                        LabeledContent {
                            Text(connectionSummary)
                        } label: {
                            Label("Connections", systemImage: "server.rack")
                        }
                    }
                    .accessibilityIdentifier("settings.connections")
                    NavigationLink(value: SettingsPage.sessionSources) {
                        Label("Session Sources", systemImage: "tray.2")
                    }
                    .accessibilityIdentifier("settings.sessionSources")
                    NavigationLink(value: SettingsPage.appearance) {
                        Label("Appearance", systemImage: "paintpalette")
                    }
                    .accessibilityIdentifier("settings.appearance")
                }
            }
            .navigationTitle("Settings")
            .navigationDestination(for: SettingsPage.self) { page in
                switch page {
                case .connections: ConnectionsSettingsView(path: $path)
                case .server(let id): ServerSettingsView(serverID: id, path: $path)
                case .sessionSources: SessionSourcesSettingsView()
                case .appearance: AppearanceSettingsView()
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    // The system's glass xmark, as the system's own sheets close.
                    Button(role: .close) { dismiss() }
                }
            }
        }
        .onAppear(perform: openServerToFix)
    }

    /// One server: its status. Several: how many are connected.
    private var connectionSummary: String {
        let servers = model.sidebarServers
        guard servers.count > 1 else { return servers.first?.connection.state.statusText ?? "No server" }
        return "\(servers.filter(\.isConnected).count) of \(servers.count) connected"
    }

    /// When the app can't work without a connection: straight to the server that needs
    /// fixing (a new blank one if there is none yet).
    private func openServerToFix() {
        guard model.settingsPresentation.isRequired, path.isEmpty else { return }
        if model.servers.isEmpty { model.addServer() }
        let server = model.servers.first { !$0.isConnected && $0.lastError != nil }
            ?? model.servers.first { !$0.isConnected } ?? model.servers.first
        guard let server else { return }
        model.selectedServerID = server.id
        path = [.connections, .server(server.id)]
    }
}

/// The pages of the settings sheet.
enum SettingsPage: Hashable {
    case connections
    case server(UUID)
    case sessionSources
    case appearance
}
#endif
