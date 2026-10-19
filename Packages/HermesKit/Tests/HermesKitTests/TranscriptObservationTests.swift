import Foundation
@testable import HermesKit
import HermesProtocol
import Observation
import Testing

/// The chat reads `ChatSession.transcript` whole: each change to it updates the whole
/// chat, so an event that changes nothing must leave it alone.
@MainActor
@Suite struct TranscriptObservationTests {
    /// Set from an observation's `onChange`, which runs synchronously on the thread that
    /// changes the property: here always the main actor, which reads it afterwards.
    private final class Flag: @unchecked Sendable {
        var isSet = false
    }

    private func event(_ type: String, _ payload: [String: JSONValue] = [:]) -> GatewayEvent {
        GatewayEvent(type: type, sessionID: "sid-1", payload: .object(payload))
    }

    /// Whether `change` tells the transcript's observers it changed.
    private func notifies(_ session: ChatSession, _ change: () -> Void) -> Bool {
        let flag = Flag()
        withObservationTracking { _ = session.transcript } onChange: { flag.isSet = true }
        change()
        return flag.isSet
    }

    @Test func anEventThatChangesNothingLeavesTheTranscriptAlone() {
        let session = ChatSession(snapshot: LiveSessionSnapshot(sessionID: "sid-1", messages: [], running: false),
                                  title: nil, connection: nil)
        session.apply(event("message.start"))
        // The wait line's frames (`tui_gateway/agent_callbacks.py:117-123`): the first one
        // that explains the wait is shown, the same frame again changes nothing.
        let wait = event("thinking.delta", ["text": "⏳ Waiting on provider"])
        #expect(notifies(session) { session.apply(wait) })
        #expect(session.transcript.waiting?.hint == "⏳ Waiting on provider")
        #expect(!notifies(session) { session.apply(wait) })
        #expect(!notifies(session) { session.apply(wait) })

        let status = event("status.update", ["kind": "compacting", "text": "Compacting context…"])
        #expect(notifies(session) { session.apply(status) })
        #expect(!notifies(session) { session.apply(status) })

        #expect(notifies(session) { session.apply(event("message.delta", ["text": "Hello"])) })
        #expect(notifies(session) { session.apply(event("message.delta", ["text": " there"])) })
        #expect(session.transcript.items.last?.text == "Hello there")
    }

    private func session(coalescing: Bool) -> ChatSession {
        let session = ChatSession(snapshot: LiveSessionSnapshot(sessionID: "sid-1", messages: [], running: false),
                                  title: nil, connection: nil)
        session.coalescesStreamedText = coalescing
        return session
    }

    /// Records when a session's transcript changes: each change it is told of, until it
    /// looks again on the next turn of the main actor.
    @MainActor private final class ChangeLog {
        let session: ChatSession
        var times: [ContinuousClock.Instant] = []

        init(_ session: ChatSession) {
            self.session = session
            track()
        }

        func track() {
            withObservationTracking { _ = session.transcript } onChange: { [weak self] in
                Task { @MainActor in
                    self?.times.append(.now)
                    self?.track()
                }
            }
        }
    }

    /// Streams `count` deltas as fast as the main actor takes them, for 0.3 s or more,
    /// and records the transcript's changes until they all show.
    private func stream(_ count: Int, coalescing: Bool) async -> (text: String, expected: String, changes: ChangeLog) {
        let session = session(coalescing: coalescing)
        session.apply(event("message.start"))
        let log = ChangeLog(session)
        let deltas = (0..<count).map { "word\($0) " }
        for delta in deltas {
            session.apply(event("message.delta", ["text": .string(delta)]))
            try? await Task.sleep(for: .milliseconds(300 / count))
        }
        _ = await eventually { session.transcript.items.last?.text == deltas.joined() }
        try? await Task.sleep(for: .milliseconds(10))
        return (session.transcript.items.last?.text ?? "", deltas.joined(), log)
    }

    @Test(.timeLimit(.minutes(1))) func streamedTextShowsABatchAtATime() async {
        let batched = await stream(60, coalescing: true)
        #expect(batched.text == batched.expected)
        let times = batched.changes.times
        #expect(times.count >= 2, "the first delta shows at once, the rest after it")
        // No two batches closer than Desktop's floor (a little early for the timer's slack).
        let gaps = zip(times.dropFirst(), times).map { $0 - $1 }
        #expect(gaps.allSatisfy { $0 >= .milliseconds(25) }, "\(gaps)")
        // The count is right: a delta at a time is a change each, or close to it.
        let each = await stream(60, coalescing: false)
        #expect(each.changes.times.count > 30, "\(each.changes.times.count) changes for 60 deltas")
        #expect(times.count < each.changes.times.count / 2)
    }

    @Test func otherChangesComeAfterTheTextBeforeThem() {
        let session = session(coalescing: true)
        session.apply(event("message.start"))
        session.apply(event("message.delta", ["text": "Hello"]))
        session.apply(event("message.delta", ["text": " there"]))
        #expect(session.transcript.items.last?.text != "Hello there", "still queued")
        // A local row lands after the text.
        session.appendLocalNote("A note")
        #expect(session.transcript.items.map(\.text).suffix(2) == ["Hello there", "A note"])
        // An event lands after the text too.
        session.apply(event("message.delta", ["text": "More"]))
        session.apply(event("message.complete", ["text": "More", "status": "complete"]))
        #expect(session.transcript.items.contains { $0.role == .assistant && $0.text == "More" })
        #expect(!session.transcript.isRunning)
    }

    @Test func aDeltaShowsAtOnceWithoutCoalescing() {
        let session = session(coalescing: false)
        session.apply(event("message.start"))
        session.apply(event("message.delta", ["text": "Hello"]))
        #expect(session.transcript.items.last?.text == "Hello")
    }

    @Test func theGapIsThreeTimesTheCostWithinDesktopsBounds() {
        #expect(StreamedTextQueue.gap(afterCost: .zero) == .milliseconds(33))
        #expect(StreamedTextQueue.gap(afterCost: .milliseconds(20)) == .milliseconds(60))
        #expect(StreamedTextQueue.gap(afterCost: .milliseconds(200)) == .milliseconds(250))
    }
}
