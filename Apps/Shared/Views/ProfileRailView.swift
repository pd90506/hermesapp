import HermesKit
import SwiftUI

/// The left column: every profile as an avatar, grouped by server when there are
/// several. Picking one lists its sessions in the middle column, so profiles never
/// mix. Narrow on purpose; the session list is the wide column.
struct ProfileRailView: View {
    @Environment(AppModel.self) private var model
    /// Shows the session list (on iPhone, pushes it).
    var showSessions: () -> Void = {}

    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                ForEach(Array(model.sidebarServers.enumerated()), id: \.element.id) { index, server in
                    if index > 0 {
                        Divider()
                            .frame(width: 32)
                    }
                    // One container per server: profile names repeat across servers
                    // ("default" on both), and a flat list keyed by name mixed them up.
                    VStack(spacing: 2) {
                        section(server)
                    }
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 8)
        }
        .scrollIndicators(.never)
        .navigationTitle("Profiles")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .refreshable { await model.refreshLists() }
        #if os(macOS)
        // Always shown: hiding the rail would hide the only way to switch profiles.
        .toolbar(removing: .sidebarToggle)
        .navigationSplitViewColumnWidth(min: ProfileRailItem.width, ideal: ProfileRailItem.width,
                                        max: ProfileRailItem.width + 20)
        #endif
    }

    @ViewBuilder private func section(_ server: ServerConnection) -> some View {
        let connection = server.connection
        if model.showsServerNames {
            RailServerHeader(name: server.name, color: statusColor(server))
                .help(statusHelp(server))
                .padding(.bottom, 2)
        }
        ForEach(connection.bots) { bot in
            ProfileRailItem(bot: bot, activity: connection.activity(for: bot),
                            isSelected: isSelected(bot, on: server)) {
                model.selectProfile(bot.name, on: server)
                showSessions()
            }
        }
        if connection.bots.isEmpty {
            Image(systemName: server.isConnected ? "person.crop.circle.badge.questionmark" : "bolt.horizontal.circle")
                .font(.title2)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .help(server.isConnected ? "No profiles" : "Not connected")
                .accessibilityLabel(server.isConnected ? "No profiles" : "Not connected")
        }
    }

    private func isSelected(_ bot: Bot, on server: ServerConnection) -> Bool {
        guard let selected = model.selectedProfile else { return false }
        return selected.server.id == server.id && selected.profile == bot.name
    }

    private func statusColor(_ server: ServerConnection) -> Color {
        let state = server.connection.state
        return state != .connected && server.lastError != nil ? .red : state.statusColor
    }

    private func statusHelp(_ server: ServerConnection) -> String {
        let state = server.connection.state
        let status = state == .connected ? state.statusText : server.lastError ?? state.statusText
        return "\(server.name): \(status)"
    }
}
