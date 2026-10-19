import HermesKit
import SwiftUI
import UniformTypeIdentifiers

/// Every profile as an avatar, grouped by server when there are several: on macOS the
/// sidebar's leading strip, on iPad the left column. Picking one lists its sessions
/// beside it, so profiles never mix. Narrow on purpose; the session list is the wide column. Settings is at its
/// bottom, under the profiles. A profile's context menu changes its avatar, which is
/// stored on its server (`GatewayConnection+Avatars.swift`).
///
/// On iPhone (`.drawer`) the same profiles fill the drawer that slides over the session
/// list (`ProfileDrawer`), as Slack's workspaces: a row each, its avatar beside its name,
/// with a "…" menu for the avatar, and Settings at the bottom.
struct ProfileRailView: View {
    enum Style {
        case rail, drawer
    }

    @Environment(AppModel.self) private var model
    #if os(macOS)
    @Environment(\.openSettings) private var openSettings
    #endif
    var style = Style.rail
    /// Shows the session list (on iPhone, closes the drawer over it).
    var showSessions: () -> Void = {}

    /// The profile whose new avatar is being picked.
    @State private var avatarTarget: (server: ServerConnection, profile: String)?
    @State private var isPickingAvatar = false
    @State private var avatarError: String?

    var body: some View {
        Group {
            switch style {
            case .rail: rail
            case .drawer: drawer
            }
        }
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
        .refreshable { await model.refreshLists() }
    }

    private var rail: some View {
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
        // On the profiles' scroll view: on the whole rail it landed on the Settings button.
        .accessibilityIdentifier("profileRail")
        .safeAreaInset(edge: .bottom, spacing: 0) {
            settingsButton
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
        }
        #if os(macOS)
        // Beside the session list in the one sidebar (`RootView`), at one width.
        .frame(width: ProfileRailItem.width)
        #endif
    }

    private func openSettingsWindow() {
        #if os(macOS)
        // The Settings window, as the app menu's Settings… opens it.
        openSettings()
        #else
        model.settingsPresentation.toggle()
        #endif
    }

