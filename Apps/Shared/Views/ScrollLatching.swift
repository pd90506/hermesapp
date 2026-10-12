#if os(macOS)
import AppKit
import HermesKit

/// Keeps a scroll with the scroll view it started over (`ScrollLatch`). AppKit hands
/// each wheel event to the scroll view under the pointer, so scrolling the chat past a
/// tool call's diff box used to stop the chat and scroll the box; browsers, and so
/// Hermes Desktop, latch the gesture instead.
///
/// One local monitor sees every wheel event before its window does: a gesture's first
/// event picks the innermost scroll view under the pointer; a later event over a
/// different scroll view goes to that one directly and is not delivered.
@MainActor
enum ScrollLatching {
    private static var monitor: Any?
    private static var latch = ScrollLatch()
    private static weak var owner: NSScrollView?

    static func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
            // Local monitors run on the main thread, inside the app's event dispatch:
            // the event never leaves it.
            nonisolated(unsafe) let event = event
            nonisolated(unsafe) var routed: NSEvent?
            MainActor.assumeIsolated { routed = route(event, in: event.window) }
            return routed
        }
    }

    /// The event to deliver, or `nil` when it went to the gesture's scroll view here.
    static func route(_ event: NSEvent, in window: NSWindow?) -> NSEvent? {
        guard let window, let content = window.contentView else { return event }
        let kind: ScrollLatch.Event
        if event.phase.contains(.began) || event.phase.contains(.mayBegin) {
            kind = .began
        } else if event.phase.isEmpty && event.momentumPhase.isEmpty {
            kind = .wheel
        } else {
            kind = .continued
        }
        let starts = latch.startsGesture(kind, at: event.timestamp)
        // An event made without a window (tests) carries a screen location.
        let point = event.window == nil ? window.convertPoint(fromScreen: event.locationInWindow) : event.locationInWindow
        let under = scrollView(at: point, in: content)
        if starts || owner?.window !== window {
            owner = under
            return event
        }
        guard let owner, owner !== under else { return event }
        owner.scrollWheel(with: event)
        return nil
    }

    /// The innermost scroll view under `point` (window coordinates).
    static func scrollView(at point: NSPoint, in content: NSView) -> NSScrollView? {
        let local = content.superview.map { $0.convert(point, from: nil) } ?? point
        var view = content.hitTest(local)
        while let current = view {
            if let scroll = current as? NSScrollView { return scroll }
            view = current.superview
        }
        return nil
    }

    #if DEBUG
    /// Tests only: the scroll view the current gesture belongs to.
    static var currentOwner: NSScrollView? { owner }

    /// Tests only: forget the current gesture.
    static func reset() {
        latch = ScrollLatch()
        owner = nil
    }
    #endif
}
#endif
