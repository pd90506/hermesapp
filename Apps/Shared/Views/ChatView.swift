import HermesKit
import HermesProtocol
import SwiftUI

/// Placeholder chat: transcript, pending approval/clarify cards, composer.
struct ChatView: View {
    let session: ChatSession
    /// Overrides the session title (a Bot Chat is titled "Bot Chat"; show the bot instead).
    var title: String?
    @Environment(ServerConnection.self) private var server

    /// The chat's own composer: it outlives this view (`GatewayConnection.composer(for:)`).
    private var composer: ChatComposer { server.connection.composer(for: session) }

    /// The row at the top of the transcript when an older page was asked for: once the
    /// page lands, the chat scrolls it back to the top of the screen.
    @State private var olderPageAnchor: String?

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    HistoryHeader(session: session, loadOlder: loadOlderMessages)
                    TranscriptMessages(transcript: session.transcript) { item, isNewest in
                        MessageRow(item: item, isNewest: isNewest, profile: session.profile, session: session)
                    } requests: {
                        ForEach(session.transcript.pendingRequests) { request in
                            RequestCardView(session: session, request: request)
                        }
                    }
                }
                .padding()
            }
            // Opens at the newest message and stays there as a reply streams in.
            .defaultScrollAnchor(.bottom)
            // An older page lands above the rows on screen. Left alone, the view stays
            // at the top edge, so the header shows again and reads the next page, and
            // so on to the beginning. Keep the row that was on top where it was: the
            // header leaves the screen until the user scrolls up past the new page.
            .onChange(of: session.transcript.nextOlderOffset) {
                guard let anchor = olderPageAnchor else { return }
                olderPageAnchor = nil
                if let id = session.transcript.blockID(containing: anchor) {
                    proxy.scrollTo(id, anchor: .top)
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            ComposerView(composer: composer, isConnected: server.isConnected)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(.bar)
        }
        .navigationTitle(title ?? session.title ?? "New Chat")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    private func loadOlderMessages() async {
        let offset = session.transcript.nextOlderOffset
        olderPageAnchor = session.transcript.items.first?.id
        await session.loadOlderMessages()
        // No page landed (failed, cancelled, nothing older): nothing to restore.
        if session.transcript.nextOlderOffset == offset { olderPageAnchor = nil }
    }
}

/// Top of the transcript: loads the next older page while it is on screen,
/// offers a retry when a page failed, and marks the beginning of the chat.
private struct HistoryHeader: View {
    let session: ChatSession
    /// Reads the next older page, keeping the rows on screen in place.
    let loadOlder: @MainActor @Sendable () async -> Void
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
            await loadOlder()
        }
    }

    @ViewBuilder private var content: some View {
        switch session.historyLoad {
        case .loadingLatest, .loadingOlder:
            ProgressView().controlSize(.small)
        case .latestFailed(let message):
            retry("Couldn't load messages: \(message)") { await session.retryHistory() }
        case .olderFailed(let message):
            retry("Couldn't load earlier messages: \(message)", action: loadOlder)
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

    private func retry(_ message: String, action: @escaping @MainActor @Sendable () async -> Void) -> some View {
        VStack(spacing: 6) {
            Label(message, systemImage: "exclamationmark.triangle")
                .multilineTextAlignment(.center)
            Button("Retry") {
                Task { await action() }
            }
            .hoverButtonStyle(padding: 4)
            .foregroundStyle(.tint)
        }
    }
}

private struct MessageRow: View {
    let item: TranscriptItem
    /// The last user or assistant row: its action bar stays shown without hover.
    let isNewest: Bool
    /// The chat's profile: stored images are read for it.
    let profile: String?
    let session: ChatSession
    @Environment(ServerConnection.self) private var server

    var body: some View {
        // Background work Hermes reported as a user turn: a line, not a prompt bubble.
        if let notice = item.backgroundNotice {
            BackgroundNoticeRow(notice: notice)
                .contextMenu { copyMenu }
        } else {
            row
        }
    }

    @ViewBuilder private var row: some View {
        switch item.role {
        case .user:
            // Shown verbatim: what the user typed, not a reinterpretation of it.
            // Images sent with it show as cards above the caption, live and stored alike.
            HStack {
                Spacer(minLength: 40)
                MessageHoverArea { isHovering in
                    VStack(alignment: .trailing, spacing: 0) {
                        if !item.images.isEmpty {
                            TrailingFlowLayout {
                                ForEach(item.images) { image in
                                    TranscriptImageCard(image: image, profile: profile, store: server.thumbnails,
                                                        connection: server.connection)
                                }
                            }
                        }
                        if !item.attachments.isEmpty {
                            VStack(alignment: .trailing, spacing: 4) {
                                ForEach(Array(item.attachments.enumerated()), id: \.offset) { index, name in
                                    let path = index < item.attachmentPaths.count ? item.attachmentPaths[index] : name
                                    FileChipView(path: path, name: name, context: fileContext)
                                }
                            }
                            .padding(.bottom, 4)
                        }
                        if !item.text.isEmpty || (item.images.isEmpty && item.attachments.isEmpty) {
                            Text(item.text)
                                .textSelection(.enabled)
                                .padding(10)
                                .background(.tint.opacity(0.15), in: .rect(cornerRadius: 12))
                        }
                        MessageActionBar(isHovering: isHovering, isNewest: isNewest,
                                         alignment: .trailing, copy: copyMessage)
                    }
                }
            }
            .contextMenu { copyMenu }
        case .assistant:
            // `TranscriptMessages` skips a reply with nothing to show yet.
            MessageHoverArea { isHovering in
                AssistantMessageContent(item: item, isHovering: isHovering, isNewest: isNewest,
                                        conversationSource: { ConversationMarkdown.export(session.transcript.items) },
                                        deliveredFiles: deliveredFiles,
                                        copy: copyMessage)
            }
        case .tool:
            ToolMessageContent(item: item)
                .contextMenu { copyMenu }
        case .system:
            Text(item.text).font(.caption).foregroundStyle(.secondary)
                .contextMenu { copyMenu }
        }
    }

    private func copyMessage() { Clipboard.copy(ConversationMarkdown.messageSource(for: item)) }

    private var fileContext: GatewayFileContext {
        GatewayFileContext(profile: profile, sessionKey: session.storedSessionID, connection: server.connection,
                           downloads: server.downloads)
    }

    private func deliveredFiles(_ files: [DeliveredFile]) -> AnyView {
        AnyView(DeliveredFilesView(files: files, context: fileContext, thumbnails: server.thumbnails))
    }

    @ViewBuilder private var copyMenu: some View {
        Button("Copy Message", action: copyMessage)
        #if os(macOS)
        Button("Copy Conversation") { Clipboard.copy(ConversationMarkdown.export(session.transcript.items)) }
        #endif
    }
}
