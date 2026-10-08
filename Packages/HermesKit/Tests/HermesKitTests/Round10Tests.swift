import Foundation
import HermesProtocol
import Testing

@testable import HermesKit

// Issue #5, round 10: the round-9 review's R9-1 (a seam newline in a twice-cut reply) and R9-2
// (receipt rows on an older page).

private func ev(_ type: String, _ payload: JSONValue? = nil) -> GatewayEvent {
    GatewayEvent(type: type, sessionID: "sid-1", payload: payload)
}

private func norm(_ text: String) -> String { text.split(whereSeparator: \.isWhitespace).joined(separator: " ") }

private func aRow(_ id: Int, _ text: String) -> StoredMessage {
    StoredMessage(id: id, role: "assistant", content: .string(text))
}

private let base = [storedRow(id: 1), storedRow(id: 2), storedRow(id: 3, role: "user", text: "go")]

private func errorEnd(_ text: String, rows: [Int]) -> JSONValue {
    ["text": .string(text), "status": "error", "error": "API failed after 3 retries", "partial": true,
     "persisted_turn": ["row_ids": .array(rows.map { .number(Double($0)) }), "complete": false,
                        "user_row_id": .number(Double(rows[0]))]]
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
    mutating func rereadAll(_ rows: [StoredMessage], reachesStart: Bool = true) {
        for _ in 0..<3 where needsReread { installRereadPage(rows, ticket: beginReread(), reachesStart: reachesStart) }
    }
    var live: [String] { items.filter { $0.role == .assistant && $0.rowID == nil }.map(\.text) }
    func shown(_ text: String) -> Int { items.filter { $0.role == .assistant && norm($0.text) == norm(text) }.count }
}

@Suite struct ReceiptSeamTests {
    /// R9-1: a reply cut off twice, then retries exhausted. The screen joins both calls' text in
    /// one bubble; Hermes stores `_join_truncated_parts`, with a "\n" at a seam where neither side
    /// has whitespace (`agent/conversation_loop.py:301-302`).
    @Test func twoFragmentsSeamNewline() {
        var t = Transcript.idle()
        t.begin()
        t.apply(ev("message.delta", ["text": "Here is the quick"]))
        t.apply(ev("message.delta", ["text": "brown fox jumps."]))
        t.apply(ev("message.complete", errorEnd("Here is the quick\nbrown fox jumps.\n\nAPI failed after 3 retries", rows: [3, 4])))
        t.rereadAll(base + [aRow(4, "Here is the quick\nbrown fox jumps.")])
        #expect(t.live.isEmpty, "live: \(t.live)")
        #expect(t.items.contains { $0.rowID == 4 })
    }

    /// Known limitation: a continuation that repeats 32+ characters of the tail is stored with the
    /// overlap removed (`conversation_loop.py:298-300`); no row matches, so the partial stays live
    /// beside its row: shown twice, never hidden.
    @Test func twoFragmentsOverlapDedupStaysShown() {
        var t = Transcript.idle()
        t.begin()
        t.apply(ev("message.delta", ["text": "First paragraph. The configuration file lives in the home directory"]))
        t.apply(ev("message.delta", ["text": " the configuration file lives in the home directory under .hermes."]))
        let stored = "First paragraph. The configuration file lives in the home directory under .hermes."
        t.apply(ev("message.complete", errorEnd(stored + "\n\nAPI failed", rows: [3, 4])))
        t.rereadAll(base + [aRow(4, stored)])
        #expect(t.live.count == 1)
        #expect(t.items.contains { $0.rowID == 4 })
    }
}

@Suite struct ReceiptOlderPageTests {
    /// R9-2: newer rows from elsewhere pushed the turn's receipt row off the latest page; the
    /// older page that holds it settles the partial.
    @Test func receiptRowOnOlderPage() {
        var t = Transcript.idle()
        t.begin()
        t.apply(ev("message.delta", ["text": "Partial reply"]))
        t.apply(ev("message.complete", errorEnd("Partial reply\n\nAPI failed", rows: [3, 4])))
        let newer = (10..<20).map { storedRow(id: $0, role: $0 % 2 == 0 ? "user" : "assistant", text: "other \($0)") }
        t.rereadAll(newer, reachesStart: false)
        #expect(t.shown("Partial reply") == 1, "live until its row is read")
        t.prependOlderPage(base + [aRow(4, "Partial reply")], hasOlder: false)
        #expect(t.shown("Partial reply") == 1, "\(t.items.map(\.text))")
        #expect(t.live.isEmpty)
        t.requestReread()
        t.rereadAll(newer, reachesStart: false)
        #expect(t.shown("Partial reply") == 1)
    }
}
