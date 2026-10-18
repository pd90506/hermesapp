import AppKit
import HermesKit
import HermesProtocol
import SwiftUI
import Testing

/// The chat's scroll view (`ChatView`), built from its own pieces: the transcript stack
/// (`TranscriptStack`) with real replies in it, its bottom anchor, and its scroll
/// position (`chatScrolling`). Insets stand in for the title bar and the composer.
///
/// Scrolling goes through SwiftUI (`ScrollPosition`), as in `PromptRailTests`: wheel
/// events sent here do not scroll the chat (measured 2026-10-17).
@MainActor
@Suite(.serialized) struct ChatScrollingTests {
    @MainActor @Observable final class Chat {
        var items: [TranscriptItem] = []
        /// How tall the last row's extra part is: a fold opening, or a reply streaming.
        var extra: CGFloat = 0
        let scroll = ChatScroll()
    }

    private struct Harness: View {
        @Bindable var chat: Chat

        var body: some View {
            ScrollView {
                TranscriptStack { rows }
                    .padding()
            }
            .defaultScrollAnchor(.bottom)
            .chatScrolling(chat.scroll)
            .safeAreaInset(edge: .top, spacing: 0) { Color.clear.frame(height: UI.titleBar) }
            .safeAreaInset(edge: .bottom, spacing: 0) { Color.clear.frame(height: UI.composer) }
        }

        @ViewBuilder private var rows: some View {
            ForEach(chat.items) { item in
                if item.role == .user {
                    Text(item.text).padding(10).frame(maxWidth: .infinity, alignment: .trailing)
                } else {
                    AssistantMessageContent(item: item) {}
                }
            }
            Color.clear.frame(height: chat.extra)
        }
    }

    /// Replies of very different heights, as a real chat has: a line, paragraphs, a table.
    static func conversation(turns: Int) -> [TranscriptItem] {
        let table = "| Command | Output |\n|---|---|\n" + (1...6).map { "| `echo \($0)` | a longer cell that wraps \($0) |" }
            .joined(separator: "\n")
        return (0..<turns).flatMap { turn -> [TranscriptItem] in
            let paragraphs = (0...(turn % 5)).map { _ in
                "A paragraph of the reply that runs long enough to wrap over several lines in a narrow window, "
                    + "with **bold**, `code` and a [link](https://example.com)."
            }
            var body = paragraphs.joined(separator: "\n\n")
            if turn % 3 == 0 { body += "\n\n" + table }
            return [
                TranscriptItem(id: "u\(turn)", role: .user, text: "Prompt \(turn)"),
                TranscriptItem(id: "a\(turn)", role: .assistant, text: turn % 4 == 1 ? "Short." : body),
            ]
        }
    }

    @MainActor private final class UI {
        static let size = CGSize(width: 520, height: 480)
        static let titleBar: CGFloat = 52
        static let composer: CGFloat = 90
        let chat = Chat()
        let window: NSWindow
        let host: NSView

