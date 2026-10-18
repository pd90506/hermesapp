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

    @MainActor @Observable final class Column {
        var extra: CGFloat = 0
        var row: CGRect = .zero
    }

    private struct ColumnHarness: View {
        @Bindable var column: Column
        @State private var width: CGFloat?

        var body: some View {
            ScrollView {
                VStack(spacing: 0) {
                    Color.gray.frame(height: 40)
                        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { column.row = $0 }
                    Color.clear.frame(height: column.extra)
                }
                .steadyColumn(maxWidth: 360, sideRoom: 20, in: width)
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        }
    }

    /// Content outgrowing the screen brings a scroller where a mouse is connected; the
    /// chat's column keeps its place and width (`steadyColumn`). Centered in the content
    /// instead, it moved and rewrapped as a fold opened or closed (the user, 2026-10-18).
    @Test func theColumnStaysPutWhenAScrollerShows() throws {
        let column = Column()
        let window = NSWindow(contentRect: .testArea(CGSize(width: 520, height: 300)),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let host = NSHostingView(rootView: ColumnHarness(column: column))
        window.contentView = host
        window.showInTestArea()
        func find(_ view: NSView) -> NSScrollView? {
            (view as? NSScrollView) ?? view.subviews.lazy.compactMap(find).first
        }
        func settle() { for _ in 0..<10 { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) } }
        settle()
        let scroll = try #require(find(host))
        // As with a mouse connected, whatever this Mac's setting.
        scroll.scrollerStyle = .legacy
        settle()
        let fits = column.row
        column.extra = 2_000
        settle()
        let scrolls = column.row
        #expect(scroll.scrollerStyle == .legacy && scroll.verticalScroller?.isHidden == false,
                "no scroller showed: the check would not mean anything")
        #expect(abs(scrolls.minX - fits.minX) < 0.5 && abs(scrolls.width - fits.width) < 0.5,
                "the column moved from \(fits) to \(scrolls) when the scroller showed")
        #expect(abs(fits.midX - 260) < 1, "the column is centered in the scroll view (\(fits.midX))")
    }
}

/// The chat's folds: a turn's work, its groups and steps, reasoning, a call.
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

    static func work(live: Bool = false) -> TurnWork {
        var thinking = TranscriptItem(id: "r1", role: .assistant, text: "")
        thinking.reasoning = "Checking both commands.\nThen the table."
        let steps: [WorkStep] = [.think(thinking), .tool(tool("t1", command: "echo alpha")),
                                 .tool(tool("t2", command: "echo beta"))]
        return TurnWork(id: "work", items: [thinking] + steps.dropFirst().map(\.item),
                        entries: [.group(StepGroup(id: "g", steps: steps, isLive: live))], isLive: live,
                        startedAt: Date(timeIntervalSince1970: 0), endedAt: Date(timeIntervalSince1970: 45))
    }

    /// The three layers the user asked for: a settled turn's work is one line ("Completed
    /// in 45s") until opened; opened, its groups are a line each; a group opened lists its
    /// steps a line each; a step opens in place below its line into its card.
    @Test func aTurnsWorkOpensLayerByLayer() {
        let work = Self.work()
        let closed = host(TurnWorkView(work: work) { _ in EmptyView() }).fittingSize.height
        let opened = host(TurnWorkView(work: work, isExpanded: true) { _ in EmptyView() }).fittingSize.height
        #expect(closed < 30, "a settled turn's work is one line and its rule, not \(closed) pt")
        #expect(opened > closed + 12 && opened < closed + 40, "opened, the work shows its one group line (\(opened) pt)")

        let group = StepGroup(id: "g", steps: [.tool(Self.tool("t1", command: "echo alpha")),
                                               .tool(Self.tool("t2", command: "echo beta"))], isLive: false)
        let groupLine = host(StepGroupView(group: group)).fittingSize.height
        let groupOpen = host(StepGroupView(group: group, isExpanded: true)).fittingSize.height
        #expect(groupLine < 24, "a group is one line until opened (\(groupLine) pt)")
        #expect(groupOpen > groupLine * 2.5, "an opened group shows each step (\(groupOpen) pt)")

        let step = WorkStep.tool(Self.tool("t1", command: "echo alpha"))
        let line = host(WorkStepView(step: step)).fittingSize.height
        let card = host(WorkStepView(step: step, isExpanded: true)).fittingSize.height
        #expect(line < 24, "a step is one line until opened (\(line) pt)")
        #expect(card > line + 40, "an opened step shows its card: the command, a rule, the output (\(card) pt)")
    }

    /// While the turn works, its work is open one layer: its group lines show, not their
    /// steps (the user, 2026-10-18).
    @Test func liveWorkShowsItsGroupsClosed() {
        let live = host(TurnWorkView(work: Self.work(live: true)) { _ in EmptyView() }).fittingSize.height
        let settled = host(TurnWorkView(work: Self.work()) { _ in EmptyView() }).fittingSize.height
        let opened = host(TurnWorkView(work: Self.work(), isExpanded: true) { _ in EmptyView() }).fittingSize.height
        #expect(live > settled + 12, "live work shows its group line (\(live) pt vs \(settled) pt)")
        #expect(abs(live - opened) < 4, "live work opens one layer, as an opened settled one (\(live) vs \(opened) pt)")
    }

    /// A working group's line is its newest step, changing as each starts; settled, it
    /// reads what its calls did.
    @Test func aWorkingGroupShowsItsNewestStep() {
        var skill = Self.tool("t0", command: "")
        skill.toolName = "skill_view"
        skill.tool?.name = "skill_view"
        skill.tool?.args = ["name": "hermes-agent"]
        var running = Self.tool("t2", command: "git status")
        running.isActive = true
        let steps: [WorkStep] = [.tool(skill), .tool(Self.tool("t1", command: "ls")), .tool(running)]
        let live = StepGroup(id: "g", steps: steps, isLive: true)
        #expect(StepGroupView.liveStep(of: live)?.id == "t2")
        #expect(StepGroupView.liveStep(of: StepGroup(id: "g", steps: Array(steps.prefix(1)), isLive: true))?.summary
            == "hermes-agent")
        let settled = StepGroup(id: "g", steps: steps, isLive: false)
        #expect(StepGroupView.liveStep(of: settled) == nil)
        #expect(settled.title == "Called tools, ran commands")
        let line = host(StepGroupView(group: live)).fittingSize.height
        #expect(line < 24, "a working group is still one line (\(line) pt)")
    }

    /// A long command's output scrolls inside its card rather than growing the chat.
    @Test func aStepsOutputScrollsPastAFewLines() {
        var item = Self.tool("t1", command: "seq 200")
        item.tool?.output = (1...200).map(String.init).joined(separator: "\n")
        let card = host(WorkStepCard(step: .tool(item))).fittingSize.height
        #expect(card < 320, "the output scrolls inside the card (\(card) pt)")
    }

    /// A call outside a turn's work (a card tool) is still its own line that opens in place.
    @Test func aCallOpensBelowItsLine() {
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
