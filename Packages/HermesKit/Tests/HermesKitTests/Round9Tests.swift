import Foundation
import HermesProtocol
import Testing

@testable import HermesKit

// Issue #5, round 9: an `error` end settled by the turn's receipt (`persisted_turn.row_ids`,
// sent for every status, `prompt_turn.py:874-941`). The round-8 review's probes R8-1, R8-2, R8-4,
// with the receipt Hermes sends on those paths.

private func ev(_ type: String, _ payload: JSONValue? = nil) -> GatewayEvent {
    GatewayEvent(type: type, sessionID: "sid-1", payload: payload)
}

private func norm(_ text: String) -> String { text.split(whereSeparator: \.isWhitespace).joined(separator: " ") }

private func count(_ t: Transcript, _ text: String) -> Int {
    t.items.filter { $0.role == .assistant && norm($0.text) == norm(text) }.count
}

private func aRow(_ id: Int, _ text: String, calls: [String] = []) -> StoredMessage {
    var row = StoredMessage(id: id, role: "assistant", content: .string(text))
    if !calls.isEmpty {
        row.toolCalls = .array(calls.map { ["id": .string($0), "type": "function", "function": ["name": "terminal", "arguments": "{}"]] })
    }
    return row
}

private func tRow(_ id: Int, call: String) -> StoredMessage {
    var row = StoredMessage(id: id, role: "tool", content: "ok")
    row.toolCallID = call
    row.toolName = "terminal"
    return row
}

private let base = [storedRow(id: 1), storedRow(id: 2), storedRow(id: 3, role: "user", text: "go")]

/// `message.complete` for an `error` end. `rows`: the receipt's `row_ids` (none: no receipt).
private func errorEnd(_ text: String = "", rows: [Int]?, partial: Bool = false) -> JSONValue {
    var payload: [String: JSONValue] = ["text": .string(text), "status": "error", "error": "API failed after 3 retries"]
    if partial { payload["partial"] = true }
    if let rows {
        payload["persisted_turn"] = ["row_ids": .array(rows.map { .number(Double($0)) }), "complete": false,
                                     "user_row_id": .number(Double(rows[0]))]
    }
    return .object(payload)
}

private extension Transcript {
    static func idle() -> Transcript {
        var t = Transcript()
        t.installLatestPage([storedRow(id: 1), storedRow(id: 2)], hasOlder: false)
        return t
    }
    mutating func begin() {
        let item = appendUserPrompt("go")
        promptAnswered(itemID: item, status: "streaming", userRowID: 3)
        apply(ev("message.start"))
    }
    mutating func runTool(_ call: String) {
        apply(ev("tool.start", ["tool_id": .string(call), "name": "terminal"]))
        apply(ev("tool.complete", ["tool_id": .string(call), "name": "terminal"]))
    }
    mutating func rereadAll(_ rows: [StoredMessage]) {
        for _ in 0..<3 where needsReread { installRereadPage(rows, ticket: beginReread(), reachesStart: true) }
    }
    var live: [String] { items.filter { $0.role == .assistant && $0.rowID == nil }.map(\.text) }
}

@Suite struct ErrorEndReceiptTests {
    /// R8-1: the stall guard (`agent/turn_final_response.py:231-237`) sends its reply as an interim
    /// before it is stored; the next call fails and the terminal persist stores it
    /// (`agent/turn_recovery.py:1241`). The receipt names it.
    @Test func stallGuardInterimAfterAToolRoundThenError() {
        var t = Transcript.idle()
        t.begin()
        t.apply(ev("message.delta", ["text": "Looking."]))
        t.apply(ev("tool.generating", ["name": "terminal"]))
        t.apply(ev("message.interim", ["text": "Looking.", "already_streamed": true]))
        t.runTool("a1")
        t.apply(ev("message.delta", ["text": "\n\nNow let me write the file."]))
        t.apply(ev("message.interim", ["text": "Now let me write the file.", "already_streamed": true]))
        t.apply(ev("message.complete", errorEnd("API failed after 3 retries", rows: [3, 4, 5, 6])))
        t.rereadAll(base + [aRow(4, "Looking.", calls: ["a1"]), tRow(5, call: "a1"), aRow(6, "Now let me write the file.")])
        #expect(count(t, "Now let me write the file.") == 1, "live: \(t.live)")
        // Only the error copy stays live (the event's text, shown as the failed reply).
        #expect(t.live == ["API failed after 3 retries"])
    }

    /// R8-2: the stream dies after visible text (a `length` stub, `chat_completion_helpers.py:3647-3667`),
    /// the continuation call runs out of retries, and `settle_delivered_partial` stores the
    /// fragment as one row (`agent/turn_recovery.py:830-847`, `agent/turn_truncation.py:89-90`).
    @Test(arguments: [false, true])
    func streamDeathThenRetryExhaustion(afterATool: Bool) {
        var t = Transcript.idle()
        t.begin()
        var rows = base
        if afterATool {
            t.runTool("a1")
            rows += [aRow(4, "", calls: ["a1"]), tRow(5, call: "a1")]
        }
        t.apply(ev("message.delta", ["text": "Here is the first half of the"]))
        t.apply(ev("thinking.delta", ["text": "↻ retrying"]))
        let partial = afterATool ? 6 : 4
        t.apply(ev("message.complete", errorEnd("Here is the first half of the\n\nAPI failed after 3 retries",
                                                rows: afterATool ? [3, 4, 5, partial] : [3, partial], partial: true)))
        rows.append(aRow(partial, "Here is the first half of the"))
        t.rereadAll(rows)
        #expect(count(t, "Here is the first half of the") == 1, "live: \(t.live)")
        #expect(t.live.isEmpty)
    }