        init(turns: Int) {
            chat.items = ChatScrollingTests.conversation(turns: turns)
            window = NSWindow(contentRect: .testArea(Self.size),
                              styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            host = NSHostingView(rootView: Harness(chat: chat))
            window.contentView = host
            window.showInTestArea()
            settle()
        }

        func close() { window.close() }

        /// Runs the loop until `condition` holds, for at most `timeout` seconds.
        @discardableResult
        func waitFor(timeout: TimeInterval = 2, _ condition: () -> Bool) -> Bool {
            let deadline = Date().addingTimeInterval(timeout)
            while !condition() {
                if Date() > deadline { return false }
                RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            }
            return true
        }

        func settle(_ rounds: Int = 10) {
            for _ in 0..<rounds { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        }

        var scrollView: NSScrollView? {
            func find(_ view: NSView) -> NSScrollView? {
                (view as? NSScrollView) ?? view.subviews.lazy.compactMap(find).first
            }
            return find(host)
        }

        var contentHeight: CGFloat? { scrollView?.documentView?.frame.height }

        /// Where the visible part starts, from the content's top.
        var shownTop: CGFloat? {
            guard let scroll = scrollView, let document = scroll.documentView else { return nil }
            let bounds = scroll.contentView.bounds
            return document.isFlipped ? bounds.minY : document.frame.height - bounds.maxY
        }

        /// How much content is below the visible part.
        var remainingBelow: CGFloat? {
            guard let scroll = scrollView, let document = scroll.documentView else { return nil }
            let bounds = scroll.contentView.bounds
            return document.isFlipped ? document.frame.height - bounds.maxY : bounds.minY
        }

        func scroll(toY y: CGFloat) {
            chat.scroll.position.scrollTo(y: y)
            settle()
        }
    }

    /// Scrolling from the end to the top, the content keeps one height, so the scroller's
    /// knob keeps its size and moves only with the scroll.
    @Test func theContentKeepsOneHeightWhileScrolling() throws {
        let ui = UI(turns: 40)
        defer { ui.close() }
        let height = try #require(ui.contentHeight)
        #expect(try #require(ui.remainingBelow) < 2, "the chat opens at its end")
        var heights: [CGFloat] = []
        var y = height
        while y > 0 {
            y -= 140
            ui.scroll(toY: max(y, 0))
            heights.append(try #require(ui.contentHeight))
        }
        let spread = (heights.max() ?? 0) - (heights.min() ?? 0)
        #expect(spread < 1, "the content's height changed while scrolling: \(Set(heights).sorted())")
        #expect(abs((heights.last ?? 0) - height) < 1, "opened at \(height), \(heights.last ?? 0) at the top")
    }

    /// A fold opened at the end of the chat opens below its line, which stays put; it
    /// moved up by the fold's height when the bottom stayed put instead.
    @Test func aFoldOpenedAtTheEndKeepsItsLine() throws {
        let ui = UI(turns: 12)
        defer { ui.close() }
        #expect(try #require(ui.remainingBelow) < 2, "the chat opens at its end")
        let top = try #require(ui.shownTop)
        let height = try #require(ui.contentHeight)
        // As a fold's button does.
        ui.chat.scroll.keepingPlace { ui.chat.extra = 300 }
        let grew = ui.waitFor { (ui.contentHeight ?? 0) > height + 299 }
        ui.settle()
        #expect(grew, "the fold did not open: \(height) -> \(ui.contentHeight ?? 0)")
        let after = try #require(ui.shownTop)
        let below = try #require(ui.remainingBelow)
        #expect(abs(after - top) < 1, "the rows on screen moved from \(top) to \(after)")
        #expect(below > 300 - UI.composer - 10, "the fold opened below the screen: \(below) pt below (the composer covers \(UI.composer))")

        // And closes again in place.
        ui.chat.scroll.keepingPlace { ui.chat.extra = 0 }
        ui.waitFor { abs((ui.contentHeight ?? 0) - height) < 1 }
        ui.settle()
        let closed = try #require(ui.shownTop)
        #expect(abs(closed - top) < 1, "closing moved the rows on screen from \(top) to \(closed)")
    }

    /// Scrolled up, a fold opening keeps the rows on screen where they are.
    @Test func aFoldOpenedScrolledUpKeepsItsLine() throws {
        let ui = UI(turns: 20)
        defer { ui.close() }
        ui.scroll(toY: 400)
        let top = try #require(ui.shownTop)
        let height = try #require(ui.contentHeight)
        #expect(try #require(ui.remainingBelow) > 200, "scrolled up")
        ui.chat.scroll.keepingPlace { ui.chat.extra = 300 }
        ui.waitFor { (ui.contentHeight ?? 0) > height + 299 }
        ui.settle()
        let after = try #require(ui.shownTop)
        #expect(abs(after - top) < 1, "the rows on screen moved from \(top) to \(after)")
    }

    /// A reply streaming at the end of the chat keeps the chat at its end.
    @Test func aReplyGrowingAtTheEndIsFollowed() throws {
        let ui = UI(turns: 12)
        defer { ui.close() }
        #expect(try #require(ui.remainingBelow) < 2, "the chat opens at its end")
        for step in 1...5 {
            ui.chat.extra = CGFloat(step) * 40
            ui.settle()
        }
        #expect(try #require(ui.remainingBelow) < 2, "the chat stopped following the reply")
    }

    /// A new chat's reply outgrows the screen and the chat follows it to its end, as
    /// it streams in and for a second prompt. It stayed at the top once the reply
    /// passed the screen's height (VM, 2026-10-18).
    @Test func aShortChatFollowsItsReplyPastTheScreen() throws {
        let ui = UI(turns: 1)
        defer { ui.close() }
        for step in 1...30 {
            ui.chat.extra = CGFloat(step) * 50
            ui.settle(3)
        }
        ui.settle()
        #expect(try #require(ui.remainingBelow) < 2, "the chat stopped following the reply")
    }
}

/// The chat folds once: reasoning and tool calls inside an opened run don't fold again.
///
/// Checked by what is laid out: SwiftUI's accessibility elements are not built for a
/// window test, and a click synthesized here does not reach a SwiftUI button
/// (`PromptRailTests`), so pressing a fold's line is checked by hand.
@MainActor
@Suite struct FoldTests {
    private func host(_ view: some View, width: CGFloat = 420) -> NSHostingView<AnyView> {
        let host = NSHostingView(rootView: AnyView(view.frame(width: width)))
        host.frame.size = host.fittingSize
        host.layoutSubtreeIfNeeded()
        return host
    }

    private func texts(in view: NSView) -> [String] {
        ((view as? NSTextView).map { [$0.string] } ?? []) + view.subviews.flatMap(texts)
    }

    static func tool(_ id: String, command: String) -> TranscriptItem {
        var item = TranscriptItem(id: id, role: .tool, text: "")
        item.toolName = "terminal"
        var tool = ToolActivity(toolID: id, name: "terminal", phase: .complete)
        tool.args = ["command": .string(command)]
        tool.output = "\(command) output"
        item.tool = tool
        return item
    }

    /// An opened run lists its calls; each is its own line that opens in place, below
    /// itself, as Desktop's rows do. Reasoning never sits inside a run.
    @Test func anOpenedRunListsItsCallsAndACallOpensBelowItsLine() {
        let run = ToolRun(id: "run", items: [Self.tool("t1", command: "echo alpha"),
                                              Self.tool("t2", command: "echo beta")], isLive: false)
        let closed = host(ToolRunView(run: run) { ToolMessageContent(item: $0) }).fittingSize.height
        let opened = host(ToolRunView(run: run, isExpanded: true) { ToolMessageContent(item: $0) }).fittingSize.height
        #expect(closed < 24, "a closed run is one line, not \(closed) pt")
        #expect(opened > closed * 2, "an opened run shows each call (\(opened) pt)")

        let call = Self.tool("t1", command: "echo alpha")
        let line = host(ToolMessageContent(item: call)).fittingSize.height
        let card = host(ToolMessageContent(item: call, isExpanded: true)).fittingSize.height
        #expect(line < 24, "a call is one line until opened (\(line) pt)")
        #expect(card > line + 20, "an opened call shows its command and output below its line (\(card) pt)")
    }

    @Test func aClosedReasoningIsOneLineThatOpensBelowIt() {
        var reply = TranscriptItem(id: "a", role: .assistant, text: "The answer.")
        reply.reasoning = "Weighing the options."
        let closed = host(ReasoningFold(item: reply))
        let open = host(ReasoningFold(item: reply, isExpanded: true))
        #expect(closed.fittingSize.height < 24, "closed: \(closed.fittingSize.height) pt")
        #expect(!texts(in: closed).contains { $0.contains("Weighing") })
        #expect(texts(in: open).contains { $0.contains("Weighing") })
    }
}
