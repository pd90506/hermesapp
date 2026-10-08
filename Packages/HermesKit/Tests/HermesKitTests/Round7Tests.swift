import Foundation
import HermesProtocol
import Testing

@testable import HermesKit

// Issue #5, round 7: the round-6 review's F1 (a mid-turn page hid a finished turn that sent
// no receipt) and F2/F3 (an interim's segment with show-reasoning on, and Codex commentary).

private func event(_ type: String, _ payload: JSONValue? = nil) -> GatewayEvent {
    GatewayEvent(type: type, sessionID: "sid-1", payload: payload)
}

private func idle() -> Transcript {
    var transcript = Transcript()
    transcript.installLatestPage([storedRow(id: 1), storedRow(id: 2)], hasOlder: false)
    return transcript
}

/// Assistant items whose text is `text`, whitespace aside.
private func copies(_ transcript: Transcript, _ text: String) -> Int {
    let target = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    return transcript.items.filter {
        $0.role == .assistant && $0.text.split(whereSeparator: \.isWhitespace).joined(separator: " ") == target
    }.count
}

private func toolRows(_ transcript: Transcript, call: String) -> Int {
    transcript.items.filter { $0.role == .tool && $0.toolCallID == call }.count
}

private func assistantRow(_ id: Int, _ text: String, calls: [String]) -> StoredMessage {
    var row = StoredMessage(id: id, role: "assistant", content: .string(text))
    if !calls.isEmpty {
        row.toolCalls = .array(calls.map { call in
            ["id": .string(call), "type": "function", "function": ["name": "terminal", "arguments": #"{"command":"date"}"#]]
        })
    }
    return row
}

private func toolRow(_ id: Int, call: String) -> StoredMessage {
    var row = StoredMessage(id: id, role: "tool", content: "Thu Oct  8")
    row.toolCallID = call
    row.toolName = "terminal"
    return row
}

/// How the earlier turn ended without a receipt.
enum EarlierTurnEnd: String, CaseIterable, Sendable {
    /// `message.complete` with no `persisted_turn` (`prompt_turn.py:874-900`).
    case completeWithoutReceipt
    /// A `running: false` report closed it here (`closeTurnHere`).
    case closedHere
}

@Suite struct MidTurnPageKeepsEarlierTurnsTests {
    /// Turn 1 (prompt row 3): text, a tool round, an answer, then an end without a receipt;
    /// its re-read fails. `repeat`: turn 2's text ("Let me look.") or call id (`a1`, as
    /// `deterministic_call_id` gives the same `terminal date` in both turns) repeats it.
    private func earlierTurn(_ transcript: inout Transcript, end: EarlierTurnEnd, call: String) {
        let prompt = transcript.appendUserPrompt("one")
        transcript.promptAnswered(itemID: prompt, status: "streaming", userRowID: 3)
        transcript.apply(event("message.start"))
        transcript.apply(event("message.delta", ["text": "Let me look."]))
        transcript.apply(event("tool.generating", ["name": "terminal"]))
        transcript.apply(event("message.interim", ["text": "Let me look.", "already_streamed": true]))
        transcript.apply(event("tool.start", ["tool_id": .string(call), "name": "terminal"]))
        transcript.apply(event("tool.complete", ["tool_id": .string(call), "name": "terminal"]))
        transcript.apply(event("message.delta", ["text": "\n\nAnswer ONE."]))
        switch end {
        case .completeWithoutReceipt:
            transcript.apply(event("message.complete", ["text": "Answer ONE.", "status": "complete"]))
        case .closedHere:
            transcript.reconcileRunning(false)
        }
        _ = transcript.beginReread()  // it fails
    }

    /// The review's repro (F1), and its call-id variant: the earlier turn's answer and tool
    /// card stay shown while turn 2 runs, whichever order turn 2's answer and start come in.
    @Test(arguments: EarlierTurnEnd.allCases, [false, true])
    func aReceiptlessEarlierTurnStaysShown(end: EarlierTurnEnd, answerAfterStart: Bool) {
        for repeatsCall in [false, true] {
            var transcript = idle()
            earlierTurn(&transcript, end: end, call: "a1")
            let second = transcript.appendUserPrompt("two")
            if !answerAfterStart { transcript.promptAnswered(itemID: second, status: "streaming", userRowID: 7) }
            transcript.apply(event("message.start"))
            if answerAfterStart { transcript.promptAnswered(itemID: second, status: "streaming", userRowID: 7) }
            if repeatsCall {
                transcript.apply(event("tool.start", ["tool_id": "a1", "name": "terminal"]))
            } else {
                transcript.apply(event("message.delta", ["text": "Let me look."]))
                transcript.apply(event("tool.generating", ["name": "terminal"]))
                transcript.apply(event("message.interim", ["text": "Let me look.", "already_streamed": true]))
                transcript.apply(event("tool.start", ["tool_id": "b1", "name": "terminal"]))
            }
            // A retry of turn 1's read lands now.
            let page = [storedRow(id: 1), storedRow(id: 2), storedRow(id: 3, role: "user", text: "one"),
                        assistantRow(4, "Let me look.", calls: ["a1"]), toolRow(5, call: "a1"),
                        assistantRow(6, "Answer ONE.", calls: []), storedRow(id: 7, role: "user", text: "two"),
                        assistantRow(8, repeatsCall ? "" : "Let me look.", calls: [repeatsCall ? "a1" : "b1"])]
            transcript.installRereadPage(page, ticket: transcript.beginReread(), reachesStart: true)
            #expect(copies(transcript, "Answer ONE.") == 1, "\(repeatsCall ? "call id" : "text"): turn 1's answer")
            #expect(toolRows(transcript, call: "a1") == (repeatsCall ? 2 : 1), "turn 1's card (and turn 2's live one)")
            #expect(transcript.items.filter { $0.text == "one" }.count == 1)
            #expect(transcript.items.filter { $0.text == "two" }.count == 1)
            // Turn 2's own prompt row places the cut: turn 1's stored rows went in.
            #expect(transcript.items.contains { $0.rowID == 6 } && transcript.items.contains { $0.rowID == 7 })
            #expect(transcript.isRunning)
        }
    }

    /// A turn this chat did not send (no prompt row known here): the cut can fall inside an
    /// earlier receipt-less turn, so that turn keeps its live items until a read that is not
    /// cut. Shown, never hidden.
    @Test(arguments: EarlierTurnEnd.allCases)
    func aTurnFromElsewhereKeepsTheEarlierTurnLive(end: EarlierTurnEnd) {
        var transcript = idle()
        earlierTurn(&transcript, end: end, call: "a1")
        transcript.apply(event("message.start"))
        transcript.apply(event("message.delta", ["text": "Let me look."]))
        transcript.apply(event("tool.generating", ["name": "terminal"]))
        transcript.apply(event("message.interim", ["text": "Let me look.", "already_streamed": true]))
        transcript.apply(event("tool.start", ["tool_id": "b1", "name": "terminal"]))
        let page = [storedRow(id: 1), storedRow(id: 2), storedRow(id: 3, role: "user", text: "one"),
                    assistantRow(4, "Let me look.", calls: ["a1"]), toolRow(5, call: "a1"),
                    assistantRow(6, "Answer ONE.", calls: []), storedRow(id: 7, role: "user", text: "two"),
                    assistantRow(8, "Let me look.", calls: ["b1"])]
        transcript.installRereadPage(page, ticket: transcript.beginReread(), reachesStart: true)
        #expect(copies(transcript, "Answer ONE.") >= 1, "turn 1's answer is hidden")
        #expect(toolRows(transcript, call: "a1") >= 1, "turn 1's card is hidden")

        // Turn 2 ends; its re-read is not cut: one of each.
        transcript.apply(event("tool.complete", ["tool_id": "b1", "name": "terminal"]))
        transcript.apply(event("message.complete", completePayload("", rows: [7, 8, 9])))
        transcript.installRereadPage(page + [toolRow(9, call: "b1")], ticket: transcript.beginReread(), reachesStart: true)
        #expect(copies(transcript, "Answer ONE.") == 1)
        #expect(toolRows(transcript, call: "a1") == 1)
        #expect(copies(transcript, "Let me look.") == 2, "one per turn")
    }
}

private let interimText = "今天是 10 月 8 号（周四），诺奖周进行中，我搜一圈今天的消息。"

@Suite struct InterimWithReasoningTests {
    /// F2: with show-reasoning on, Hermes relays the response's content as
    /// `reasoning.available` after `tool.generating` sealed it
    /// (`agent/turn_response_intake.py:103-117`, `tool_progress.py:383-386`).
    @Test(arguments: [true, false])
    func theRelayedTextDoesNotOpenASecondCopy(leadingBreak: Bool) throws {
        var transcript = idle()
        transcript.appendUserPrompt("今天有什么新闻")
        transcript.apply(event("message.start"))
        transcript.apply(event("tool.start", ["tool_id": "c1", "name": "terminal"]))
        transcript.apply(event("tool.complete", ["tool_id": "c1", "name": "terminal"]))
        transcript.apply(event("message.delta", ["text": .string((leadingBreak ? "\n\n" : "") + interimText)]))
        transcript.apply(event("tool.generating", ["name": "web_search"]))
        transcript.apply(event("reasoning.available", ["text": .string(interimText)]))
        transcript.apply(event("message.interim", ["text": .string(interimText), "already_streamed": true]))
        transcript.apply(event("tool.start", ["tool_id": "c4", "name": "web_search"]))
        #expect(copies(transcript, interimText) == 1)
        #expect(!transcript.items.contains { $0.reasoning == interimText }, "the relay shows as reasoning")
        let interim = try #require(transcript.items.firstIndex { $0.isInterim })
        let c1 = try #require(transcript.items.firstIndex { $0.toolCallID == "c1" })
        let c4 = try #require(transcript.items.firstIndex { $0.toolCallID == "c4" })
        #expect(c1 < interim && interim < c4)
        expectWellFormed(transcript)
    }

    /// The reasoning-only shape: real reasoning streams after the round's text was sealed;
    /// the interim seals the text, and the reasoning stays as it is.
    @Test func aReasoningOnlySegmentDoesNotTakeTheInterim() {
        var transcript = idle()
        transcript.appendUserPrompt("go")
        transcript.apply(event("message.start"))
        transcript.apply(event("tool.start", ["tool_id": "c1", "name": "terminal"]))
        transcript.apply(event("tool.complete", ["tool_id": "c1", "name": "terminal"]))
        transcript.apply(event("message.delta", ["text": "\n\nSearching next."]))
        transcript.apply(event("tool.generating", ["name": "web_search"]))
        transcript.apply(event("reasoning.delta", ["text": "which query first?"]))
        transcript.apply(event("message.interim", ["text": "Searching next.", "already_streamed": true]))
        #expect(copies(transcript, "Searching next.") == 1)
        #expect(transcript.items.contains { $0.reasoning == "which query first?" && $0.text.isEmpty })
    }

    /// F3: Codex commentary that never streamed, beside a streamed partial answer sealed by
    /// `tool.generating` (`stream_delivery.py:188-195`): the answer keeps its text.
    @Test func commentaryDoesNotReplaceADifferentSealedText() {
        var transcript = idle()
        transcript.appendUserPrompt("go")
        transcript.apply(event("message.start"))
        transcript.apply(event("tool.start", ["tool_id": "c1", "name": "terminal"]))
        transcript.apply(event("tool.complete", ["tool_id": "c1", "name": "terminal"]))
        transcript.apply(event("message.delta", ["text": "\n\nThe answer is 4"]))
        transcript.apply(event("tool.generating", ["name": "terminal"]))
        transcript.apply(event("message.interim", ["text": "Checking the arithmetic.", "already_streamed": false]))
        #expect(copies(transcript, "The answer is 4") == 1)
        #expect(copies(transcript, "Checking the arithmetic.") == 1)
    }
}
