import Foundation
import HermesProtocol
import Testing

@testable import HermesKit

// Regression tests for the third review of the paged transcript (fix round 4).
// They use only API the previous round already had, so they also build against it.
// The user writes mostly in Chinese: CJK text is a first-class case here.

private func event(_ type: String, _ payload: JSONValue? = nil) -> GatewayEvent {
    GatewayEvent(type: type, sessionID: "sid-1", payload: payload)
}

private func user(_ id: Int, _ text: String) -> StoredMessage {
    StoredMessage(id: id, role: "user", content: .string(text))
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
/// `inflight.assistant` is every delta of the turn so far, joined with no separator
/// (`tui_gateway/session_history.py:402-410`).
private func running(user: String, assistant: String) throws -> Transcript {
    Transcript(snapshot: try liveAck(sid: "sid-1", key: "s1", count: 292,
                                     inflight: ["assistant": .string(assistant), "streaming": true,
                                                "user": .string(user)]).decode(LiveSessionSnapshot.self))
}

private func occurrences(_ transcript: Transcript, _ segment: String) -> Int {
    transcript.items.reduce(0) { $0 + $1.text.components(separatedBy: segment).count - 1 }
}

private func tools(_ transcript: Transcript) -> [TranscriptItem] { transcript.items.filter { $0.role == .tool } }

@Suite struct PagingRound4RegressionTests {
    // MARK: M1: a stored tool preamble joined to the next segment without a separator

    /// A Chinese reply repeated by a later bot turn stays (round 3's N1, in Chinese).
    @Test func aRepeatedChineseReplyAfterThePageStays() throws {
        var transcript = try idle()
        transcript.installLatestPage(plain(171...289) + [user(290, "在吗"), assistant(291, "在的")], hasOlder: true)
        transcript.apply(event("message.start"))
        transcript.apply(event("message.delta", ["text": "在的"]))
        transcript.apply(event("message.complete", completePayload("在的", rows: [292, 293])))
        #expect(occurrences(transcript, "在的") == 2)
        expectWellFormed(transcript)
    }

    // MARK: S1: item ids stay unique

    /// Round 3's N3 scenario: the live row of a reused call id must not repeat the stored row's id.
    @Test func aReusedCallIDNeverRepeatsAnItemID() throws {
        var transcript = try idle()
        transcript.installLatestPage(plain(172...288) + [
            user(289, "q"), assistant(290, "Looking.", call: "call_0"), tool(291, call: "call_0"),
        ], hasOlder: true)
        transcript.apply(event("message.start"))
        transcript.apply(event("tool.start", ["tool_id": "call_0", "name": "terminal", "context": "pwd"]))
        #expect(tools(transcript).count == 2)
        expectWellFormed(transcript)
    }

    // MARK: S2: tool-call ids reused by later turns and later rounds

    @Test func myOwnTurnReusingAStoredCallIDAddsARow() throws {
        var transcript = try idle()
        transcript.installLatestPage(plain(172...288) + [
            user(289, "q"), assistant(290, "Looking.", call: "call_0"), tool(291, call: "call_0"),
        ], hasOlder: true)
        transcript.appendUserPrompt("q2")
        transcript.apply(event("message.start"))
        transcript.apply(event("tool.start", ["tool_id": "call_0", "name": "terminal", "context": "pwd"]))
        transcript.apply(event("tool.complete", ["tool_id": "call_0", "name": "terminal", "summary": "/srv"]))
        #expect(tools(transcript).map(\.detail) == ["ls", "/srv"])
        #expect(tools(transcript).allSatisfy { !$0.isActive })
        expectWellFormed(transcript)
    }

    @Test func twoLaterTurnsReusingACallIDEachAddARow() throws {
        var transcript = try idle()
        transcript.installLatestPage(plain(172...288) + [
            user(289, "q"), assistant(290, "Looking.", call: "call_0"), tool(291, call: "call_0"),
        ], hasOlder: true)
        for (n, path) in ["/a", "/b"].enumerated() {
            transcript.apply(event("message.start"))
            transcript.apply(event("tool.start", ["tool_id": "call_0", "name": "terminal", "context": .string(path)]))
            transcript.apply(event("tool.complete", ["tool_id": "call_0", "name": "terminal", "summary": .string(path)]))
            transcript.apply(event("message.complete", completePayload("done", rows: [292 + 4 * n, 295 + 4 * n])))
        }
        #expect(tools(transcript).map(\.detail) == ["ls", "/a", "/b"])
        expectWellFormed(transcript)
    }

    /// One turn whose second tool round numbers its calls from 0 again.
    @Test func aSecondToolRoundRestartingAtCallZeroAddsARow() throws {
        var transcript = try idle()
        transcript.installLatestPage(plain(172...288) + [
            user(289, "q"), assistant(290, "Looking.", call: "call_0"), tool(291, call: "call_0"),
        ], hasOlder: true)
        transcript.apply(event("message.start"))
        transcript.apply(event("tool.start", ["tool_id": "call_0", "name": "terminal", "context": "round 1"]))
        transcript.apply(event("tool.complete", ["tool_id": "call_0", "name": "terminal", "summary": "one"]))
        transcript.apply(event("message.delta", ["text": "第二轮"]))
        transcript.apply(event("tool.start", ["tool_id": "call_0", "name": "terminal", "context": "round 2"]))
        #expect(tools(transcript).map(\.detail) == ["ls", "one", "round 2"])
        #expect(tools(transcript).map(\.isActive) == [false, false, true])
        transcript.apply(event("tool.complete", ["tool_id": "call_0", "name": "terminal", "summary": "two"]))
        #expect(tools(transcript).map(\.detail) == ["ls", "one", "two"])
        expectWellFormed(transcript)
    }

    // MARK: Nits: anchors that would hide content

    /// A Bot Mode turn running at open stored its prompt with other text; an older
    /// prompt of the user has exactly the `inflight.user` text.
    @Test func aStaleTextMatchDoesNotHideTheRunningReply() throws {
        var transcript = try running(user: "ping", assistant: "pong")
        transcript.installLatestPage(plain(174...289) + [user(290, "ping"), assistant(291, "pong"),
                                                         user(292, "[bot] ping")], hasOlder: true)
        #expect(occurrences(transcript, "pong") == 2)
        expectWellFormed(transcript)
    }

    /// Another client's submit landed just after the page was read, its `message.start`
    /// arrived before the page; the previous turn ended without a final reply.
    @Test func anUnansweredPreviousTurnDoesNotSwallowTheNextOne() throws {
        var transcript = try idle()
        transcript.apply(event("message.start"))
        transcript.apply(event("message.delta", ["text": "Let me check."]))
        transcript.installLatestPage(plain(173...289) + [
            user(290, "q"), assistant(291, "Let me check.", call: "call-A"), tool(292, call: "call-A"),
        ], hasOlder: true)
        #expect(occurrences(transcript, "Let me check.") == 2)
        transcript.apply(event("tool.start", ["tool_id": "call-B", "name": "terminal"]))
        #expect(occurrences(transcript, "Let me check.") == 2)
        expectWellFormed(transcript)
    }

    // MARK: Receipts without `final_assistant_row_id` (Bot Mode)

}
