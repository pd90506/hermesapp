import HermesKit
import HermesProtocol
import SwiftUI

/// Placeholder chat: transcript, pending approval/clarify cards, composer.
struct ChatView: View {
    let session: ChatSession
    /// Overrides the session title (a Bot Chat is titled "Bot Chat"; show the bot instead).
    var title: String?
    @Environment(AppModel.self) private var model

    /// The chat's own composer: it outlives this view (`GatewayConnection.composer(for:)`).
    private var composer: ChatComposer { model.connection.composer(for: session) }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                HistoryHeader(session: session)
                ForEach(session.transcript.items) { item in
                    MessageRow(item: item, profile: session.profile, session: session)
                }
                ForEach(session.transcript.pendingRequests) { request in
                    RequestCardView(session: session, request: request)
                }
                if let status = session.transcript.status, session.transcript.isRunning {
                    Label(status, systemImage: "ellipsis")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let lastError = session.transcript.lastError {
                    Label(lastError, systemImage: "exclamationmark.triangle")
                        .font(.callout)
                        .foregroundStyle(.red)
                }
            }
            .padding()
        }
        // Bottom-anchored for size changes too: an older page prepended above
        // keeps the rows on screen where they are.
        .defaultScrollAnchor(.bottom)
        .safeAreaInset(edge: .bottom) {
            ComposerView(composer: composer, isConnected: model.isConnected)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(.bar)
        }
        .navigationTitle(title ?? session.title ?? "New Chat")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}

/// Top of the transcript: loads the next older page while it is on screen,
/// offers a retry when a page failed, and marks the beginning of the chat.
private struct HistoryHeader: View {
    let session: ChatSession
    @State private var isVisible = false

    /// Re-runs the load when a page lands and the header is still on screen.
    private struct Trigger: Equatable {
        var isVisible: Bool
        var offset: Int
    }

    var body: some View {
        HStack {
            Spacer()
            content
            Spacer()
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .onScrollVisibilityChange(threshold: 0.2) { isVisible = $0 }
        .task(id: Trigger(isVisible: isVisible, offset: session.transcript.nextOlderOffset)) {
            guard isVisible else { return }
            // A page that just landed pushes this header off screen; wait for the
            // layout so opening a chat does not read a second page right away.
            // Leaving the screen changes the trigger and cancels this task.
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled, isVisible else { return }
            await session.loadOlderMessages()
        }
    }

    @ViewBuilder private var content: some View {
        switch session.historyLoad {
        case .loadingLatest, .loadingOlder:
            ProgressView().controlSize(.small)
        case .latestFailed(let message):
            retry("Couldn't load messages: \(message)")
        case .olderFailed(let message):
            retry("Couldn't load earlier messages: \(message)")
        case .unavailable(let message):
            Label(message, systemImage: "exclamationmark.triangle")
                .multilineTextAlignment(.center)
        case .idle:
            if session.transcript.paging.hasOlder {
                ProgressView().controlSize(.small)
            } else if session.reachedBeginning, !session.transcript.items.isEmpty {
                Text("Beginning of conversation")
            }
        }
    }

    private func retry(_ message: String) -> some View {
        VStack(spacing: 6) {
            Label(message, systemImage: "exclamationmark.triangle")
                .multilineTextAlignment(.center)
            Button("Retry") {
                Task { await session.retryHistory() }
            }
            .hoverButtonStyle(padding: 4)
            .foregroundStyle(.tint)
        }
    }
}

private struct MessageRow: View {
    let item: TranscriptItem
    /// The chat's profile: stored images are read for it.
    let profile: String?
    let session: ChatSession
    @Environment(AppModel.self) private var model
    @State private var isHovering = false

    var body: some View {
        switch item.role {
        case .user:
            // Shown verbatim: what the user typed, not a reinterpretation of it.
            // Images sent with it show as cards above the caption, live and stored alike.
            HStack {
                Spacer(minLength: 40)
                VStack(alignment: .trailing, spacing: 6) {
                    if !item.images.isEmpty {
                        TrailingFlowLayout {
                            ForEach(item.images) { image in
                                TranscriptImageCard(image: image, profile: profile, store: model.thumbnails,
                                                    connection: model.connection)
                            }
                        }
                    }
                    if !item.text.isEmpty || item.images.isEmpty {
                        Text(item.text)
                            .textSelection(.enabled)
                            .padding(10)
                            .background(.tint.opacity(0.15), in: .rect(cornerRadius: 12))
                    }
                    InlineMessageCopyButton(action: copyMessage)
                }
                .messageCopyAccessory(isHovering: isHovering, placement: .leadingOutside, action: copyMessage)
            }
            .onHover { isHovering = $0 }
            .contextMenu { copyMenu }
        case .assistant:
            AssistantMessageContent(item: item, isHovering: isHovering,
                                    conversationSource: { ConversationMarkdown.export(session.transcript.items) },
                                    copy: copyMessage)
                .onHover { isHovering = $0 }
        case .tool:
            ToolMessageContent(item: item, isHovering: isHovering, copy: copyMessage)
                .onHover { isHovering = $0 }
                .contextMenu { copyMenu }
        case .system:
            HStack {
                Text(item.text)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 4)
                InlineMessageCopyButton(action: copyMessage)
            }
            .messageCopyAccessory(isHovering: isHovering, placement: .trailingGutter(.center), action: copyMessage)
            .onHover { isHovering = $0 }
            .contextMenu { copyMenu }
        }
    }

    private func copyMessage() { Clipboard.copy(ConversationMarkdown.messageSource(for: item)) }

    @ViewBuilder private var copyMenu: some View {
        Button("Copy Message", action: copyMessage)
        #if os(macOS)
        Button("Copy Conversation") { Clipboard.copy(ConversationMarkdown.export(session.transcript.items)) }
        #endif
    }
}
