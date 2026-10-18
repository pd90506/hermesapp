import HermesKit
import SwiftUI
import UniformTypeIdentifiers

/// Every profile as an avatar, grouped by server when there are several: on macOS the
/// sidebar's leading strip, on iOS the left column. Picking one lists its sessions
/// beside it, so profiles never mix. Narrow on purpose; the session list is the wide column. Settings is at its
/// bottom, under the profiles. A profile's context menu changes its avatar, which is
/// stored on its server (`GatewayConnection+Avatars.swift`).
struct ProfileRailView: View {
    @Environment(AppModel.self) private var model
    #if os(macOS)
    @Environment(\.openSettings) private var openSettings
    #endif
    /// Shows the session list (on iPhone, slides it back over the rail).
    var showSessions: () -> Void = {}

    /// The profile whose new avatar is being picked.
    @State private var avatarTarget: (server: ServerConnection, profile: String)?
    @State private var isPickingAvatar = false
    @State private var avatarError: String?

    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                ForEach(Array(model.sidebarServers.enumerated()), id: \.element.id) { index, server in
                    if index > 0 {
                        Divider()
                            .frame(width: 28)
                    }
                    // One container per server: profile names repeat across servers
                    // ("default" on both), and a flat list keyed by name mixed them up.
                    VStack(spacing: 2) {
                        section(server)
                    }
                }
            }
            .padding(.vertical, 8)
        }
        .scrollIndicators(.never)
        .accessibilityIdentifier("profileRail")
        .fileImporter(isPresented: $isPickingAvatar, allowedContentTypes: [.image]) { result in
            guard let target = avatarTarget else { return }
            avatarTarget = nil
            switch result {
            case .success(let url): Task { await upload(url, for: target.profile, on: target.server) }
            case .failure(let error): avatarError = error.localizedDescription
            }
        }
        .alert("Couldn't change the avatar", isPresented: Binding(get: { avatarError != nil },
                                                                  set: { if !$0 { avatarError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(avatarError ?? "")
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            Button("Settings", systemImage: "gearshape") {
                #if os(macOS)
                // The Settings window, as the app menu's Settings… opens it.
                openSettings()
                #else
                model.settingsPresentation.toggle()
                #endif
            }
            .labelStyle(.iconOnly)
            .uiFont(.title3)
            .foregroundStyle(.secondary)
            .hoverButtonStyle(.circle, padding: 8)
            .help("Settings")
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
        }
        #if os(macOS)
        // Beside the session list in the one sidebar (`RootView`), at one width.
        .frame(width: ProfileRailItem.width)
        #endif
        .refreshable { await model.refreshLists() }
    }

    @ViewBuilder private func section(_ server: ServerConnection) -> some View {
        let connection = server.connection
        if model.showsServerNames {
            RailServerHeader(name: server.name, color: statusColor(server), isLocal: server.isLocal,
                             status: status(server))
                .help(statusHelp(server))
                .padding(.bottom, 2)
        }
        ForEach(connection.bots) { bot in
            ProfileRailItem(bot: bot, activity: connection.activity(for: bot),
                            isSelected: isSelected(bot, on: server),
                            image: AvatarImages.image(connection.avatars[bot.name])) {
                model.selectProfile(bot.name, on: server)
                showSessions()
            }
            .contextMenu {
                Button("Change Avatar…", systemImage: "photo") {
                    avatarTarget = (server, bot.name)
                    isPickingAvatar = true
                }
                if bot.hasAvatar {
                    Button("Remove Avatar", systemImage: "trash", role: .destructive) {
                        Task { await removeAvatar(of: bot.name, on: server) }
                    }
                }
            }
        }
        if connection.bots.isEmpty {
            Image(systemName: server.isConnected ? "person.crop.circle.badge.questionmark" : "bolt.horizontal.circle")
                .uiFont(.title2)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .help(server.isConnected ? "No profiles" : "Not connected")
                .accessibilityLabel(server.isConnected ? "No profiles" : "Not connected")
        }
    }

    private func upload(_ url: URL, for profile: String, on server: ServerConnection) async {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url), let png = AvatarImages.uploadPNG(from: data) else {
            avatarError = "That file isn't an image this app can read."
            return
        }
        do {
            try await server.connection.setAvatar(png, for: profile)
        } catch {
            avatarError = error.localizedDescription
        }
    }

    private func removeAvatar(of profile: String, on server: ServerConnection) async {
        do {
            try await server.connection.removeAvatar(for: profile)
        } catch {
            avatarError = error.localizedDescription
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

    private func status(_ server: ServerConnection) -> String {
        let state = server.connection.state
        return state == .connected ? state.statusText : server.lastError ?? state.statusText
    }

    private func statusHelp(_ server: ServerConnection) -> String {
        "\(server.name): \(status(server))"
    }
}
