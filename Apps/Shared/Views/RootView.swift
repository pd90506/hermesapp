import HermesKit
import HermesProtocol
import SwiftUI

/// Sidebar (bots + History) + detail (chat). Used by both apps; on iPhone the
/// split view collapses into a navigation stack automatically.
struct RootView: View {
    @Environment(AppModel.self) private var model
    @State private var selection: SidebarItem?

    var body: some View {
        @Bindable var model = model

        NavigationSplitView {
            BotSidebarView(selection: $selection)
        } detail: {
            if let session = model.connection.activeSession {
                ChatView(session: session, title: title(of: session))
                    .id(session.id)  // a fresh composer per chat
            } else {
                ContentUnavailableView(
                    "No Chat Selected", systemImage: "bubble.left.and.bubble.right",
                    description: Text(model.isConnected ? "Pick a bot to chat with." : "Connect to your Hermes gateway."))
            }
        }
        .sheet(isPresented: $model.isShowingSettings) {
            NavigationStack {
                ConnectionSettingsView(isSheet: true)
            }
            #if os(macOS)
            .frame(minWidth: 460, minHeight: 420)
            #endif
        }
        .onChange(of: selection) { _, newValue in
            guard let newValue else { return }
            Task { await open(newValue) }
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
                if !model.isConnected { model.isShowingSettings = true }
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
