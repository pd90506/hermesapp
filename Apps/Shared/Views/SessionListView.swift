import HermesKit
import HermesProtocol
import SwiftUI

struct SessionListView: View {
    @Environment(AppModel.self) private var model
    @Binding var selection: SessionSummary.ID?

    var body: some View {
        List(selection: $selection) {
            if !model.connection.otherSessionRequests.isEmpty {
                Section {
                    Label("\(model.connection.otherSessionRequests.count) session(s) waiting for you",
                          systemImage: "hand.raised.fill")
                        .foregroundStyle(.orange)
                }
            }
            Section("Sessions") {
                ForEach(model.connection.sessions) { session in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(session.title?.isEmpty == false ? session.title! : "Untitled")
                            .lineLimit(1)
                        if let preview = session.preview, !preview.isEmpty {
                            Text(preview)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                    }
                    .tag(session.id)
                }
            }
        }
        .navigationTitle("Hermes")
        .refreshable { try? await model.connection.refreshSessions() }
        .safeAreaInset(edge: .bottom) {
            ConnectionStatusBar()
        }
        .toolbar {
            ToolbarItem {
                Button("New Chat", systemImage: "square.and.pencil") {
                    Task {
                        do {
                            selection = nil
                            try await model.connection.newSession()
                        } catch {
                            model.lastError = GatewayConnection.describe(error)
                        }
                    }
                }
                .disabled(!model.isConnected)
            }
            ToolbarItem {
                Button("Connection", systemImage: "gearshape") {
                    model.isShowingSettings = true
                }
            }
        }
        #if os(macOS)
        .navigationSplitViewColumnWidth(min: 220, ideal: 260)
        #endif
    }
}

private struct ConnectionStatusBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer()
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    private var text: String {
        switch model.connection.state {
        case .disconnected: "Disconnected"
        case .connecting: "Connecting…"
        case .connected: "Connected"
        case .reconnecting(let attempt): "Reconnecting (attempt \(attempt))…"
        case .failed(let message): message
        }
    }

    private var color: Color {
        switch model.connection.state {
        case .connected: .green
        case .connecting, .reconnecting: .yellow
        case .disconnected: .gray
        case .failed: .red
        }
    }
}
