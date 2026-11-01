import HermesKit
import SwiftUI

/// Which profile, on which server, a profile settings page (Capabilities, Providers)
/// reads and writes. It starts on the profile the session list shows, as Desktop's
/// settings follow the active profile (`apps/desktop/src/app/capabilities/scope-selector.tsx`).
struct ProfileScope: Equatable {
    var serverID: UUID?
    var profile: String?
}

/// Pickers for a `ProfileScope`: the server when there are several, then its profile.
struct ProfileScopePicker: View {
    @Environment(AppModel.self) private var model
    @Binding var scope: ProfileScope

    var body: some View {
        let servers = model.sidebarServers
        if servers.count > 1 {
            Picker("Server", selection: Binding(get: { scope.serverID }, set: { id in
                scope = ProfileScope(serverID: id, profile: Self.defaultProfile(model.servers.first { $0.id == id }))
            })) {
                ForEach(servers, id: \.id) { Text($0.config.displayName).tag(Optional($0.id)) }
            }
            .accessibilityIdentifier("profileScope.server")
        }
        let bots = server?.connection.bots ?? []
        Picker("Profile", selection: $scope.profile) {
            ForEach(bots, id: \.name) { Text($0.displayName).tag(Optional($0.name)) }
            if let profile = scope.profile, !bots.contains(where: { $0.name == profile }) {
                Text(profile).tag(Optional(profile))
            }
        }
        .disabled(bots.isEmpty)
        .accessibilityIdentifier("profileScope.profile")
    }

    private var server: ServerConnection? { model.servers.first { $0.id == scope.serverID } }

    static func defaultProfile(_ server: ServerConnection?) -> String? {
        server?.connection.listProfile ?? server?.connection.bots.first?.name
    }

    /// The session list's server and profile.
    static func initial(_ model: AppModel) -> ProfileScope {
        let server = model.sessionsServer ?? model.sidebarServers.first
        return ProfileScope(serverID: server?.id, profile: defaultProfile(server))
    }
}

/// The installed skills, toolsets, MCP servers and plugins of a profile, each with its
/// switch: Desktop's Capabilities page without its catalogs and marketplace (asked for by
/// the user, 2026-11-01). A tab per kind, a search field, and rows a switch each.
struct CapabilitiesView: View {
    @Environment(AppModel.self) private var model
    @State private var scope = ProfileScope()
    @State private var kind: CapabilityKind = .skills
    @State private var query = ""
    /// The last switch the server refused.
    @State private var actionError: String?

    private var server: ServerConnection? { model.servers.first { $0.id == scope.serverID } }

    var body: some View {
        content
            .onAppear { if scope.serverID == nil { scope = ProfileScopePicker.initial(model) } }
            .task(id: TaskKey(scope: scope, kind: kind, isConnected: server?.isConnected == true)) { await refresh() }
    }

