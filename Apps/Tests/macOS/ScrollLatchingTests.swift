import AppKit
import HermesKit
import SwiftUI
import Testing

/// A scroll stays with the scroll view it started over (`ScrollLatching`): the chat
/// keeps scrolling when the pointer crosses a diff box, and the box scrolls only for a
/// scroll that starts over it.
@MainActor
@Suite(.serialized) struct ScrollLatchingTests {
    @MainActor final class Recording: NSScrollView {
        var received = 0
        override func scrollWheel(with event: NSEvent) { received += 1 }
    }

    /// A chat-like outer scroll view with a diff-box-like scroll view inside it.
    @MainActor final class Nested {
        let window: NSWindow
        let outer = Recording(frame: NSRect(x: 0, y: 0, width: 300, height: 300))
        let inner = Recording(frame: NSRect(x: 20, y: 100, width: 260, height: 100))

        init() {
            window = NSWindow(contentRect: .testArea(CGSize(width: 300, height: 300)),
                              styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            let page = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 2000))
            outer.documentView = page
            inner.documentView = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 1000))
            page.addSubview(inner)
            window.contentView = outer
            window.showInTestArea()
            ScrollLatching.reset()
        }

        var outsidePoint: NSPoint { window.convertPoint(toScreen: NSPoint(x: 150, y: 40)) }
        var insidePoint: NSPoint { window.convertPoint(toScreen: inner.convert(NSPoint(x: 100, y: 50), to: nil)) }

        /// A pixel scroll at `point` (screen coordinates), `phase` 0 for a plain wheel
        /// tick, 1 began, 2 changed (`CGScrollPhase`).
        func scroll(at point: NSPoint, phase: Int64, time: TimeInterval) -> NSEvent? {
            let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: -10, wheel2: 0, wheel3: 0)!
            let primary = NSScreen.screens.first?.frame.height ?? 0
            event.location = CGPoint(x: point.x, y: primary - point.y)
            event.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
            event.timestamp = CGEventTimestamp(time * 1_000_000_000)
            return ScrollLatching.route(NSEvent(cgEvent: event)!, in: window)
        }

        func close() { window.close() }
    }

    /// The chat as SwiftUI builds it: a scroll view holding an opened edit whose diff
    /// box scrolls. A scroll started beside the box stays with the chat over the box.
    @Test func theChatKeepsAScrollThatCrossesADiffBox() throws {
        var edit = TranscriptItem(id: "edit", role: .tool, text: "")
        edit.toolName = "patch"
        var tool = ToolActivity(toolID: "edit", name: "patch", phase: .complete)
        tool.inlineDiff = (1...200).map { "+line \($0)" }.joined(separator: "\n")
        edit.tool = tool
        let host = NSHostingView(rootView: ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(0..<30) { Text("Message \($0)") }
                ToolMessageContent(item: edit)
                ForEach(30..<60) { Text("Message \($0)") }
            }
            .padding()
        }
        .defaultScrollAnchor(.center))
        let window = NSWindow(contentRect: .testArea(CGSize(width: 400, height: 400)),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.showInTestArea()
        defer { window.close() }
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(mode: .default, before: Date())
        ScrollLatching.reset()

        func scrollViews(in view: NSView) -> [NSScrollView] {
            ((view as? NSScrollView).map { [$0] } ?? []) + view.subviews.flatMap(scrollViews)
        }
        let all = scrollViews(in: host)
        let chat = try #require(all.first, "no scroll view for the chat")
        let box = try #require(all.first { $0 !== chat && $0.isDescendant(of: chat) }, "no scroll view for the diff box")
        let inBox = window.convertPoint(toScreen: box.convert(NSPoint(x: box.bounds.midX, y: box.bounds.midY), to: nil))
        let beside = window.convertPoint(toScreen: NSPoint(x: 390, y: 20))

        func scroll(at point: NSPoint, phase: Int64, time: TimeInterval) -> NSEvent? {
            let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: -10, wheel2: 0, wheel3: 0)!
            let primary = NSScreen.screens.first?.frame.height ?? 0
            event.location = CGPoint(x: point.x, y: primary - point.y)
            event.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
            event.timestamp = CGEventTimestamp(time * 1_000_000_000)
            return ScrollLatching.route(NSEvent(cgEvent: event)!, in: window)
        }
        #expect(ScrollLatching.scrollView(at: window.convertPoint(fromScreen: inBox), in: host) === box,
                "the box's scroll view is not the one under the pointer")
        #expect(scroll(at: beside, phase: 1, time: 40) != nil)
        #expect(ScrollLatching.currentOwner === chat, "the gesture belongs to \(String(describing: ScrollLatching.currentOwner))")
        #expect(scroll(at: inBox, phase: 2, time: 40.02) == nil, "the box took the chat's scroll")
    }

    @Test func aScrollStartedOverTheChatStaysWithTheChat() {
        let ui = Nested()
        defer { ui.close() }
        #expect(ui.scroll(at: ui.outsidePoint, phase: 1, time: 10) != nil, "the first event is delivered as usual")
        for step in 1...5 {
            #expect(ui.scroll(at: ui.insidePoint, phase: 2, time: 10 + Double(step) * 0.016) == nil,
                    "an event over the box went to the box")
        }
        #expect(ui.outer.received == 5)
        #expect(ui.inner.received == 0)
    }

    @Test func aScrollStartedOverTheBoxScrollsTheBox() {
        let ui = Nested()
        defer { ui.close() }
        #expect(ui.scroll(at: ui.insidePoint, phase: 1, time: 20) != nil)
        #expect(ui.scroll(at: ui.insidePoint, phase: 2, time: 20.02) != nil, "the box's own gesture is delivered to it")
        #expect(ui.outer.received == 0)
    }

    @Test func wheelTicksLatchUntilTheyPause() {
        let ui = Nested()
        defer { ui.close() }
        #expect(ui.scroll(at: ui.outsidePoint, phase: 0, time: 30) != nil)
        #expect(ui.scroll(at: ui.insidePoint, phase: 0, time: 30.1) == nil, "the next tick stays with the chat")
        #expect(ui.outer.received == 1)
        #expect(ui.scroll(at: ui.insidePoint, phase: 0, time: 31) != nil, "after a pause, a tick over the box scrolls it")
    }
}
