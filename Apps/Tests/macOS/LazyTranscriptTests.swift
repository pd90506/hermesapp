import AppKit
import HermesKit
import HermesProtocol
import SwiftUI
import Testing

/// The chat draws only the blocks near the screen (`TranscriptLaziness`): the rest are
/// clear space of the height they had, so the content keeps its height as it scrolls
/// (the scroller's knob does not jump), and a fold opened before scrolling away is open
/// when it comes back (`RowMemory`).
@MainActor
@Suite(.serialized) struct LazyTranscriptTests {
    @MainActor @Observable final class Chat {
        var transcript = Transcript()
        let scroll = ChatScroll()
        let laziness = TranscriptLaziness()
        let memory = RowMemory()
        let visible = VisibleBlocks()
        @ObservationIgnored var contentHeight: CGFloat = 0
        @ObservationIgnored var containerHeight: CGFloat = 0
    }

    /// `ChatView`'s scroll view with its rows drawn as `MessageRow` draws them.
    private struct Harness: View {
        let chat: Chat
        let lazy: Bool
        @State private var window = TranscriptWindow()

        var body: some View {
            ScrollView {
                TranscriptStack {
                    TranscriptMessages(transcript: chat.transcript) { item, isNewest in
                        Row(item: item, isNewest: isNewest)
                    } requests: {
                        EmptyView()
                    }
                }
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { chat.laziness.widthChanged($0) }
                .padding()
                .frame(maxWidth: 700)
                .frame(maxWidth: .infinity)
            }
            .environment(\.transcriptLaziness, lazy ? chat.laziness : nil)
            .environment(\.rowMemory, lazy ? chat.memory : nil)
            .environment(\.visibleBlocks, chat.visible)
            .transcriptWindow(window, isEmpty: chat.transcript.items.isEmpty) { chat.transcript.blocks }
            .defaultScrollAnchor(.bottom)
            .chatScrolling(chat.scroll)
            .onScrollGeometryChange(for: CGSize.self) {
                CGSize(width: $0.containerSize.height, height: $0.contentSize.height)
            } action: { _, size in
                chat.containerHeight = size.width
                chat.contentHeight = size.height
            }
        }
    }

    /// A row as `ChatView`'s `MessageRow` draws it: hover area, action bar, menus.
    private struct Row: View {
        let item: TranscriptItem
        let isNewest: Bool

        var body: some View {
            switch item.role {
            case .user:
                HStack {
                    Spacer(minLength: 40)
                    MessageHoverArea { isHovering in
                        VStack(alignment: .trailing, spacing: 0) {
                            Text(item.text)
                                .textSelection(.enabled)
                                .padding(10)
                                .background(.quaternary, in: .rect(cornerRadius: 12))
                            MessageActionBar(isHovering: isHovering, isNewest: isNewest, alignment: .trailing,
                                             timestamp: item.timestamp, copy: {})
                        }
                    }
                }
                .contextMenu { Button("Copy Message") {} }
            case .assistant:
                MessageHoverArea { isHovering in
                    AssistantMessageContent(item: item, isHovering: isHovering, isNewest: isNewest,
                                            conversationSource: { "" }, branch: {}, copy: {})
                }
            case .tool:
                ToolMessageContent(item: item).contextMenu { Button("Copy Message") {} }
            case .system:
                Text(item.text).contextMenu { Button("Copy Message") {} }
            }
        }
    }

    @MainActor private final class UI {
        static let size = CGSize(width: 900, height: 800)
        let chat = Chat()
        let window: NSWindow

        init(pages: Int, lazy: Bool) {
            var transcript = Transcript()
            transcript.installLatestPage(ChatSwitchTests.page(seed: 0), hasOlder: pages > 1)
            for page in 1..<max(pages, 1) {
                transcript.prependOlderPage(ChatSwitchTests.page(seed: page), hasOlder: page < pages - 1)
            }
            chat.transcript = transcript
            window = NSWindow(contentRect: .testArea(Self.size), styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: Harness(chat: chat, lazy: lazy))
            window.showInTestArea()
        }

        func close() { window.close() }

        func turn() async -> TimeInterval {
            let start = Date()
            try? await Task.sleep(for: .milliseconds(4))
            return Date().timeIntervalSince(start)
        }

        /// Turns until the content's height has stayed put for `quiet` seconds.
        func settle(quiet: TimeInterval = 0.6) async {
            var height = chat.contentHeight, since = Date()
            let start = Date()
            while Date().timeIntervalSince(since) < quiet, Date().timeIntervalSince(start) < 20 {
                _ = await turn()
                if chat.contentHeight != height { height = chat.contentHeight; since = Date() }
            }
        }

        /// The messages' text views in the window: one or more per drawn reply.
        var textViews: Int {
            func count(_ view: NSView) -> Int {
                (view is MarkdownSelectionTextView ? 1 : 0) + view.subviews.reduce(0) { $0 + count($1) }
            }
            return window.contentView.map(count) ?? 0
        }

        var maxY: CGFloat { max(0, chat.contentHeight - chat.containerHeight) }

        /// Scrolls a few lines up and down from where the chat is, 12 pt a frame, 8 times:
        /// each frame's time, slowest last.
        func nudge() async -> [TimeInterval] {
            let start = chat.scroll.shownY
            var frames: [TimeInterval] = []
            for pass in 0..<8 {
                for i in 1...20 {
                    let offset = CGFloat(pass % 2 == 0 ? i : 20 - i) * 12
                    chat.scroll.position.scrollTo(y: max(0, start - offset))
                    frames.append(await turn() - 0.004)
                }
            }
            return frames.sorted()
        }

