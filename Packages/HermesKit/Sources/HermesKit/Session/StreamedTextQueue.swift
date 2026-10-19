import Foundation
import HermesProtocol

/// Streamed text (`message.delta`, `reasoning.delta`), shown a batch at a time as
/// Desktop shows it (`apps/desktop/src/app/session/hooks/use-message-stream/index.ts:339-437`).
///
/// The chat reads its transcript whole, so each change to it updates the whole chat.
/// Shown a delta at a time, a long reply kept the main thread busy for most of each
/// second, and scrolling stuttered. Desktop queues the deltas and shows them together,
/// at least 33 ms apart; the gap grows to three times what the last batch cost, at most
/// 250 ms, so the main thread stays mostly free for input however costly a batch gets.
/// The first delta of a stream shows at once.
///
/// Whoever owns the transcript shows the queued text (`flush`) before anything else
/// changes it, so events still apply in the order they came.
@MainActor
public final class StreamedTextQueue {
    /// Desktop's `STREAM_DELTA_FLUSH_MS` and `MAX_STREAM_FLUSH_GAP_MS`
    /// (`use-message-stream/utils.ts:112,118`).
    public nonisolated static let minimumGap = Duration.milliseconds(33)
    public nonisolated static let maximumGap = Duration.milliseconds(250)

    /// The gap from one batch to the next: three times what the last batch cost, within
    /// `minimumGap` and `maximumGap`.
    public nonisolated static func gap(afterCost cost: Duration) -> Duration {
        min(max(minimumGap, cost * 3), maximumGap)
    }

    private let show: @MainActor ([GatewayEvent]) -> Void
    private var queued: [GatewayEvent] = []
    private var batches: Task<Void, Never>?

    /// - Parameter show: applies a batch of deltas, oldest first, in one change.
    public init(show: @escaping @MainActor ([GatewayEvent]) -> Void) {
        self.show = show
    }

    /// No text waits to be shown.
    public var isEmpty: Bool { queued.isEmpty }

    /// Queues a delta, shown with the next batch.
    public func append(_ event: GatewayEvent) {
        queued.append(event)
        guard batches == nil else { return }
        batches = Task { [weak self] in await self?.showBatches() }
    }

    /// Shows the queued text now.
    public func flush() {
        guard !queued.isEmpty else { return }
        let events = queued
        queued = []
        show(events)
    }

    /// Shows the queued text, then waits out the gap, until nothing more is queued.
    /// A batch's cost is measured until the main thread next waits for a timer: by then
    /// the chat has drawn the change.
    private func showBatches() async {
        let clock = ContinuousClock()
        while !queued.isEmpty {
            let start = clock.now
            flush()
            try? await Task.sleep(for: .milliseconds(1))
            let cost = clock.now - start - .milliseconds(1)
            try? await Task.sleep(until: start + Self.gap(afterCost: cost), clock: clock)
        }
        batches = nil
    }
}
