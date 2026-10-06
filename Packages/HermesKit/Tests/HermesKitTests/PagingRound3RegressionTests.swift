import Foundation
import HermesProtocol
import Synchronization
import Testing

@testable import HermesKit

// Regression tests for the second review of the paged transcript (fix round 3).
// They use only API the previous round already had, so they also build against it.

private func event(_ type: String, _ payload: JSONValue? = nil) -> GatewayEvent {
    GatewayEvent(type: type, sessionID: "sid-1", payload: payload)
}

private func user(_ id: Int, _ text: String, hidden: Bool = false) -> StoredMessage {
    var row = StoredMessage(id: id, role: "user", content: .string(text))
    if hidden { row.displayKind = "hidden" }
    return row
}

/// An assistant row; with `call`, the tool-call round Hermes stores before the
/// tool runs (`agent/turn_tool_round.py:127-130`).
private func assistant(_ id: Int, _ text: String, call: String? = nil) -> StoredMessage {
    var row = StoredMessage(id: id, role: "assistant", content: .string(text))
    if let call {
        row.toolCalls = [["id": .string(call), "type": "function",
                          "function": ["name": "terminal", "arguments": #"{"command":"ls"}"#]]]
    }
    return row
}

private func tool(_ id: Int, call: String) -> StoredMessage {
    var row = StoredMessage(id: id, role: "tool", content: "output")
    row.toolCallID = call
    row.toolName = "terminal"
    return row
}

private func plain(_ range: ClosedRange<Int>) -> [StoredMessage] { range.map { storedRow(id: $0) } }

/// Nothing running at open; the history still to be read (`methods_session.py:949-967`).
private func idle() throws -> Transcript {
    Transcript(snapshot: try deferredAck(sid: "sid-1", key: "s1", count: 300).decode(LiveSessionSnapshot.self))
}

/// A turn running at open: the live-reuse ack (`server.py:3146-3186`, `methods_session.py:880-895`).
private func running(user: String, assistant: String) throws -> LiveSessionSnapshot {
    try liveAck(sid: "sid-1", key: "s1", count: 292,
                inflight: ["assistant": .string(assistant), "streaming": true, "user": .string(user)])
        .decode(LiveSessionSnapshot.self)
}

private func occurrences(_ transcript: Transcript, _ segment: String) -> Int {
    transcript.items.reduce(0) { $0 + $1.text.components(separatedBy: segment).count - 1 }
}

private func tools(_ transcript: Transcript) -> [TranscriptItem] { transcript.items.filter { $0.role == .tool } }

@Suite struct PagingRound3RegressionTests {
    // MARK: N1: turns that start after the page was read

    /// A Bot Chat turn delivered after the page (a bot DM, `session_notifications.py:~670`)
    /// repeats the previous reply. None of its rows can be in the page.
    @Test func aTurnStartedAfterThePageKeepsRepeatedText() throws {
        var transcript = try idle()
        transcript.installLatestPage(plain(171...289) + [user(290, "ping"), assistant(291, "pong")], hasOlder: true)
        transcript.apply(event("message.start"))
        transcript.apply(event("message.delta", ["text": "pong"]))
        #expect(occurrences(transcript, "pong") == 2)
        transcript.apply(event("message.complete", completePayload("pong", rows: [292, 293])))
        #expect(occurrences(transcript, "pong") == 2)
        expectWellFormed(transcript)
    }

    @Test func aTurnStartedAfterThePageKeepsRepeatedTextBeforeATool() throws {
        var transcript = try idle()
        transcript.installLatestPage(plain(173...289) + [
            user(290, "ping"), assistant(291, "Let me check.", call: "call-A"), tool(292, call: "call-A"),
            assistant(293, "4"),
        ], hasOlder: true)
        transcript.apply(event("message.start"))
        transcript.apply(event("message.delta", ["text": "Let me check."]))
        transcript.apply(event("tool.start", ["tool_id": "call-B", "name": "terminal"]))
        #expect(occurrences(transcript, "Let me check.") == 2)
        #expect(tools(transcript).count == 2)
        expectWellFormed(transcript)
    }

    /// The page was read just before another client's submit landed: the turn is
    /// live, but its prompt is not in the page. Position alone would anchor it to
    /// the previous turn, which already ended in a final reply.
    @Test func aTurnWhosePromptMissedThePageIsNotMatchedToThePreviousTurn() throws {
        var transcript = try idle()
        transcript.apply(event("message.start"))
        transcript.apply(event("message.delta", ["text": "pong"]))
        transcript.installLatestPage(plain(171...289) + [user(290, "ping"), assistant(291, "pong")], hasOlder: true)
        #expect(occurrences(transcript, "pong") == 2)
        transcript.apply(event("message.complete", completePayload("pong", rows: [292, 293])))
        #expect(occurrences(transcript, "pong") == 2)
        expectWellFormed(transcript)
    }

    /// The turn running at open (anchored by its echoed prompt): a stored segment
    /// that ends a reply only matches the whole live text.
    @Test func aStoredReplyIsNotTrimmedOffTheStartOfALongerLiveText() throws {
        var transcript = Transcript(snapshot: try running(user: "ping", assistant: "Sure thing, here it is."))
        transcript.installLatestPage(plain(173...289) + [user(290, "ping"), assistant(291, "Sure")], hasOlder: true)
        #expect(transcript.items.last?.text == "Sure thing, here it is.")
        expectWellFormed(transcript)
    }

    // MARK: N2: a foreign reply that was not streamed

    @Test func anUnstreamedForeignReplyIsShownEvenIfItRepeatsTheLastOne() throws {
        var transcript = try idle()
        transcript.installLatestPage(plain(171...289) + [user(290, "ping"), assistant(291, "pong")], hasOlder: true)
        transcript.apply(event("message.start"))
        transcript.apply(event("message.complete", completePayload("pong", rows: [292, 293])))
        #expect(occurrences(transcript, "pong") == 2)
        // Without a `message.start` either.
        transcript.apply(event("message.complete", completePayload("pong", rows: [294, 295])))
        #expect(occurrences(transcript, "pong") == 3)
        expectWellFormed(transcript)
    }

    // MARK: N3: tool-call ids repeated across turns

    /// Providers can number calls per response (`tools/mcp_tool_sampling.py:48`).
    @Test func aLaterTurnReusingACallIDAddsANewToolRow() throws {
        var transcript = try idle()
        transcript.installLatestPage(plain(172...288) + [
            user(289, "q"), assistant(290, "Looking.", call: "call_0"), tool(291, call: "call_0"),
        ], hasOlder: true)
        transcript.apply(event("message.start"))
        transcript.apply(event("tool.start", ["tool_id": "call_0", "name": "terminal", "context": "pwd"]))
        let rows = tools(transcript)
        #expect(rows.count == 2)
        #expect(rows.first?.isActive == false && rows.last?.isActive == true)
        #expect(rows.last?.detail == "pwd")
        transcript.apply(event("tool.complete", ["tool_id": "call_0", "name": "terminal", "summary": "/srv"]))
        #expect(tools(transcript).map(\.detail) == ["ls", "/srv"])
        expectWellFormed(transcript)
    }

    // MARK: N5: the hidden opening row at an exact page boundary

    @Test func theOpeningRowShowsWhenTheBeginningIsAnEmptyPage() {
        var transcript = Transcript()
        transcript.installLatestPage([user(1, "hi there", hidden: true)] + plain(2...120), hasOlder: true)
        transcript.prependOlderPage([], hasOlder: false)
        #expect(transcript.items.first?.text == "hi there")
        #expect(transcript.items.count == 120)
        expectWellFormed(transcript)
    }

}

/// Pages but ignores `order` and `offset`: always the oldest rows.
private struct RepeatingSource: SessionMessagesSource {
    func messagesPage(_ query: SessionMessagesQuery) async throws -> SessionMessagesPage {
        let page = (1...query.limit).map { storedRow(id: $0) }
        return SessionMessagesPage(messages: page, pagination: SessionMessagesPagination(
            limit: query.limit, offset: query.offset, order: nil, returned: page.count))
    }
}

/// A gateway that ignores `offset` leaves no state a retry could fix.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct PagingRound3ConnectionTests {
    @Test func anUnreadableHistoryOffersNoRetry() async throws {
        let transport = FakeTransport()
        let server = PagedServer(store: FakeMessageStore(count: 10))
        transport.serve(log: FrameLog(), server.handle)
        var configuration = GatewayClient.Configuration()
        configuration.heartbeatInterval = nil
        let connection = GatewayConnection(configuration: configuration)
        try await connection.connect(using: FakeConnector([transport], messages: RepeatingSource()))
        let session = try await connection.open(SessionSummary(id: "stored-1"))
        await session.historyTask?.value
        guard case .unavailable = session.historyLoad else {
            Issue.record("expected an unavailable history, got \(session.historyLoad)"); return
        }
        expectWellFormed(session.transcript)
    }
}
