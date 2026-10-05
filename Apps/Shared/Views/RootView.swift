import HermesKit
import HermesProtocol
import SwiftUI

/// Sidebar (sessions) + detail (chat). Used by both apps; on iPhone the
/// split view collapses into a navigation stack automatically.
struct RootView: View {
    @Environment(AppModel.self) private var model
    @State private var selection: SessionSummary.ID?

    var body: some View {
        @Bindable var model = model

        NavigationSplitView {
            SessionListView(selection: $selection)
        } detail: {
            if let session = model.connection.activeSession {
                ChatView(session: session)
            } else {
                ContentUnavailableView(
                    "No Chat Selected", systemImage: "bubble.left.and.bubble.right",
                    description: Text(model.isConnected ? "Pick a session or start a new one." : "Connect to your Hermes gateway."))
            }
        }
        .sheet(isPresented: $model.isShowingSettings) {
            NavigationStack {
                ConnectionSettingsView()
            }
            #if os(macOS)
            .frame(minWidth: 460, minHeight: 420)
            #endif
        }
        .onChange(of: selection) { _, newValue in
            guard let id = newValue, let summary = model.connection.sessions.first(where: { $0.id == id }) else { return }
            guard model.connection.activeSession?.storedSessionID != id else { return }
            Task {
                do {
                    try await model.connection.open(summary)
                } catch {
                    model.lastError = GatewayConnection.describe(error)
                }
            }
        }
        .task {
            // Auto-connect on launch when settings exist.
            if !model.settings.serverURL.isEmpty, model.connection.state == .disconnected {
                await model.connect()
                if !model.isConnected { model.isShowingSettings = true }
            }
        }
    }
}
