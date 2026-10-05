import HermesKit
import HermesProtocol
import SwiftUI

/// Placeholder chat: transcript, pending approval/clarify cards, composer.
struct ChatView: View {
    let session: ChatSession
    @State private var draft = ""
    @State private var error: String?

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                ForEach(session.transcript.items) { item in
                    MessageRow(item: item)
                }
                ForEach(session.transcript.pendingRequests) { request in
                    RequestCardView(session: session, request: request)
                }
                if let status = session.transcript.status, session.transcript.isRunning {
                    Label(status, systemImage: "ellipsis")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let lastError = session.transcript.lastError ?? error {
                    Label(lastError, systemImage: "exclamationmark.triangle")
                        .font(.callout)
                        .foregroundStyle(.red)
                }
            }
            .padding()
        }
        .defaultScrollAnchor(.bottom)
        .safeAreaInset(edge: .bottom) {
            composer
        }
        .navigationTitle(session.title ?? "New Chat")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Message Hermes", text: $draft, axis: .vertical)
                .lineLimit(1...8)
                .textFieldStyle(.roundedBorder)
                .onSubmit(send)
            if session.transcript.isRunning {
                Button("Stop", systemImage: "stop.circle.fill") {
                    Task {
                        do { try await session.interrupt() } catch { self.error = GatewayConnection.describe(error) }
                    }
                }
                .labelStyle(.iconOnly)
                .font(.title2)
            } else {
                Button("Send", systemImage: "arrow.up.circle.fill", action: send)
                    .labelStyle(.iconOnly)
                    .font(.title2)
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .keyboardShortcut(.return, modifiers: .command)
            }
        }
        .padding()
        .background(.bar)
    }

    private func send() {
        let text = draft
        draft = ""
        error = nil
        Task {
            do { try await session.send(text) } catch { self.error = GatewayConnection.describe(error) }
        }
    }
}

private struct MessageRow: View {
    let item: TranscriptItem

    var body: some View {
        switch item.role {
        case .user:
            HStack {
                Spacer(minLength: 40)
                Text(item.text)
                    .textSelection(.enabled)
                    .padding(10)
                    .background(.tint.opacity(0.15), in: .rect(cornerRadius: 12))
            }
        case .assistant:
            VStack(alignment: .leading, spacing: 6) {
                if !item.reasoning.isEmpty {
                    DisclosureGroup("Reasoning") {
                        Text(item.reasoning)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    .font(.caption)
                }
                // Markdown rendering is a follow-up; plain text keeps streaming cheap.
                Text(item.text.isEmpty && item.isActive ? "…" : item.text)
                    .textSelection(.enabled)
                if item.outcome == "interrupted" {
                    Text("Interrupted").font(.caption).foregroundStyle(.secondary)
                }
            }
        case .tool:
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.toolName ?? "tool").font(.callout.monospaced())
                    if let detail = item.detail {
                        Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                    }
                }
            } icon: {
                if item.isActive {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "wrench.and.screwdriver")
                }
            }
            .padding(8)
            .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 8))
        case .system:
            Text(item.text)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
