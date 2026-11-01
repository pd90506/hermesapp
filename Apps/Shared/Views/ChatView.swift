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
    /// The chat's height, for a short chat's blank space (Mac).
    @State private var chatHeight: CGFloat?
    /// Only the blocks near the screen are drawn (`TranscriptLaziness`); what the rows
    /// remember meanwhile (`RowMemory`).
    @State private var laziness = TranscriptLaziness()
    @State private var rowMemory = RowMemory()
    /// The task list's card is open (`TodoPill`).
    @State private var isTodoOpen = false
    @Environment(\.textSizes) private var sizes
    @Environment(\.surfaces) private var surfaces
    /// The composer's card and the scroll-to-bottom pill, as one glass (`ChatGlass`).
    @Namespace private var glass

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

    /// How far a table may reach past each side of the column (`MarkdownTableGrid`): the
    /// window's width beside the column, less the prompt rail's room and a scroller's, so
    /// a wide table only scrolls once the window is too narrow for it (the user,
    /// 2026-10-30). The transcript's padding stays as the margin.
    private var tableReach: CGFloat {
        guard let chatWidth else { return 0 }
        let column = SteadyColumn.width(maxWidth: Self.contentWidth(textSize: sizes.content),
                                        sideRoom: Self.sideRoom, outerWidth: chatWidth)
        return max(0, ((chatWidth - column) / 2 - Self.sideRoom - SteadyColumn.scrollerRoom).rounded(.down))
    }

    /// On the Mac, room for the prompt rail at the trailing edge, and as much on the other
    /// side so the messages stay centered.
    static var sideRoom: CGFloat {
        #if os(macOS)
        PromptRail.room
        #else
        0
        #endif
    }

    /// How far the scroll-to-bottom pill floats above the composer's card. The chat's glass
    /// merges shapes this close, so the pill comes out of the card, yet at rest they are apart.
    static var pillGap: CGFloat {
        #if os(macOS)
        16
        #else
        20
        #endif
    }

    /// On the Mac the composer's card and the scroll-to-bottom pill in one glass container,
    /// so their glass morphs: the pill grows out of the card and melts back into it. Not on
    /// iOS (VM, 2026-10-20): around the chat, the container lost the messages' blur under
    /// the composer's bar and the composer's keyboard; around the bar alone, the pill over
    /// it, outside the bar, took no taps.
    var body: some View {
        #if os(macOS)
        GlassEffectContainer(spacing: Self.pillGap) {
            chat
        }
        .environment(\.chatGlass, ChatGlass(namespace: glass))
        #else
        chat
        #endif
    }

    private var chat: some View {
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
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { laziness.widthChanged($0) }
                .quietWhileScrolling(scroll)
                .environment(\.tableReach, tableReach)
                .padding()
                .steadyColumn(maxWidth: Self.contentWidth(textSize: sizes.content), sideRoom: Self.sideRoom,
                              in: chatWidth)
                #if os(macOS)
                // A short chat starts at the top, under the title, as tall as the chat, with
                // blank space below its last message (the user, 2026-10-22). At the bottom,
                // with the space above it, the system drew its scroll edge from the window's
                // top down to the first message, a band in dark (#54; VM 2026-10-22).
                .frame(minHeight: chatHeight, alignment: .top)
                #endif
            }
            #if os(macOS)
            // Not on iOS, which has no scroller to make room for: there the column took the
            // width measured before a turn to landscape and back, held the scroll view at
            // it, and so never measured the narrower one again; the chat and its composer
            // ran off the screen's right edge (VM, 2026-10-19).
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { chatWidth = $0 }
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { chatHeight = $0 }
            #endif
            #if os(macOS)
            // The messages blur away under the toolbar's title.
            .scrollEdgeEffectStyle(.soft, for: .top)
            #endif
            #if os(iOS)
            // The messages blur away under the composer's bar, down to the screen's edge, as
            // in the Claude app. The automatic style, which the bar alone gave, left them
            // sharp under and around the card (VM, 2026-10-19).
            .scrollEdgeEffectStyle(.soft, for: .bottom)
            // The keyboard goes as on iOS's own chats: a drag down on the transcript takes
            // it along under the finger (back up, it stays), and a tap on the transcript
            // puts it away. Before, nothing did, once the composer had the keyboard.
            .scrollDismissesKeyboard(.interactively)
            .contentShape(.rect)
            .simultaneousGesture(TapGesture().onEnded { Self.dismissKeyboard() })
            #endif
            .environment(\.visibleBlocks, visibleBlocks)
            .environment(\.transcriptLaziness, laziness)
            .environment(\.rowMemory, rowMemory)
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
            // Over the chat, not the composer: at the bottom of the safe area, which ends
            // where the composer's bar begins, so the button sits just above the card, clear
            // of the bar's blur and inside its own hit area.
            .overlay(alignment: .bottom) {
                // Beside the task list's pill instead, while that shows (`composerRow`).
                if session.transcript.todoPlan == nil || isTodoOpen {
                    ScrollToBottomButton(transcript: session.transcript, scroll: scroll, visibleBlocks: visibleBlocks)
                        #if os(macOS)
                        // 16 pt above the card (`pillGap`), as Desktop's, with the bar's 10 pt padding.
                        .padding(.bottom, Self.pillGap - 10)
                        #endif
                }
            }
        }
        #if os(macOS)
        // An inset, not a bar: under a bar the Mac drew its edge, a grey band and a line,
        // only while the pointer was over the chat (VM, 2026-10-20). The messages fade into
        // the inset of their own (`composerRow`).
        .safeAreaInset(edge: .bottom) { composerRow }
        #else
        // A bar, so the messages blur away under the floating card, as under iOS's own bars.
        .safeAreaBar(edge: .bottom) { composerRow }
        #endif
        #if os(iOS)
        // The theme's chat colour, as the Mac's chat card: not the system's black in dark.
        .background { surfaces.chat.ignoresSafeArea() }
        #endif
        // The title is the column's (`RootView`), as several chats are kept built.
    }

    /// The composer, as wide as the messages' text (the content width less its padding):
    /// a glass card floating over the chat, as the Claude app's. On iOS the messages blur
    /// away under it (`scrollEdgeEffectStyle`); on the Mac they fade into the chat's colour
    /// from the bar's top to the card's middle, so the card's glass shows them blurred
    /// under its top as they go.
    ///
    /// The agent's task list rides on top of the card (`TodoPill`), inside the bar. While
    /// it shows, the scroll-to-bottom pill joins it there as a round arrow, side by side,
    /// rather than float over it, as Claude Code's (the user, 2026-10-31).
    private var composerRow: some View {
        VStack(spacing: 8) {
            TodoPill(transcript: session.transcript, scroll: scroll, isOpen: $isTodoOpen) {
                ScrollToBottomButton(transcript: session.transcript, scroll: scroll, visibleBlocks: visibleBlocks,
                                     compact: true)
            }
            ComposerView(composer: composer, isConnected: server.isConnected)
                .environment(\.chatIsShown, isShown)
                .disabled(!isShown)
        }
        .frame(maxWidth: Self.contentWidth(textSize: sizes.content) - 32)
        .frame(maxWidth: .infinity)
        #if os(macOS)
        .padding(.horizontal, 16)
        .padding(.horizontal, PromptRail.room)
        .padding(.vertical, 10)
        .background {
            LinearGradient(stops: [.init(color: surfaces.chat.opacity(0), location: 0),
                                   .init(color: surfaces.chat, location: 0.55)],
                           startPoint: .top, endPoint: .bottom)
                .allowsHitTesting(false)
        }
        #else
        .padding(.horizontal, 12)
        // Room above the card inside the bar: the blur (`scrollEdgeEffectStyle`) starts
        // there, so a line above the card is already soft as it reaches it.
        .padding(.top, Self.pillGap)
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
            BackgroundNoticeRow(notice: notice, id: item.id)
                .contextMenu { copyMenu }
        } else if let note = item.reviewNote {
            ReviewNoteRow(note: note)
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
                            // Apart from the caption's bubble (the user, 2026-10-29: they touched).
                            .padding(.bottom, 6)
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
                                         alignment: .trailing, timestamp: item.timestamp,
                                         outgoingStatus: item.outgoingStatus, copy: copyMessage)
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