    @ViewBuilder private var content: some View {
        #if os(macOS)
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 16) {
                ProfileScopePicker(scope: $scope)
                    .fixedSize()
                Spacer()
                TextField("Search", text: $query, prompt: Text("Search \(kind.title.lowercased())"))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 220)
                    .accessibilityIdentifier("capabilities.search")
            }
            kindPicker
            List { rows }
                .listStyle(.inset)
                .alternatingRowBackgrounds()
                .overlay { placeholder }
                .frame(height: 440)
            footnote
        }
        #else
        List {
            Section {
                ProfileScopePicker(scope: $scope)
                kindPicker
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
            }
            Section {
                rows
            } footer: {
                footnote
            }
        }
        .overlay { placeholder }
        .searchable(text: $query, prompt: "Search \(kind.title.lowercased())")
        .refreshable { await refresh() }
        .themedPage()
        .navigationTitle("Capabilities")
        #endif
    }

    private var kindPicker: some View {
        Picker("Kind", selection: $kind) {
            ForEach(CapabilityKind.allCases) { kind in
                Text(kind.title).tag(kind)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .accessibilityIdentifier("capabilities.kind")
    }

    private var board: CapabilitiesBoard? {
        guard let board = server?.connection.capabilities, board.profile == scope.profile else { return nil }
        return board
    }

    private var shown: [Capability] {
        let rows = board?.lists[kind] ?? []
        let words = query.trimmingCharacters(in: .whitespaces)
        guard !words.isEmpty else { return rows }
        return rows.filter { row in
            ([row.title, row.name, row.detail] + row.tags).contains { $0.localizedStandardContains(words) }
        }
    }

    @ViewBuilder private var rows: some View {
        ForEach(shown) { row in
            CapabilityRow(row: row, isSaving: board?.saving.contains(row.id) == true) { on in
                guard let server else { return }
                Task {
                    do {
                        try await server.connection.setCapability(row, enabled: on)
                        actionError = nil
                    } catch {
                        actionError = model.describe(error, on: server)
                    }
                }
            }
        }
    }

    /// Loading, an error, or an empty list, over the rows.
    @ViewBuilder private var placeholder: some View {
        if server?.isConnected != true {
            ContentUnavailableView("Not Connected", systemImage: "bolt.horizontal",
                                   description: Text("Connect to the server to see its capabilities."))
        } else if board?.isAvailable == false {
            ContentUnavailableView("Not Available", systemImage: "puzzlepiece.extension",
                                   description: Text("This connection can't read the profile's settings."))
        } else if let error = board?.errors[kind], board?.lists[kind] == nil {
            ContentUnavailableView {
                Label("Couldn't Load \(kind.title)", systemImage: "exclamationmark.triangle")
            } description: {
                Text(error)
            } actions: {
                Button("Try Again") { Task { await refresh() } }
            }
        } else if board?.lists[kind] == nil {
            ProgressView()
        } else if shown.isEmpty {
            if query.isEmpty {
                ContentUnavailableView("No \(kind.title)", systemImage: "puzzlepiece.extension",
                                       description: Text("None are installed in this profile."))
            } else {
                ContentUnavailableView.search(text: query)
            }
        }
    }

    private var footnote: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let actionError {
                Text(actionError).foregroundStyle(.red).accessibilityIdentifier("capabilities.error")
            }
            footnoteText
        }
        .uiFont(.caption)
    }

    private var footnoteText: some View {
        Text(kind == .plugins
             ? "Plugins are installed with Hermes. Switching one loads or unloads it for this profile."
             : "Changes apply to chats started after them.")
            .foregroundStyle(.secondary)
    }

    private func refresh() async {
        guard let server, server.isConnected, let profile = scope.profile else { return }
        await server.connection.refreshCapabilities(kind, profile: profile)
    }

    private struct TaskKey: Equatable {
        var scope: ProfileScope
        var kind: CapabilityKind
        var isConnected: Bool
    }
}

/// A capability: its name and what it does, its tags under them, its switch at the end.
private struct CapabilityRow: View {
    let row: Capability
    let isSaving: Bool
    let set: (Bool) -> Void

    var body: some View {
        Toggle(isOn: Binding(get: { row.isEnabled }, set: set)) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(row.title)
                        .lineLimit(1)
                    if isSaving { ProgressView().controlSize(.mini) }
                }
                if !row.detail.isEmpty {
                    Text(row.detail)
                        .uiFont(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                if let note {
                    Text(note)
                        .uiFont(.caption2)
                        .foregroundStyle(row.needsSetup ? AnyShapeStyle(.orange) : AnyShapeStyle(.tertiary))
                        .lineLimit(1)
                }
            }
        }
        .disabled(row.lockedReason != nil || isSaving)
        .padding(.vertical, 2)
        .accessibilityIdentifier("capability.\(row.kind.rawValue).\(row.name)")
    }

    private var note: String? {
        let parts = (row.needsSetup ? ["Needs keys or setup in Hermes"] : []) + row.tags + [row.lockedReason].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}