    /// On iPhone: a title, a row per profile (under its server's name, with several),
    /// and Settings under a line at the bottom.
    private var drawer: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                Text("Profiles")
                    .uiFont(.title, weight: .bold)
                    .accessibilityAddTraits(.isHeader)
                    .padding(.horizontal, drawerRowInset + 12)
                    .padding(.top, 24)
                    .padding(.bottom, 12)
                ForEach(model.sidebarServers) { server in
                    drawerSection(server)
                }
            }
            .padding(.bottom, 8)
        }
        .accessibilityIdentifier("profileRail")
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                Divider()
                Button(action: openSettingsWindow) {
                    Label("Settings", systemImage: "gearshape")
                        .uiFont(.body)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, drawerRowInset + 12)
                        .padding(.vertical, 14)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("settingsButton")
            }
        }
    }

    @ViewBuilder private func drawerSection(_ server: ServerConnection) -> some View {
        let connection = server.connection
        if model.showsServerNames {
            HStack(spacing: 6) {
                Circle()
                    .fill(statusColor(server))
                    .frame(width: 8, height: 8)
                Text(server.name)
                    .uiFont(.subheadline, weight: .semibold)
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(statusHelp(server))
            .padding(.horizontal, drawerRowInset + 12)
            .padding(.top, 12)
        }
        ForEach(connection.bots) { bot in
            DrawerProfileRow(bot: bot, activity: connection.activity(for: bot),
                             subtitle: drawerSubtitle(bot, on: server),
                             isSelected: isSelected(bot, on: server),
                             image: AvatarImages.image(connection.avatars[bot.name])) {
                model.selectProfile(bot.name, on: server)
                showSessions()
            } menu: {
                avatarMenu(bot, on: server)
            }
            .contextMenu { avatarMenu(bot, on: server) }
        }
        if connection.bots.isEmpty {
            Text(server.isConnected ? "No profiles" : status(server))
                .uiFont(.subheadline)
                .foregroundStyle(.secondary)
                .padding(.horizontal, drawerRowInset + 12)
                .padding(.vertical, 8)
        }
    }

    /// Under the name, as Slack's workspace address: the profile's own name, and its
    /// server while that isn't connected.
    private func drawerSubtitle(_ bot: Bot, on server: ServerConnection) -> String {
        server.connection.shownState == .connected ? bot.name : "\(bot.name) · \(status(server))"
    }

    @ViewBuilder private func avatarMenu(_ bot: Bot, on server: ServerConnection) -> some View {
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

    /// The gear under the profiles. On iOS the system's Liquid Glass circle, as the
    /// toolbar's buttons (user, 2026-10-18); on macOS a plain glyph with a hover circle.
    @ViewBuilder private var settingsButton: some View {
        #if os(macOS)
        Button("Settings", systemImage: "gearshape") {
            // The Settings window, as the app menu's Settings… opens it.
            openSettings()
        }
        .labelStyle(.iconOnly)
        .uiFont(.title3)
        .foregroundStyle(.secondary)
        .hoverButtonStyle(.circle, padding: 8)
        .help("Settings")
        #else
        Button("Settings", systemImage: "gearshape") {
            model.settingsPresentation.toggle()
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
        .controlSize(.large)
        .accessibilityIdentifier("settingsButton")
        #endif
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
            .contextMenu { avatarMenu(bot, on: server) }
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

    /// Quiet while a dropped connection gets back within a few seconds (`shownState`).
    private func statusColor(_ server: ServerConnection) -> Color {
        let state = server.connection.shownState
        return state != .connected && server.lastError != nil ? .red : state.statusColor
    }

    private func status(_ server: ServerConnection) -> String {
        let state = server.connection.shownState
        return state == .connected ? state.statusText : server.lastError ?? state.statusText
    }

    private func statusHelp(_ server: ServerConnection) -> String {
        "\(server.name): \(status(server))"
    }
}

/// A profile in the iPhone's drawer, as a workspace in Slack's: its avatar (a rounded
/// square, ringed when picked), its name over a grey line, and a "…" menu at the end.
/// The picked one sits on a grey fill.
/// A drawer row's fill, inset from the drawer's edges.
private let drawerRowInset: CGFloat = 8

private struct DrawerProfileRow<Actions: View>: View {
    let bot: Bot
    let activity: BotActivity
    let subtitle: String
    let isSelected: Bool
    var image: CGImage?
    let action: () -> Void
    @ViewBuilder var menu: Actions
    @Environment(\.surfaces) private var surfaces

    private static var avatarSize: CGFloat { 48 }

    var body: some View {
        HStack(spacing: 8) {
            Button(action: action) {
                HStack(spacing: 14) {
                    BotAvatar(name: bot.displayName, activity: activity, size: Self.avatarSize, image: image,
                              color: bot.avatarColor.map(Color.init(rgb:)), squared: true)
                        .padding(3)
                        .overlay {
                            RoundedRectangle(cornerRadius: Self.avatarSize * 0.3 + 3, style: .continuous)
                                .strokeBorder(.primary, lineWidth: 2.5)
                                .opacity(isSelected ? 1 : 0)
                        }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(bot.displayName)
                            .uiFont(.headline)
                            .lineLimit(1)
                        Text(subtitle)
                            .uiFont(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(bot.displayName)
            .accessibilityValue(subtitle)
            .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
            .accessibilityHint("Lists this profile's sessions")

            Menu {
                menu
            } label: {
                Image(systemName: "ellipsis")
                    .uiFont(.body, weight: .semibold)
                    .foregroundStyle(.primary)
                    .frame(width: 44, height: 44)
                    .contentShape(.rect)
            }
            // Black (white in dark mode), as Slack's, not the accent.
            .tint(.primary)
            .accessibilityLabel("Avatar options for \(bot.displayName)")
        }
        .padding(.leading, 12)
        .padding(.trailing, 4)
        .padding(.vertical, 8)
        .background {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(surfaces.selection)
                .opacity(isSelected ? 1 : 0)
        }
        .padding(.horizontal, drawerRowInset)
        .animation(.snappy(duration: 0.2), value: isSelected)
    }
}
