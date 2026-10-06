import Foundation
import HermesProtocol
import Testing

@testable import HermesKit

/// The stored part of `Transcript`: pages from `GET /api/sessions/{id}/messages`
/// and how they meet the live turns.
@Suite struct TranscriptPagingTests {
    private func event(_ type: String, _ payload: JSONValue? = nil) -> GatewayEvent {
        GatewayEvent(type: type, sessionID: "sid-1", payload: payload)
    }

    /// `message.complete` with the committed rows (`prompt_turn.py:873-922`).
    private func complete(_ text: String, rows: [Int], fully: Bool = true) -> GatewayEvent {
        event("message.complete", ["text": .string(text), "status": "complete",
                                   "persisted_turn": ["row_ids": .array(rows.map { .number(Double($0)) }),
                                                      "complete": .bool(fully),
                                                      "user_row_id": .number(Double(rows[0])),
                                                      "final_assistant_row_id": .number(Double(rows.last!))]])
    }

    private func rows(_ range: ClosedRange<Int>) -> [StoredMessage] { range.map { storedRow(id: $0) } }

    private func texts(_ transcript: Transcript) -> [String] { transcript.items.map(\.text) }

    // MARK: Projection

    /// Raw rows as `_row_to_message_dict` returns them (`hermes_state_messages.py:1311-1333`),
    /// after `_project_for_display` (`web_routers/sessions.py:617-682`).
    @Test func storedRowsProjectLikeTheGatewayResume() throws {
        let page = try decodeJSON(#"""
            {"session_id":"s1","profile":"coder","pagination":{"limit":120,"offset":0,"order":"latest","returned":7},
             "messages":[
              {"id":10,"session_id":"s1","role":"user","content":"[System: model switched]","tool_call_id":null,
               "tool_calls":null,"tool_name":null,"timestamp":1700000000.0,"token_count":null,"finish_reason":null,
               "reasoning":null,"active":1,"compacted":0,"display_kind":"hidden","display_metadata":null},
              {"id":11,"session_id":"s1","role":"user","content":"list files","tool_call_id":null,"tool_calls":null,
               "tool_name":null,"timestamp":1700000001.0,"active":1,"compacted":0,"display_kind":null},
              {"id":12,"session_id":"s1","role":"assistant","content":"","tool_call_id":null,
               "tool_calls":[{"id":"call-1","type":"function","function":{"name":"terminal","arguments":"{\"command\":\"ls -la\"}"}}],
               "tool_name":null,"timestamp":1700000002.0,"reasoning":"Look first.","active":1,"compacted":0,"display_kind":null},
              {"id":13,"session_id":"s1","role":"tool","content":"a\nb","tool_call_id":"call-1","tool_calls":null,
               "tool_name":"terminal","timestamp":1700000003.0,"active":1,"compacted":0,"display_kind":null},
              {"id":14,"session_id":"s1","role":"assistant","content":"","tool_call_id":null,"tool_calls":null,
               "tool_name":null,"timestamp":1700000004.0,"active":1,"compacted":0,"display_kind":null},
              {"id":15,"session_id":"s1","role":"assistant","content":"[CONTEXT COMPACTION] …","_compressed_summary":true,
               "display_content":"Earlier turns were summarised.","timestamp":1700000005.0,"active":1,"compacted":0},
              {"id":16,"session_id":"s1","role":"assistant","content":[{"type":"text","text":"Two files."}],
               "timestamp":1700000006.0,"active":1,"compacted":0,"display_kind":null}
             ]}
            """#, as: SessionMessagesPage.self)

        var transcript = Transcript()
        transcript.installLatestPage(page.messages, hasOlder: false)

        // The empty assistant row 14 is skipped; row 12 stays for its reasoning.
        #expect(texts(transcript) == ["list files", "", "", "Earlier turns were summarised.", "Two files."])
        let roles = transcript.items.map(\.role)
        #expect(roles == [.user, .assistant, .tool, .assistant, .assistant])
        #expect(transcript.items[1].reasoning == "Look first.")
        #expect(transcript.items[2].toolName == "terminal" && transcript.items[2].detail == "ls -la")
        #expect(transcript.items[2].id == "row-13")  // stored items are keyed by row
        #expect(transcript.items[2].toolCallID == "call-1")
        #expect(transcript.items.map(\.rowID) == [11, 12, 13, 15, 16])
        #expect(transcript.historyCount == 5)
        // Hidden rows count for the server's offset.
        // Older pages start `olderPageOverlap` (10) rows early; never below 0.
        #expect(transcript.nextOlderOffset == 0)
        expectWellFormed(transcript)
    }

    // MARK: Older pages

    @Test func olderPagesPrependInOrderUntilTheBeginning() {
        var transcript = Transcript()
        transcript.installLatestPage(rows(181...300), hasOlder: true)
        #expect(transcript.nextOlderOffset == 110)  // 120 received, 10 re-read as overlap

        transcript.prependOlderPage(rows(61...180), hasOlder: true)
        #expect(transcript.nextOlderOffset == 230)
        transcript.prependOlderPage(rows(1...60), hasOlder: false)

        #expect(transcript.items.compactMap(\.rowID) == Array(1...300))
        #expect(Set(transcript.items.map(\.id)).count == 300)
        #expect(!transcript.paging.hasOlder)
        expectWellFormed(transcript)
    }

    /// Rows stored after the newest page was read shift the server's offsets:
    /// the next page overlaps (Desktop `transcript-backfill.test.ts:121-154`).
    @Test func anOverlappingOlderPageAddsNoDuplicates() {
        var transcript = Transcript()
        transcript.installLatestPage(rows(181...300), hasOlder: true)
        // Five rows were written meanwhile, unseen: offset 120 now starts at row 185.
        transcript.prependOlderPage(rows(65...184), hasOlder: true)
        #expect(transcript.items.compactMap(\.rowID) == Array(65...300))
        expectWellFormed(transcript)
    }

    /// The offset counts fetched rows only, as Desktop does: rows a live ack names
    /// may be model-only or fold into an existing display row, so counting them
    /// could skip rows. Rows stored since make the next page overlap instead.
    @Test func liveAcksDoNotMoveTheNextOffset() {
        var transcript = Transcript()
        transcript.installLatestPage(rows(181...300), hasOlder: true)
        let prompt = transcript.appendUserPrompt("next")
        transcript.promptAnswered(itemID: prompt)
        transcript.apply(event("message.delta", ["text": "ok"]))
        transcript.apply(complete("ok", rows: [301, 302]))
        #expect(transcript.nextOlderOffset == 110)
        #expect(texts(transcript).suffix(2) == ["next", "ok"])
        // The overlapping page (rows 61...180 shifted by two) adds no duplicates.
        transcript.prependOlderPage(rows(63...182), hasOlder: true)
        #expect(transcript.items.compactMap(\.rowID) == Array(63...300))
        expectWellFormed(transcript)
    }

    // MARK: Seams with live turns

    /// Not provably stored in full: the live copy stays.
    @Test func aPartlyStoredForeignTurnStaysLive() {
        var transcript = Transcript(snapshot: LiveSessionSnapshot(sessionID: "sid-1").withCount(300))
        transcript.apply(event("message.delta", ["text": "reply"]))
        transcript.apply(complete("reply", rows: [301, 302], fully: false))
        transcript.installLatestPage(rows(181...300), hasOlder: true)
        #expect(texts(transcript).suffix(2) == ["assistant 300", "reply"])
        expectWellFormed(transcript)
    }
}

extension LiveSessionSnapshot {
    /// A resume ack with `omit_messages`: no messages, the stored size as `message_count`.
    func withCount(_ count: Int) -> LiveSessionSnapshot {
        var snapshot = self
        snapshot.messageCount = count
        return snapshot
    }
}
