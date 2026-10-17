import AppKit
import HermesKit
import SwiftUI
import Testing

/// The chat's scrolling around prompts (`promptScrolling`, `PromptRail.swift`) in a
/// scroll view built like `ChatView`'s: a send brings the chat to the bottom, and a
/// rail tick brings its prompt to the top.
@MainActor
@Suite(.serialized) struct PromptRailTests {
    @MainActor @Observable final class Chat {
        var transcript = Transcript()
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
            }
        }
    }

    @MainActor private final class UI {
        let chat = Chat()
        let window: NSWindow
        let host: NSView

        init(prompts: Int) {
            chat.transcript.installLatestPage([], hasOlder: false)
            for index in 0..<prompts { chat.transcript.appendUserPrompt("Prompt \(index)") }
            window = NSWindow(contentRect: .testArea(CGSize(width: 420, height: 400)),
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

        var scrollView: NSScrollView? {
            func find(_ view: NSView) -> NSScrollView? {
                (view as? NSScrollView) ?? view.subviews.lazy.compactMap(find).first
            }
            return find(host)
        }

        /// How far the visible part's top is below the content's top.
        var offsetFromTop: CGFloat? {
            guard let scroll = scrollView, let document = scroll.documentView else { return nil }
            let visible = scroll.contentView.bounds
            return document.isFlipped ? visible.minY : document.frame.height - visible.maxY
        }

        /// How much content is below the visible part.
        var remainingBelow: CGFloat? {
            guard let scroll = scrollView, let document = scroll.documentView else { return nil }
            let visible = scroll.contentView.bounds
            return document.isFlipped ? document.frame.height - visible.maxY : visible.minY
        }

        /// Clicks the rail's tick for `label` the way VoiceOver does.
        func pressTick(_ label: String) -> Bool {
            func search(_ element: NSObject) -> NSObject? {
                if element.accessibilityIdentifier() == PromptRail.accessibilityIdentifier,
                   element.accessibilityLabel() == label {
                    return element
                }
                for child in element.accessibilityChildren() ?? [] {
                    if let child = child as? NSObject, let found = search(child) { return found }
                }
                return nil
            }
            guard let tick = search(host) else { return false }
            let pressed = tick.accessibilityPerformPress()
            settle()
            return pressed
        }
    }

    @Test func theTicksPackCloserInALongChat() {
        #expect(PromptRail.spacing(count: 10, height: 400) == PromptRail.maxSpacing)
        #expect(PromptRail.spacing(count: 100, height: 400) == 4, "a long chat packs its ticks into the rail")
    }

    @Test func aTickScrollsToItsPromptAndASendScrollsBackDown() throws {
        let ui = UI(prompts: 30)
        defer { ui.close() }
        #expect(try #require(ui.remainingBelow) < 2, "the chat opens at the bottom")

        #expect(ui.pressTick("Prompt 10"), "no rail tick for Prompt 10")
        let expected = Harness.padding + 10 * (Harness.rowHeight + Harness.spacing)
        let offset = try #require(ui.offsetFromTop)
        #expect(abs(offset - expected) <= 4, "Prompt 10 is at \(offset), expected \(expected)")

        ui.chat.transcript.appendUserPrompt("Prompt 30")
        ui.settle()
        #expect(try #require(ui.remainingBelow) < 2, "the send left the chat scrolled up")

        // Again: a second send after a jump still comes down.
        #expect(ui.pressTick("Prompt 3"))
        #expect(try #require(ui.remainingBelow) > 100, "the tick did not scroll up")
        ui.chat.transcript.appendUserPrompt("Prompt 31")
        ui.settle()
        #expect(try #require(ui.remainingBelow) < 2, "the second send left the chat scrolled up")
    }

    @Test func aSendScrollsDownAfterTheUserScrolledUp() throws {
        let ui = UI(prompts: 30)
        defer { ui.close() }
        let scroll = try #require(ui.scrollView)
        let document = try #require(scroll.documentView)
        // As a scroll wheel would leave it: at the top.
        let top = document.isFlipped ? 0 : document.frame.height - scroll.contentView.bounds.height
        scroll.contentView.scroll(to: NSPoint(x: 0, y: top))
        scroll.reflectScrolledClipView(scroll.contentView)
        ui.settle()
        #expect(try #require(ui.offsetFromTop) < 2)

        ui.chat.transcript.appendUserPrompt("Prompt 30")
        ui.settle()
        #expect(try #require(ui.remainingBelow) < 2, "the send left the chat scrolled up")
    }
}