    /// R8-4: tool progress off; round 2 repeats round 1's text, so no interim; round 3 fails.
    /// The receipt names round 2's row.
    @Test func toolProgressOffRepeatedTextThenError() {
        var t = Transcript.idle()
        t.begin()
        t.apply(ev("message.delta", ["text": "Let me check."]))
        t.apply(ev("message.interim", ["text": "Let me check.", "already_streamed": true]))
        t.apply(ev("message.delta", ["text": "\n\nLet me check."]))
        t.apply(ev("message.complete", errorEnd(rows: [3, 4, 5, 6, 7])))
        t.rereadAll(base + [aRow(4, "Let me check.", calls: ["a1"]), tRow(5, call: "a1"),
                            aRow(6, "Let me check.", calls: ["a2"]), tRow(7, call: "a2")])
        #expect(count(t, "Let me check.") == 2, "live: \(t.live)")
        #expect(t.live.isEmpty)
    }

    /// A partial Hermes did not store (no row of the receipt holds it: the overflow stub, a failed
    /// save before tools) stays, with or without a receipt.
    @Test(arguments: [false, true])
    func anUnstoredPartialStays(receipt: Bool) {
        var t = Transcript.idle()
        t.begin()
        t.runTool("a1")
        t.apply(ev("message.delta", ["text": "\n\nPartial"]))
        t.apply(ev("message.complete", errorEnd(rows: receipt ? [3, 4, 5] : nil)))
        t.rereadAll(base + [aRow(4, "", calls: ["a1"]), tRow(5, call: "a1")])
        #expect(count(t, "Partial") == 1)
        #expect(t.live == ["\n\nPartial"])
    }

    /// R7-2 with a receipt: Codex commentary sent mid-stream and not stored is in no row: it stays.
    @Test func unstoredCodexCommentaryStaysWithAReceipt() {
        var t = Transcript.idle()
        t.begin()
        t.runTool("c1")
        t.apply(ev("message.interim", ["text": "Checking the arithmetic.", "already_streamed": false]))
        t.apply(ev("message.delta", ["text": "\n\nThe answer is"]))
        t.apply(ev("message.complete", errorEnd(rows: [3, 4, 5])))
        t.rereadAll(base + [aRow(4, "", calls: ["c1"]), tRow(5, call: "c1")])
        #expect(count(t, "Checking the arithmetic.") == 1)
        #expect(count(t, "The answer is") == 1)
    }

    /// Only the turn's own receipt rows are compared: the same words stored by an earlier turn
    /// do not settle this turn's unstored partial.
    @Test func anotherTurnsRowDoesNotSettleIt() {
        var t = Transcript.idle()
        t.begin()
        t.runTool("a1")
        t.apply(ev("message.delta", ["text": "\n\nHello"]))
        t.apply(ev("message.complete", errorEnd(rows: [3, 4, 5])))
        t.rereadAll([storedRow(id: 1), aRow(2, "Hello"), storedRow(id: 3, role: "user", text: "go"),
                     aRow(4, "", calls: ["a1"]), tRow(5, call: "a1")])
        #expect(count(t, "Hello") == 2, "the stored row 2 and this turn's unstored partial")
    }
}

@Suite struct ReviewedBehaviourTests {
    /// The round-8 review's P5: a reconnect mid tool-call re-streams the opening text
    /// (`chat_completion_helpers.py:3663-3677`); shown twice until the turn's re-read, once after.
    @Test func midToolCallReconnectShowsOnceAfterTurn() {
        var t = Transcript.idle()
        t.begin()
        t.apply(ev("message.delta", ["text": "Let me check."]))
        t.apply(ev("tool.generating", ["name": "terminal"]))
        t.apply(ev("message.delta", ["text": "\n\n⚠ Connection dropped mid tool-call; reconnecting…\n\n"]))
        t.apply(ev("message.delta", ["text": "Let me check."]))
        t.apply(ev("tool.generating", ["name": "terminal"]))
        t.apply(ev("message.interim", ["text": "Let me check.", "already_streamed": false]))
        t.runTool("a1")
        t.apply(ev("message.delta", ["text": "\n\nDone."]))
        t.apply(ev("message.complete", ["text": "Done.", "status": "complete"]))
        t.rereadAll(base + [aRow(4, "Let me check.", calls: ["a1"]), tRow(5, call: "a1"), aRow(6, "Done.")])
        #expect(count(t, "Let me check.") == 1)
        #expect(t.live.isEmpty)
    }

    /// The round-8 review's P6: a non-streaming round. Until the re-read the relayed content is
    /// reasoning and the interim its bubble's text (Desktop parity); after it, only stored rows.
    @Test func nonStreamingRelayThenInterim() {
        var t = Transcript.idle()
        t.begin()
        t.apply(ev("reasoning.available", ["text": "I'll run the tests."]))
        t.apply(ev("message.interim", ["text": "I'll run the tests.", "already_streamed": false]))
        let shown = t.items.filter { $0.role == .assistant && $0.rowID == nil }
        #expect(shown.count == 1)
        #expect(shown.first?.reasoning == "I'll run the tests." && shown.first?.text == "I'll run the tests.")
        t.runTool("a1")
        t.apply(ev("message.complete", ["text": "All green.", "status": "complete"]))
        t.rereadAll(base + [aRow(4, "I'll run the tests.", calls: ["a1"]), tRow(5, call: "a1"), aRow(6, "All green.")])
        #expect(t.live.isEmpty)
    }
}
