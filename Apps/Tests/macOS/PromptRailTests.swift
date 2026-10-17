import AppKit
import HermesKit
import SwiftUI
import Testing

/// The chat's scrolling around prompts (`promptScrolling`, `PromptRail.swift`) in a
/// scroll view built like `ChatView`'s: a tick's jump brings its prompt on screen, and
/// a send brings the chat back to the bottom.
///
/// The jump goes through `PromptRail.scroll`, what a tick's button runs: a click
/// synthesized here does not reach a SwiftUI button (measured 2026-10-17), so the click
/// itself is checked by hand. So is a send after scrolling up with the wheel: wheel
/// events sent here do not scroll the chat, and a clip view moved behind SwiftUI's back
/// went back to the bottom within half a second (VM, 2026-10-17). The jump is SwiftUI's
/// own scroll, and the send after it is the same path.
@MainActor
@Suite(.serialized) struct PromptRailTests {
    @MainActor @Observable final class Chat {
        var transcript = Transcript()
        /// The prompt to jump to, as its tick would.
        var jump: PromptMark?
    }

    /// `ChatView`'s scroll view, with rows of a fixed height so positions are known.
    private struct Harness: View {
        let chat: Chat
        static let rowHeight: CGFloat = 60
        static let spacing: CGFloat = 12
        static let padding: CGFloat = 16

        var body: some View {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: Self.spacing) {
                        TranscriptMessages(transcript: chat.transcript) { item, _ in
                            Text(item.text).frame(height: Self.rowHeight)
                        } requests: {
                            EmptyView()
                        }
                    }
                    .padding(Self.padding)
                    .padding(.trailing, PromptRail.width)
                }
                .defaultScrollAnchor(.bottom)
                .promptScrolling(transcript: chat.transcript, proxy: proxy)
                .onChange(of: chat.jump) {
                    if let mark = chat.jump { PromptRail.scroll(to: mark, in: chat.transcript, with: proxy) }
                }
            }
        }

        /// Where prompt `index`'s row starts in the content.
        static func top(of index: Int) -> CGFloat { padding + CGFloat(index) * (rowHeight + spacing) }
    }

    @MainActor private final class UI {
        static let size = CGSize(width: 420, height: 400)
        let chat = Chat()
        let window: NSWindow
        let host: NSView

        init(prompts: Int) {
            chat.transcript.installLatestPage([], hasOlder: false)
            for index in 0..<prompts { chat.transcript.appendUserPrompt("Prompt \(index)") }
            window = NSWindow(contentRect: .testArea(Self.size),
                              styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            host = NSHostingView(rootView: Harness(chat: chat))
            window.contentView = host
            window.showInTestArea()
            settle()
        }

        func close() { window.close() }

        func settle() {
            for _ in 0..<10 { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        }

        /// Runs the loop until `condition` holds, for at most `timeout` seconds. Under
        /// load (the full VM run) a scroll can take more than `settle`'s 0.2 s to land.
        @discardableResult
        func waitFor(timeout: TimeInterval = 2, _ condition: () -> Bool) -> Bool {
            let deadline = Date().addingTimeInterval(timeout)
            while !condition() {
                if Date() > deadline { return false }
                RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            }
            return true
        }

        var scrollView: NSScrollView? {
            func find(_ view: NSView) -> NSScrollView? {
                (view as? NSScrollView) ?? view.subviews.lazy.compactMap(find).first
            }
            return find(host)
        }

        /// The visible part of the content, measured from the content's top.
        var visible: ClosedRange<CGFloat>? {
            guard let scroll = scrollView, let document = scroll.documentView else { return nil }
            let bounds = scroll.contentView.bounds
            let top = document.isFlipped ? bounds.minY : document.frame.height - bounds.maxY
            return top...(top + bounds.height)
        }

        /// How much content is below the visible part.
        var remainingBelow: CGFloat? {
            guard let scroll = scrollView, let document = scroll.documentView else { return nil }
            let bounds = scroll.contentView.bounds
            return document.isFlipped ? document.frame.height - bounds.maxY : bounds.minY
        }

        func jump(to index: Int) {
            chat.jump = chat.transcript.promptMarks[index]
            settle()
            waitFor { (remainingBelow ?? 0) > 100 }
        }

        /// Sends `text` and waits for the chat to reach the bottom (or the timeout).
        func send(_ text: String) {
            chat.transcript.appendUserPrompt(text)
            settle()
            waitFor { (remainingBelow ?? .infinity) < 2 }
        }
    }

    @Test func theTicksPackCloserInALongChat() {
        #expect(PromptRail.spacing(count: 10, height: 400) == PromptRail.maxSpacing)
        #expect(PromptRail.spacing(count: 100, height: 400) == 4, "a long chat packs its ticks into the rail")
    }

    @Test func thePanelOpensLevelWithTheTopTickInsideTheRail() {
        let height: CGFloat = 400
        for count in [3, 10, 100] {
            let spacing = PromptRail.spacing(count: count, height: height)
            let ticksTop = (height - spacing * CGFloat(count)) / 2
            let panel = min(PromptRail.panelMaxHeight, height, CGFloat(count) * PromptRail.panelRowEstimate + 16)
            let top = PromptRail.panelTop(count: count, height: height)
            #expect(top >= 0 && top + panel <= height + 0.5, "count \(count): top \(top)")
            if ticksTop + panel <= height {
                #expect(abs(top - ticksTop) < 0.5, "count \(count): the panel opens at \(top), the ticks start at \(ticksTop)")
            }
        }
        #expect(PromptRail.panelTop(count: 100, height: height) == 0, "a full rail's panel opens at its top")
    }

    @Test func aJumpBringsItsPromptOnScreenAndASendScrollsBackDown() throws {
        let ui = UI(prompts: 30)
        defer { ui.close() }
        #expect(try #require(ui.remainingBelow) < 2, "the chat opens at the bottom")

        ui.jump(to: 10)
        let shown = try #require(ui.visible)
        #expect(shown.contains(Harness.top(of: 10)), "Prompt 10 starts at \(Harness.top(of: 10)), the chat shows \(shown)")
        #expect(try #require(ui.remainingBelow) > 100, "the jump did not scroll up")

        ui.send("Prompt 30")
        #expect(try #require(ui.remainingBelow) < 2, "the send left the chat scrolled up")

        // Again: a second send after a jump still comes down.
        ui.jump(to: 3)
        #expect(try #require(ui.remainingBelow) > 100, "the jump did not scroll up")
        ui.send("Prompt 31")
        #expect(try #require(ui.remainingBelow) < 2, "the second send left the chat scrolled up")
    }
}
