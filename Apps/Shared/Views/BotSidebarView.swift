import HermesKit
import HermesProtocol
import SwiftUI

/// What the sidebar can select.
enum SidebarItem: Hashable {
    /// A bot, by profile name. Selecting it opens its one Bot Chat.
    case bot(String)
    /// A Sessions row, by `HistoryEntry.id`.
    case history(String)
}

/// The bot roster and the profile-scoped session browser, under a page switcher.
///
/// The chrome is the same on both pages, so switching moves nothing but the rows:
/// - pinned at the top, the switcher (and on Sessions, New chat under it, so the list
///   starts one row lower there; see `SidebarHeader`);
/// - one toolbar button (Settings), beside the system sidebar toggle;
/// - at the bottom, the error and "waiting" banners and a fixed-height footer: the
///   connection status, plus the Sessions profile picker on the same line.
/// Rows and controls are in `SidebarControls.swift`; pointer feedback in `Hover.swift`.
struct BotSidebarView: View {
    @Environment(AppModel.self) private var model
    @Binding var selection: SidebarItem?
    /// Shows the chat a side chat was started for (on iPhone, pushes it).
    var showChat: () -> Void = {}
    /// One side chat at a time: repeated clicks while one is being created do nothing.
    @State private var isStartingChat = false

    var body: some View {
        @Bindable var model = model
        @Bindable var connection = model.connection
        List(selection: $selection) {
            if connection.navigationPage == .bots {
                Section("Bots") {
                    ForEach(model.connection.bots) { bot in
                        BotRow(bot: bot, activity: model.connection.activity(for: bot))
                            .sidebarRowHover(isSelected: selection == .bot(bot.name))
                            .tag(SidebarItem.bot(bot.name))
                            .contextMenu {
                                Button("New Side Chat", systemImage: "plus.bubble") { startSideChat(with: bot) }
                                    .disabled(!model.isConnected || isStartingChat)
                            }
                    }
                }
            } else {
                Section("Sessions") {
                    // Only before the first rows: background refreshes keep the list still.
                    if connection.sessionListLoading && connection.history.isEmpty {
                        ProgressView("Loading sessions…")
                    }
                    if let error = connection.sessionListError {
                        Text(error).foregroundStyle(.red)
                        Button("Retry") { Task { await connection.refreshSessionList() } }
                            .hoverButtonStyle(padding: 4)
                            .foregroundStyle(.tint)
                    }
                    if connection.bots.isEmpty {
                        Text(model.isConnected ? "No profiles available" : "Connect to browse sessions")
                            .foregroundStyle(.secondary)
                    } else if connection.history.isEmpty && !connection.sessionListLoading
                                && connection.sessionListError == nil {
                        Text("No sessions yet")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(connection.history) { entry in
                        HistoryRow(entry: entry, botName: displayName(of: entry.profile))
                            .sidebarRowHover(isSelected: selection == .history(entry.id))
                            .tag(SidebarItem.history(entry.id))
                    }
                }
            }
        }
        .navigationTitle(connection.navigationPage.title)
        #if os(iOS)
        // The switcher is the title; the navigation title stays for the back button.
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(removing: .title)
        #endif
        .refreshable { await model.refreshLists() }
        // Pinned above the list: it never scrolls away; rows scroll under it.
        .safeAreaBar(edge: .top) {
            SidebarHeader(page: $connection.navigationPage, newChat: newChatRow)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                banners
                SidebarFooter(status: statusText, color: statusColor) {
                    if connection.navigationPage == .sessions {
                        ProfilePicker(bots: connection.bots, selection: connection.listProfile) {
                            connection.selectListProfile($0)
                        }
                    }
                }
            }
            // The list scrolls under this inset; without a bar behind it, rows
            // showed through the status text.
            .background(.bar)
            .overlay(alignment: .top) { Divider() }
        }
        .toolbar {
            // The same single item on both pages, so the glass group never changes shape.
            SettingsToolbarItem(presentation: $model.settingsPresentation)
        }
        .task(id: "\(connection.navigationPage.rawValue):\(connection.listProfile ?? ""):\(model.isConnected)") {
            await connection.refreshSessionListIfVisible()
        }
        .task(id: model.isConnected) {
            // Keeps previews and activity dots current (Desktop re-reads the roster every 5 s).
            guard model.isConnected else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15))
                model.connection.refreshListsInBackground()
            }
        }
        #if os(macOS)
        .navigationSplitViewColumnWidth(min: 240, ideal: 280)
        #endif
    }

    /// Above the footer on both pages, so they never push the rows (or New chat) around.
    @ViewBuilder private var banners: some View {
        if let error = model.actionError {
            HStack(alignment: .top) {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                Spacer()
                Button("Dismiss", systemImage: "xmark") { model.actionError = nil }
                    .labelStyle(.iconOnly)
                    .hoverButtonStyle(.circle)
            }
            .padding(.horizontal)
            .padding(.vertical, 6)
        }
        if !model.connection.otherSessionRequests.isEmpty {
            Label("\(model.connection.otherSessionRequests.count) chat(s) waiting for you",
                  systemImage: "hand.raised.fill")
                .font(.callout)
                .foregroundStyle(.orange)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal)
                .padding(.vertical, 6)
        }
    }

    /// Sessions only: Bots has no New chat.
    private var newChatRow: NewChatRow? {
        let connection = model.connection
        guard connection.navigationPage == .sessions else { return nil }
        return NewChatRow(isEnabled: connection.canStartListChat && !isStartingChat,
                          disabledReason: newChatDisabledReason) {
            if let bot = connection.listProfileBot { startSideChat(with: bot) }
        }
    }

    private var newChatDisabledReason: String? {
        if !model.isConnected { return "Connect to your Hermes gateway first." }
        if model.connection.listProfileBot == nil { return "Pick a profile first." }
        if isStartingChat { return "A new chat is being created." }
        return nil
    }

    private var statusText: String {
        switch model.connection.state {
        case .disconnected: "Disconnected"
        case .connecting: "Connecting…"
        case .connected: "Connected"
        case .reconnecting(let attempt): "Reconnecting (attempt \(attempt))…"
        case .failed(let message): message
        }
    }

    private var statusColor: Color {
        switch model.connection.state {
        case .connected: .green
        case .connecting, .reconnecting: .yellow
        case .disconnected: .gray
        case .failed: .red
        }
    }

    private func displayName(of profile: String) -> String {
        model.connection.bots.first { $0.name == profile }?.displayName ?? profile
    }

    private func startSideChat(with bot: Bot) {
        guard !isStartingChat else { return }
        isStartingChat = true
        selection = nil
        Task {
            defer { isStartingChat = false }
            do {
                try await model.connection.newSideChat(profile: bot.name)
                showChat()
            } catch {
                model.actionError = GatewayConnection.describe(error)
            }
        }
    }
}
