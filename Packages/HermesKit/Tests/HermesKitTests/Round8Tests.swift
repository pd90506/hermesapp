import Foundation
import HermesProtocol
import Testing

@testable import HermesKit

// Issue #5, round 8: one round model (`Transcript.currentRound`, `docs/protocol.md` §5 "Rounds")
// for `message.interim`, `reasoning.available` and the items an `error` end leaves unstored.
// The round-7 review's R7-1 to R7-4.

private func event(_ type: String, _ payload: JSONValue? = nil) -> GatewayEvent {
    GatewayEvent(type: type, sessionID: "sid-1", payload: payload)
}

private func idle() -> Transcript {
    var transcript = Transcript()
    transcript.installLatestPage([storedRow(id: 1), storedRow(id: 2)], hasOlder: false)
    return transcript
}

private func normalized(_ text: String) -> String { text.split(whereSeparator: \.isWhitespace).joined(separator: " ") }

/// Items whose text is `text`, whitespace aside.
private func copies(_ transcript: Transcript, _ text: String) -> Int {
    transcript.items.filter { $0.role == .assistant && normalized($0.text) == normalized(text) }.count
}

private func assistantRow(_ id: Int, _ text: String, calls: [String]) -> StoredMessage {
    var row = StoredMessage(id: id, role: "assistant", content: .string(text))
    if !calls.isEmpty {
        row.toolCalls = .array(calls.map { call in
            ["id": .string(call), "type": "function", "function": ["name": "terminal", "arguments": "{}"]]
        })
    }
    return row
}

private func toolRow(_ id: Int, call: String) -> StoredMessage {
    var row = StoredMessage(id: id, role: "tool", content: "ok")
    row.toolCallID = call
    row.toolName = "terminal"
    return row
}

private extension Transcript {
    /// A prompt answered `streaming` with its row written at submit, and its turn started.
    mutating func startTurn(prompt: String, row: Int) {
        let item = appendUserPrompt(prompt)
        promptAnswered(itemID: item, status: "streaming", userRowID: row)
        apply(event("message.start"))
    }

    mutating func tool(_ call: String) {
        apply(event("tool.start", ["tool_id": .string(call), "name": "terminal"]))
        apply(event("tool.complete", ["tool_id": .string(call), "name": "terminal"]))
    }

    mutating func fail() {
        apply(event("message.complete", ["text": "", "status": "error", "error": "provider failed"]))
    }

    /// The turn's re-reads, until none is asked for.
    mutating func reread(_ rows: [StoredMessage]) {
        for _ in 0..<3 where needsReread {
            installRereadPage(rows, ticket: beginReread(), reachesStart: true)
        }
    }

    /// Live assistant items left (none of them stored).
    var liveReplies: [TranscriptItem] { items.filter { $0.role == .assistant && $0.rowID == nil } }
}

private let head = [storedRow(id: 1), storedRow(id: 2), storedRow(id: 3, role: "user", text: "go")]

@Suite struct ErrorEndRoundTests {
    /// R7-1 repro 1: round 2 repeats round 1's text, so Hermes sends no interim for it
    /// (`_interim_text_was_delivered`, `stream_delivery.py:165-167`); round 3 fails before
    /// streaming. Round 2's text was stored with its tool call: no copy stays live.
    @Test func aRoundWithoutAnInterimBeforeAFailedCallIsStored() {
        var transcript = idle()
        transcript.startTurn(prompt: "go", row: 3)
        transcript.apply(event("message.delta", ["text": "Let me check."]))
        transcript.apply(event("tool.generating", ["name": "terminal"]))
        transcript.apply(event("message.interim", ["text": "Let me check.", "already_streamed": true]))
        transcript.tool("a1")
        transcript.apply(event("message.delta", ["text": "\n\nLet me check."]))
        transcript.apply(event("tool.generating", ["name": "terminal"]))
        transcript.tool("a2")
        transcript.fail()
        transcript.reread(head + [assistantRow(4, "Let me check.", calls: ["a1"]), toolRow(5, call: "a1"),
                                  assistantRow(6, "Let me check.", calls: ["a2"]), toolRow(7, call: "a2")])
        #expect(copies(transcript, "Let me check.") == 2, "one per stored row")
        #expect(transcript.liveReplies.isEmpty, "\(transcript.liveReplies.map(\.text))")
        expectWellFormed(transcript)
    }

