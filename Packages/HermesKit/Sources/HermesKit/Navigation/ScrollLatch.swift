import Foundation

/// Which scroll gesture a wheel event belongs to, so a scroll stays with the view it
/// started over, as a browser latches it (Hermes Desktop's nested diff boxes,
/// `apps/desktop/src/components/chat/diff-lines.tsx:62-67`): scrolling the chat past
/// a diff box keeps scrolling the chat, and only a scroll that starts over the box
/// scrolls the box.
///
/// - A trackpad or Magic Mouse gesture starts with its `began` phase; its changes, its
///   end and the momentum after it belong to it.
/// - A plain wheel has no phases: a tick starts a new gesture when the last one was
///   more than `gap` ago.
public struct ScrollLatch: Sendable {
    public enum Event: Sendable {
        /// The gesture's `began` (or `mayBegin`) phase.
        case began
        /// A later phase of the gesture, or its momentum.
        case continued
        /// A wheel tick with no phase.
        case wheel
    }

    /// The longest pause between ticks of one plain-wheel scroll.
    public var gap: TimeInterval
    private var last: TimeInterval?

    public init(gap: TimeInterval = 0.3) {
        self.gap = gap
    }

    /// Whether `event`, at `time` (seconds, any monotonic clock), starts a new gesture.
    public mutating func startsGesture(_ event: Event, at time: TimeInterval) -> Bool {
        defer { last = time }
        switch event {
        case .began: return true
        case .continued: return last == nil
        case .wheel: return last.map { time - $0 > gap } ?? true
        }
    }
}