        /// Scrolls to `y`, a frame at a time in steps of `step`, recording the content's
        /// height and each frame's time.
        func scroll(to y: CGFloat, step: CGFloat) async -> (heights: [CGFloat], frames: [TimeInterval]) {
            var current = chat.scroll.shownY
            var heights: [CGFloat] = [], frames: [TimeInterval] = []
            while abs(current - y) > 0.5 {
                current = y < current ? max(y, current - step) : min(y, current + step)
                chat.scroll.position.scrollTo(y: current)
                frames.append(await turn() - 0.004)
                heights.append(chat.contentHeight)
            }
            for _ in 0..<10 {
                _ = await turn()
                heights.append(chat.contentHeight)
            }
            return (heights, frames)
        }
    }

    private func ms(_ seconds: TimeInterval) -> String { String(format: "%.1f ms", seconds * 1000) }

    /// Three pages of a chat: drawn lazily, the content is as tall as with every row
    /// drawn, holds its height through a scroll to the top and back (a few lines at a
    /// time), and only the rows near the screen have text views.
    @Test func lazyChatKeepsItsHeightWhileScrolling() async throws {
        let all = UI(pages: 3, lazy: false)
        await all.settle()
        let fullHeight = all.chat.contentHeight
        let allTextViews = all.textViews
        let allNudges = await all.nudge()
        let allFrames = await all.scroll(to: 0, step: 40).frames.sorted()
        all.close()

        let ui = UI(pages: 3, lazy: true)
        defer { ui.close() }
        await ui.settle()
        #expect(abs(ui.chat.contentHeight - fullHeight) < 1, "lazy \(ui.chat.contentHeight) pt, all drawn \(fullHeight) pt")
        let atBottom = ui.textViews
        #expect(atBottom < allTextViews / 3, "text views: \(atBottom) near the screen, \(allTextViews) with every row drawn")

        let lazyNudges = await ui.nudge()
        let up = await ui.scroll(to: 0, step: 40)
        let spread = (up.heights.max() ?? 0) - (up.heights.min() ?? 0)
        #expect(spread < 1, "the content's height moved by \(spread) pt on the way up")
        #expect(abs(ui.chat.scroll.shownY) < 1, "reached the top: \(ui.chat.scroll.shownY)")
        let atTop = ui.textViews
        #expect(atTop < allTextViews / 3, "text views at the top: \(atTop) of \(allTextViews)")
        // The blocks on screen, for the prompt rail and the scroll-to-bottom button: the
        // first at the top, not the last, and only a screen's worth.
        let blocks = ui.chat.transcript.blocks.map(\.id)
        let shownAtTop = ui.chat.visible.ids
        #expect(shownAtTop.contains(blocks[0]) && !shownAtTop.contains(blocks[blocks.count - 1]), "\(shownAtTop)")
        #expect(shownAtTop.count < 12, "\(shownAtTop.count) blocks on screen at the top")

        let down = await ui.scroll(to: ui.maxY, step: 40)
        let downSpread = (down.heights.max() ?? 0) - (down.heights.min() ?? 0)
        #expect(downSpread < 1, "the content's height moved by \(downSpread) pt on the way down")
        #expect(abs(ui.chat.contentHeight - fullHeight) < 1)
        let shownAtBottom = ui.chat.visible.ids
        #expect(shownAtBottom.contains(blocks[blocks.count - 1]) && !shownAtBottom.contains(blocks[0]), "\(shownAtBottom)")

        let lazyFrames = up.frames.sorted()
        func median(_ values: [TimeInterval]) -> TimeInterval { values[values.count / 2] }
        let report = ("3 pages, frame median / slowest. A few lines up and down: every row drawn "
            + "\(ms(median(allNudges))) / \(ms(allNudges.last ?? 0)), lazy \(ms(median(lazyNudges))) / \(ms(lazyNudges.last ?? 0)). "
            + "To the top: every row drawn \(ms(median(allFrames))) / \(ms(allFrames.last ?? 0)), "
            + "lazy \(ms(median(lazyFrames))) / \(ms(lazyFrames.last ?? 0)). Text views \(allTextViews) → \(atBottom)")
        print(report)
        // The VM run keeps the numbers here (`scripts/vm-test.sh` shows no test output).
        try? report.write(toFile: NSTemporaryDirectory() + "lazy-transcript.txt", atomically: true, encoding: .utf8)
    }

    /// A fold opened near the bottom, then scrolled far away and back: open again, at the
    /// height its clear space kept.
    @Test func foldOpenedBeforeScrollingAwayIsOpenWhenBack() async throws {
        let ui = UI(pages: 2, lazy: true)
        defer { ui.close() }
        await ui.settle()
        let work = try #require(ui.chat.transcript.blocks.reversed().lazy.compactMap { block -> TurnWork? in
            if case .work(let work) = block { work } else { nil }
        }.first)
        let closed = ui.chat.contentHeight
        ui.chat.memory.save("work:\(work.id)", true as Bool?)
        await ui.settle()
        let opened = ui.chat.contentHeight
        #expect(opened > closed + 20, "the turn's work opened: \(closed) → \(opened) pt")

        _ = await ui.scroll(to: 0, step: 400)
        await ui.settle()
        #expect(abs(ui.chat.contentHeight - opened) < 1, "far away: \(ui.chat.contentHeight) of \(opened) pt")
        _ = await ui.scroll(to: ui.maxY, step: 400)
        await ui.settle()
        #expect(abs(ui.chat.contentHeight - opened) < 1, "back: \(ui.chat.contentHeight) of \(opened) pt")
        #expect(ui.chat.memory.saved("work:\(work.id)", as: Bool?.self)?.value == true)
    }
}
