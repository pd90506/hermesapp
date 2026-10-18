import AppKit
import HermesKit
import HermesProtocol
import SwiftUI
import Testing

/// The chat's scroll view (`ChatView`), built from its own pieces: the transcript stack
/// (`TranscriptStack`) with real replies in it, and its scroll anchors
/// (`chatScrollAnchoring`).
///
/// Scrolling goes through SwiftUI (`ScrollPosition`), as in `PromptRailTests`: wheel
/// events sent here do not scroll the chat (measured 2026-10-17).
@MainActor
@Suite(.serialized) struct ChatScrollingTests {
    @MainActor @Observable final class Chat {
        var items: [TranscriptItem] = []
        var position = ScrollPosition(idType: String.self)
        /// How tall the last row's extra part is: a fold opening, or a reply streaming.
        var extra: CGFloat = 0
        let anchor = ChatScrollAnchor()
    }

    private struct Harness: View {
        @Bindable var chat: Chat

        var body: some View {
            ScrollView {
                TranscriptStack { rows }
                    .padding()
            }
            .chatScrollAnchoring(chat.anchor)
            .scrollPosition($chat.position)
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
            chat.position.scrollTo(y: y)
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
        // As a fold's button does.
        ui.chat.anchor.hold { ui.chat.extra = 300 }
        ui.settle(20)
        let after = try #require(ui.shownTop)
        #expect(abs(after - top) < 1, "the rows on screen moved from \(top) to \(after)")
        #expect(try #require(ui.remainingBelow) > 250, "the fold opened below the screen")
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

    /// Scrolled up, the rows on screen stay where they are as the chat grows below them,
    /// a fold opening or a reply streaming alike.
    @Test func scrolledUpTheRowsOnScreenStayPut() throws {
        let ui = UI(turns: 20)
        defer { ui.close() }
        ui.scroll(toY: 400)
        let top = try #require(ui.shownTop)
        #expect(try #require(ui.remainingBelow) > 200, "scrolled up")
        ui.chat.extra = 300
        ui.settle()
        let after = try #require(ui.shownTop)
        #expect(abs(after - top) < 1, "the rows on screen moved from \(top) to \(after)")
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

    @Test func anOpenedRunShowsItsReasoningWithoutAFoldOfItsOwn() {
        var commentary = TranscriptItem(id: "c", role: .assistant, text: "")
        commentary.reasoning = "Thinking about which command to run."
        let run = ToolRun(id: "run", items: [commentary, Self.tool("t1", command: "echo alpha"),
                                              Self.tool("t2", command: "echo beta")], isLive: false)
        let view = host(ToolRunView(run: run, isExpanded: true) { item in
            if item.role == .tool {
                ToolMessageContent(item: item)
            } else {
                AssistantMessageContent(item: item) {}
            }
        })
        #expect(texts(in: view).contains { $0.contains("Thinking about which command") },
                "the reasoning is shown in the opened run")
        // Outside a run the same reply keeps its reasoning closed.
        #expect(!texts(in: host(AssistantMessageContent(item: commentary) {})).contains { $0.contains("Thinking") })
    }

    /// An edit's diff opens below its line by default; inside a run, nothing opens below
    /// a call's line (its detail is a popover).
    @Test func aCallInARunNeverOpensBelowItsLine() {
        let edit = ToolRowTests.edit(lines: 3)
        let alone = host(ToolMessageContent(item: edit)).fittingSize.height
        let inRun = host(ToolMessageContent(item: edit).environment(\.isInToolRun, true)).fittingSize.height
        #expect(alone > 40, "an edit with a diff opens by default (\(alone) pt)")
        #expect(inRun < 24, "a call in a run is one line, not \(inRun) pt")
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