    /// R7-1 repro 2: text, `tool.generating`, text, `tool.generating` in one response; its
    /// interim holds both; its tools run; the next call fails.
    @Test func aTwoSegmentRoundBeforeAFailedCallIsStored() {
        var transcript = idle()
        transcript.startTurn(prompt: "go", row: 3)
        transcript.apply(event("message.delta", ["text": "I'll check A."]))
        transcript.apply(event("tool.generating", ["name": "terminal"]))
        transcript.apply(event("message.delta", ["text": "And B."]))
        transcript.apply(event("tool.generating", ["name": "terminal"]))
        transcript.apply(event("message.interim", ["text": "I'll check A.\n\nAnd B.", "already_streamed": true]))
        transcript.tool("a1")
        transcript.tool("b1")
        transcript.fail()
        transcript.reread(head + [assistantRow(4, "I'll check A.\n\nAnd B.", calls: ["a1", "b1"]),
                                  toolRow(5, call: "a1"), toolRow(6, call: "b1")])
        #expect(transcript.items.filter { $0.text.contains("And B.") }.count == 1)
        #expect(transcript.liveReplies.isEmpty, "\(transcript.liveReplies.map(\.text))")
    }

    /// R7-2: Codex commentary delivered mid-stream (`_fire_streamed_codex_commentary`,
    /// `stream_delivery.py:188-195`) is not stored when its call fails: it stays, with the
    /// call's partial answer, after the re-read.
    @Test(arguments: [false, true])
    func codexCommentaryOfAFailedCallStays(partialAnswer: Bool) {
        var transcript = idle()
        transcript.startTurn(prompt: "go", row: 3)
        transcript.tool("c1")
        transcript.apply(event("message.interim", ["text": "Checking the arithmetic.", "already_streamed": false]))
        if partialAnswer { transcript.apply(event("message.delta", ["text": "\n\nThe answer is"])) }
        transcript.fail()
        transcript.reread(head + [assistantRow(4, "", calls: ["c1"]), toolRow(5, call: "c1")])
        #expect(copies(transcript, "Checking the arithmetic.") == 1, "the commentary is gone")
        #expect(copies(transcript, "The answer is") == (partialAnswer ? 1 : 0))
    }

    /// Tool progress off: no tool events, so interims end the rounds. The stored rounds go
    /// with the re-read; the failing call's partial stays.
    @Test func withoutToolEventsInterimsEndTheRounds() {
        var transcript = idle()
        transcript.startTurn(prompt: "go", row: 3)
        transcript.apply(event("message.delta", ["text": "Let me check."]))
        transcript.apply(event("message.interim", ["text": "Let me check.", "already_streamed": true]))
        transcript.apply(event("message.delta", ["text": "\n\nNext step."]))
        transcript.apply(event("message.interim", ["text": "Next step.", "already_streamed": true]))
        transcript.apply(event("message.delta", ["text": "\n\nPartial"]))
        transcript.fail()
        transcript.reread(head + [assistantRow(4, "Let me check.", calls: ["a1"]), toolRow(5, call: "a1"),
                                  assistantRow(6, "Next step.", calls: ["a2"]), toolRow(7, call: "a2")])
        #expect(copies(transcript, "Let me check.") == 1)
        #expect(copies(transcript, "Next step.") == 1)
        #expect(transcript.liveReplies.map(\.text) == ["\n\nPartial"])
    }
}

@Suite struct RoundTextTests {
    /// R7-3: real reasoning streams after the round's text was sealed; Hermes then relays the
    /// call's content (`agent/turn_response_intake.py:103-117`). The relay is that text: it
    /// never replaces the reasoning, and the text shows once.
    @Test func theRelayNeverReplacesReasoning() {
        var transcript = idle()
        transcript.startTurn(prompt: "go", row: 3)
        transcript.tool("c1")
        transcript.apply(event("message.delta", ["text": "\n\nSearching next."]))
        transcript.apply(event("tool.generating", ["name": "web_search"]))
        transcript.apply(event("reasoning.delta", ["text": "which query first?"]))
        transcript.apply(event("reasoning.available", ["text": "Searching next."]))
        transcript.apply(event("message.interim", ["text": "Searching next.", "already_streamed": true]))
        #expect(transcript.items.contains { $0.reasoning == "which query first?" })
        #expect(!transcript.items.contains { $0.reasoning == "Searching next." })
        #expect(copies(transcript, "Searching next.") == 1)
    }

    /// R7-4: two segments of one call, then its interim holding both: one copy, no error end.
    @Test func twoSegmentsOfOneCallShowOnce() {
        var transcript = idle()
        transcript.startTurn(prompt: "go", row: 3)
        transcript.apply(event("message.delta", ["text": "I'll check A."]))
        transcript.apply(event("tool.generating", ["name": "terminal"]))
        transcript.apply(event("message.delta", ["text": "And B."]))
        transcript.apply(event("tool.generating", ["name": "terminal"]))
        transcript.apply(event("message.interim", ["text": "I'll check A.\n\nAnd B.", "already_streamed": true]))
        transcript.apply(event("tool.start", ["tool_id": "a1", "name": "terminal"]))
        #expect(transcript.items.filter { $0.text.contains("And B.") }.count == 1)
        #expect(transcript.items.filter { $0.text.contains("I'll check A.") }.count == 1)
        #expect(transcript.items.first { $0.text.contains("And B.") }?.isInterim == true)
    }
}
