import HermesKit
import HermesProtocol
import SwiftUI

/// Placeholder chat: transcript, pending approval/clarify cards, composer.
struct ChatView: View {
    let session: ChatSession
    /// False while the chat is kept built but hidden (`KeptChats`): its composer gives up
    /// the keyboard and its shortcuts.
    var isShown = true
    @Environment(ServerConnection.self) private var server

    /// The chat's own composer: it outlives this view (`GatewayConnection.composer(for:)`).
    private var composer: ChatComposer { server.connection.composer(for: session) }

    /// The row at the top of the transcript when an older page was asked for: once the
    /// page lands, the chat scrolls it back to the top of the screen.
    @State private var olderPageAnchor: String?
    /// The transcript's blocks on screen, for the prompt the chat is at.
    @State private var visibleBlocks = VisibleBlocks()
    /// The chat's scroll position: a send scrolls to the end, a fold keeps its place.
    @State private var scroll = ChatScroll()
    /// The newest rows first, the older ones in the frames after (`TranscriptWindow`).
    @State private var window: TranscriptWindow
    /// The scroll view's own width, scroller included (`steadyColumn`); macOS only.
    @State private var chatWidth: CGFloat?
    @Environment(\.textSizes) private var sizes
    @Environment(\.surfaces) private var surfaces

    /// `pushed`: the chat is a page pushed over the session list (iPhone), whose rows
    /// wait for the push to end (`TranscriptWindow`).
    init(session: ChatSession, isShown: Bool = true, pushed: Bool = false) {
        self.session = session
        self.isShown = isShown
        _window = State(initialValue: TranscriptWindow(pushed: pushed))
    }

    /// How wide the chat's messages and composer get, centered in a wider window:
    /// about ChatGPT's measure (48 em) at the content text size.
    static func contentWidth(textSize: CGFloat) -> CGFloat { (textSize * 54).rounded() }

    /// On the Mac, room for the prompt rail at the trailing edge, and as much on the other
    /// side so the messages stay centered.
    static var sideRoom: CGFloat {
        #if os(macOS)
        PromptRail.room
        #else
        0
        #endif
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                TranscriptStack {
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
                .steadyColumn(maxWidth: Self.contentWidth(textSize: sizes.content), sideRoom: Self.sideRoom,
                              in: chatWidth)
            }
            #if os(macOS)
            // Not on iOS, which has no scroller to make room for: there the column took the
            // width measured before a turn to landscape and back, held the scroll view at
            // it, and so never measured the narrower one again; the chat and its composer
            // ran off the screen's right edge (VM, 2026-10-19).
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { chatWidth = $0 }
            #endif
            #if os(iOS)
            // The keyboard goes as on iOS's own chats: a drag down on the transcript takes
            // it along under the finger (back up, it stays), and a tap on the transcript
            // puts it away. Before, nothing did, once the composer had the keyboard.
            .scrollDismissesKeyboard(.interactively)
            .contentShape(.rect)
            .simultaneousGesture(TapGesture().onEnded { Self.dismissKeyboard() })
            #endif
            .environment(\.visibleBlocks, visibleBlocks)
            .environment(\.sessionFolder, session.info?.cwd)
            .transcriptWindow(window, isEmpty: session.transcript.items.isEmpty) { [session] in
                session.transcript.blocks
            }
            // Opens at the newest message and stays there as a reply streams in.
            .defaultScrollAnchor(.bottom)
            .chatScrolling(scroll)
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
            .promptScrolling(transcript: session.transcript, scroll: scroll, visibleBlocks: visibleBlocks, proxy: proxy)
        }
        #if os(macOS)
        .safeAreaInset(edge: .bottom) { composerRow }
        #else
        // A bar, so the messages blur away under the floating card, as under iOS's own bars.
        .safeAreaBar(edge: .bottom) { composerRow }
        // The theme's chat colour, as the Mac's chat card: not the system's black in dark.
        .background { surfaces.chat.ignoresSafeArea() }
        #endif
        // The title is the column's (`RootView`), as several chats are kept built.
        #if os(macOS)
        // No toolbar background over the chat. Its title bar holds no controls, and
        // macOS 26 showed that background while the pointer was over the title bar or
        // the top of the chat: a gray band down to the first message, with a line under it.
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        #endif
    }

    /// The composer, as wide as the messages' text (the content width less its padding).
    /// On the Mac on a bar of the chat's colour, the transcript fading into it, as
    /// Desktop's; on iOS a card floating over the chat, as the Claude app's.
    private var composerRow: some View {
        ComposerView(composer: composer, isConnected: server.isConnected)
            .environment(\.chatIsShown, isShown)
            .disabled(!isShown)
            .frame(maxWidth: Self.contentWidth(textSize: sizes.content) - 32)
            .frame(maxWidth: .infinity)
            #if os(macOS)
            .padding(.horizontal, 16)
            .padding(.horizontal, PromptRail.room)
            .padding(.vertical, 10)
            .background {
                surfaces.chat
                    .overlay(alignment: .top) {
                        LinearGradient(colors: [surfaces.chat.opacity(0), surfaces.chat], startPoint: .top, endPoint: .bottom)
                            .frame(height: 16)
                            .offset(y: -16)
                            .allowsHitTesting(false)
                    }
            }
            #else
            .padding(.horizontal, 12)
            .padding(.top, 6)
            .padding(.bottom, 6)
            #endif
    }

    #if os(iOS)
    /// Whatever has the keyboard (the composer's text view) gives it up.
    private static func dismissKeyboard() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }
    #endif

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
    @Environment(\.transcriptWindow) private var window

    /// Re-runs the load when a page lands and the header is still on screen.
    private struct Trigger: Equatable {
        var isVisible: Bool
        var offset: Int
    }

    var body: some View {
        // Not above a transcript still being built (`TranscriptWindow`): on screen over
        // the first frame's rows, it would read an older page before the rest of this
        // one is built. A chat with no rows yet shows its spinner.
        if window?.isWaitingForPush == true, !session.transcript.items.isEmpty {
            // The rows come once the page is pushed (iPhone).
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity)
        } else if window?.isComplete != false || session.transcript.items.isEmpty {
            header
        }
    }

    private var header: some View {
        HStack {
            Spacer()
            content
            Spacer()
        }
        .uiFont(.caption)
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
    @Environment(\.surfaces) private var surfaces
    @Environment(ServerConnection.self) private var server
    @Environment(AppModel.self) private var model

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
                                .contentFont()
                                .textSelection(.enabled)
                                .padding(10)
                                .background(surfaces.userBubble, in: .rect(cornerRadius: 12))
                        }
                        MessageActionBar(isHovering: isHovering, isNewest: isNewest,
                                         alignment: .trailing, timestamp: item.timestamp, copy: copyMessage)
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
                                        branch: branchAction,
                                        copy: copyMessage)
            }
        case .tool:
            ToolMessageContent(item: item)
                .contextMenu { copyMenu }
        case .system:
            Text(item.text).uiFont(.caption).foregroundStyle(.secondary)
                .contextMenu { copyMenu }
        }
    }

    private func copyMessage() { Clipboard.copy(ConversationMarkdown.messageSource(for: item)) }

    /// Branch in New Chat from this message; not for a bot's Bot Chat, which isn't copied
    /// (`SessionActionError.botChatProtected`).
    private var branchAction: (() -> Void)? {
        guard !server.connection.isProtected(session) else { return nil }
        let (model, session, item, server) = (model, session, item, server)
        return { Task { await model.branch(session, at: item, on: server) } }
    }

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
