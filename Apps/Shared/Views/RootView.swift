import HermesKit
import HermesProtocol
import SwiftUI

/// Sidebar (Bots / Sessions) + detail (chat). Used by both apps; on iPhone the
/// split view collapses into a navigation stack automatically.
struct RootView: View {
    @Environment(AppModel.self) private var model
    @State private var selection: SidebarItem?
    /// The column shown when the split view is collapsed (iPhone). A new side chat
    /// has no row to select until the list catches up, so it is shown through this.
    @State private var compactColumn = NavigationSplitViewColumn.sidebar

    var body: some View {
        NavigationSplitView(preferredCompactColumn: $compactColumn) {
            BotSidebarView(
                selection: Binding(
                    get: { selection },
                    set: { item in
                        selection = item
                        if let item { Task { await open(item) } }
                    }),
                showChat: { compactColumn = .detail })
        } detail: {
            if let opening = model.connection.opening {
                // A first open: the chat's frame at once, not the previous chat.
                OpeningChatView(title: title(of: opening))
            } else if let session = model.connection.activeSession {
                ChatView(session: session, title: title(of: session))
                    .id(session.id)  // a fresh composer per chat
            } else {
                ContentUnavailableView(
                    "No Chat Selected", systemImage: "bubble.left.and.bubble.right",
                    description: Text(model.isConnected ? "Pick a bot or session to chat with." : "Connect to your Hermes gateway."))
            }
        }
        // The settings sheet, from the gear or because the app must connect
        // (`SettingsPresentation`).
        .sheet(isPresented: Binding(
            get: { model.settingsPresentation.isShown },
            set: { if !$0 { model.settingsPresentation.close() } })) {
            NavigationStack {
                ConnectionSettingsView(isSheet: true)
            }
            #if os(macOS)
            // Opened from the gear, a click elsewhere in the window closes it as Done
            // would; the must-connect sheet ignores such clicks.
            .onParentWindowClick(isEnabled: model.settingsPresentation.isTransient) {
                model.settingsPresentation.clickedOutside()
            }
            .frame(minWidth: 460, minHeight: 420)
            #endif
        }
        .onChange(of: model.connection.activeSession?.id) { _, _ in
            // The chat on screen can change without a click: dropped on reconnect,
            // cleared on a server switch, or a new side chat. Follow it, so the
            // highlighted row is always the one on screen and clicking a row always opens it.
            let shown = item(for: model.connection.activeSession)
            if selection != shown { selection = shown }
        }
        .task {
            // Auto-connect on launch when settings exist.
            if !model.settings.serverURL.isEmpty, model.connection.state == .disconnected {
                await model.connect()
                if !model.isConnected { model.settingsPresentation.requireConnection() }
            }
        }
    }

    /// The sidebar row for a chat, if it has one.
    private func item(for session: ChatSession?) -> SidebarItem? {
        guard let session, let profile = session.profile else { return nil }
        switch session.kind {
        case .botChat: return .bot(profile)
        case .sideChat:
            return model.connection.history
                .first { $0.profile == profile && $0.summary.id == session.storedSessionID }
                .map { .history($0.id) }
        case .session: return nil
        }
    }

    private func open(_ item: SidebarItem) async {
        do {
            switch item {
            case .bot(let profile):
                // Resolved by name on every click; HermesKit never creates a second Bot Chat.
                try await model.connection.openBotChat(profile: profile)
            case .history(let id):
                guard let entry = model.connection.history.first(where: { $0.id == id }) else { return }
                try await model.connection.open(entry)
            }
            model.actionError = nil
        } catch is CancellationError {
            // Opened on a socket that was since replaced: let a click on the same row retry.
            if selection == item { selection = nil }
        } catch {
            model.actionError = GatewayConnection.describe(error)
            // Clear the selection so clicking the same row again retries.
            if selection == item { selection = nil }
        }
    }

    private func title(of opening: PendingChat) -> String {
        let botName = model.connection.bots.first { $0.name == opening.profile }?.displayName ?? opening.profile
        switch opening.kind {
        case .botChat: return botName ?? "Hermes"
        case .sideChat:
            let title = opening.title?.isEmpty == false ? opening.title! : "Side chat"
            return botName.map { "\(title) · \($0)" } ?? title
        case .session: return opening.title?.isEmpty == false ? opening.title! : "Chat"
        }
    }

    private func title(of session: ChatSession) -> String? {
        let botName = model.connection.bots.first { $0.name == session.profile }?.displayName ?? session.profile
        switch session.kind {
        case .botChat: return botName
        case .sideChat:
            let title = session.title?.isEmpty == false ? session.title! : "Side chat"
            return botName.map { "\(title) · \($0)" } ?? title
        case .session: return nil
        }
    }
}

/// The frame of a chat being opened: its title and a spinner where the transcript goes.
private struct OpeningChatView: View {
    let title: String

    var body: some View {
        ProgressView()
            .controlSize(.small)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle(title)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .accessibilityLabel("Opening \(title)")
    }
}
