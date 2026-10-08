import Foundation
import HermesProtocol
import Testing

@testable import HermesKit

// Issue #5, round 6: interim text shown twice in tool-using turns (Path A), and a re-read
// that lands mid-turn showing that turn's stored rows beside its live items (Path B).

private func event(_ type: String, _ payload: JSONValue? = nil) -> GatewayEvent {
    GatewayEvent(type: type, sessionID: "sid-1", payload: payload)
}

/// An idle chat whose history is rows 1...2 (prompt, reply), every row read.
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

/// A stored assistant row with `text` and the given tool calls.
private func assistantRow(_ id: Int, _ text: String, calls: [String]) -> StoredMessage {
    var row = StoredMessage(id: id, role: "assistant", content: .string(text))
    if !calls.isEmpty {
        row.toolCalls = .array(calls.map { call in
            ["id": .string(call), "type": "function", "function": ["name": "web_search", "arguments": "{}"]]
        })
    }
    return row
}

private func toolRow(_ id: Int, call: String) -> StoredMessage {
    var row = StoredMessage(id: id, role: "tool", content: "results")
    row.toolCallID = call
    row.toolName = "web_search"
    return row
}

private let interimText = "今天是 10 月 8 号（周四），诺奖周进行中，我搜一圈今天的消息。"

/// Round 1 (`terminal date` and a `web_search`, no text), then round 2's text: the first
/// delta after a tool round starts with "\n\n" (`agent/stream_delivery.py:305-310`).
private func pathA(_ transcript: inout Transcript, leadingBreak: Bool = true, generating: Bool = true) {
    transcript.apply(event("message.start"))
    transcript.apply(event("tool.generating", ["name": "terminal"]))
    transcript.apply(event("tool.start", ["tool_id": "c1", "name": "terminal"]))
    transcript.apply(event("tool.start", ["tool_id": "c2", "name": "web_search"]))
    transcript.apply(event("tool.complete", ["tool_id": "c1", "name": "terminal"]))
    transcript.apply(event("tool.complete", ["tool_id": "c2", "name": "web_search", "summary": "Did 8 searches in 3.1s"]))
    transcript.apply(event("message.delta", ["text": .string((leadingBreak ? "\n\n" : "") + "今天是 10 月 8 号（周四），")]))
    transcript.apply(event("message.delta", ["text": "诺奖周进行中，我搜一圈今天的消息。"]))
    if generating { transcript.apply(event("tool.generating", ["name": "web_search"])) }
    // Sent once round 2's row is stored (`turn_tool_round.py:150-155`), stripped.
    transcript.apply(event("message.interim", ["text": .string(interimText), "already_streamed": true]))
    transcript.apply(event("tool.start", ["tool_id": "c4", "name": "web_search"]))
}

@Suite struct InterimShownOnceTests {
    /// Panda's report (diag-dup2 §4): the interim text showed twice, in a row.
    @Test(arguments: [(true, true), (true, false), (false, true), (false, false)])
    func theRoundsTextShowsOnce(leadingBreak: Bool, generating: Bool) throws {
        var transcript = idle()
        transcript.appendUserPrompt("今天有什么新闻")
        pathA(&transcript, leadingBreak: leadingBreak, generating: generating)
        #expect(copies(transcript, interimText) == 1)
        let interim = try #require(transcript.items.firstIndex { $0.role == .assistant && $0.isInterim })
        #expect(transcript.items[interim].text == interimText)
        // Before round 2's card, after round 1's.
        let c2 = try #require(transcript.items.firstIndex { $0.toolCallID == "c2" })
        let c4 = try #require(transcript.items.firstIndex { $0.toolCallID == "c4" })
        #expect(c2 < interim && interim < c4)
        expectWellFormed(transcript)
    }

    /// Only part streamed before `tool.generating` sealed it: the interim replaces it in place.
    @Test func aPartlyStreamedSealedSegmentTakesTheInterim() {
        var transcript = idle()
        transcript.appendUserPrompt("go")
        transcript.apply(event("message.start"))
        transcript.apply(event("tool.start", ["tool_id": "c1", "name": "terminal"]))
        transcript.apply(event("tool.complete", ["tool_id": "c1", "name": "terminal"]))
        transcript.apply(event("message.delta", ["text": "\n\n今天是 10 月"]))
        transcript.apply(event("tool.generating", ["name": "web_search"]))
        transcript.apply(event("message.interim", ["text": .string(interimText), "already_streamed": false]))
        #expect(copies(transcript, interimText) == 1)
        #expect(!transcript.items.contains { $0.role == .assistant && $0.text.contains("今天是 10 月") && $0.text != interimText })
    }

    /// Interim text that never streamed is appended once.
    @Test func anInterimThatNeverStreamedIsAppendedOnce() {
        var transcript = idle()
        transcript.appendUserPrompt("go")
        transcript.apply(event("message.start"))
        transcript.apply(event("tool.start", ["tool_id": "c1", "name": "terminal"]))
        transcript.apply(event("tool.complete", ["tool_id": "c1", "name": "terminal"]))
        transcript.apply(event("tool.generating", ["name": "web_search"]))
        transcript.apply(event("message.interim", ["text": "Searching now.", "already_streamed": false]))
        #expect(copies(transcript, "Searching now.") == 1)
        #expect(transcript.items.last?.isInterim == true)
    }

    /// A repeated delivery, whitespace aside, stays one row, also past a tool row.
    @Test func aRepeatedDeliveryStaysOneRow() {
        var transcript = idle()
        transcript.appendUserPrompt("go")
        pathA(&transcript)
        let again = " " + interimText.replacingOccurrences(of: " 8 ", with: "\n8  ") + "\n"
        transcript.apply(event("message.interim", ["text": .string(again), "already_streamed": true]))
        #expect(copies(transcript, interimText) == 1)
    }

    /// The match never crosses a prompt: the same words in the next turn are that turn's.
    @Test func theSameTextInTheNextTurnIsItsOwn() {
        var transcript = idle()
        transcript.appendUserPrompt("first")
        transcript.apply(event("message.start"))
        transcript.apply(event("tool.start", ["tool_id": "c1", "name": "terminal"]))
        transcript.apply(event("tool.complete", ["tool_id": "c1", "name": "terminal"]))
        transcript.apply(event("message.interim", ["text": "Let me look.", "already_streamed": false]))
        transcript.apply(event("message.complete", ["text": "done", "status": "complete"]))
        transcript.appendUserPrompt("second")
        transcript.apply(event("message.start"))
        transcript.apply(event("tool.start", ["tool_id": "c9", "name": "terminal"]))
        transcript.apply(event("tool.complete", ["tool_id": "c9", "name": "terminal"]))
        transcript.apply(event("message.interim", ["text": "Let me look.", "already_streamed": false]))
        #expect(copies(transcript, "Let me look.") == 2)
    }

    /// diag-dup2 §1's edge: a turn that fails after an interim. The interim was stored
    /// before it was sent, so after the re-read only the stored copy shows.
    @Test func anErrorTurnLeavesOnlyTheStoredInterim() {
        var transcript = idle()
        let prompt = transcript.appendUserPrompt("今天有什么新闻")
        transcript.promptAnswered(itemID: prompt, status: "streaming", userRowID: 3)
        pathA(&transcript)
        transcript.apply(event("tool.complete", ["tool_id": "c4", "name": "web_search"]))
        transcript.apply(event("message.complete", ["text": "", "status": "error", "error": "provider failed"]))
        let rows = [storedRow(id: 1), storedRow(id: 2), storedRow(id: 3, role: "user", text: "今天有什么新闻"),
                    assistantRow(4, "", calls: ["c1", "c2"]), toolRow(5, call: "c1"), toolRow(6, call: "c2"),
                    assistantRow(7, interimText, calls: ["c4"]), toolRow(8, call: "c4")]
        for _ in 0..<3 where transcript.needsReread {
            transcript.installRereadPage(rows, ticket: transcript.beginReread(), reachesStart: true)
        }
        #expect(copies(transcript, interimText) == 1)
        #expect(transcript.items.first { $0.text == interimText }?.rowID == 7)
        expectWellFormed(transcript)
    }
}

@Suite struct MidTurnRereadTests {
    /// Path B: the read a `streaming` answer asks for, sent before `message.start`, lands
    /// after the turn stored a round. The turn's stored rows stay out until its own re-read.
    @Test func theAnswersRereadLandingAfterAStoredRound() {
        var transcript = idle()
        let prompt = transcript.appendUserPrompt("hello")
        transcript.promptAnswered(itemID: prompt, status: "streaming", userRowID: 3)
        let ticket = transcript.beginReread()
        transcript.apply(event("message.start"))
        transcript.apply(event("tool.start", ["tool_id": "c1", "name": "web_search"]))
        transcript.apply(event("tool.complete", ["tool_id": "c1", "name": "web_search"]))
        transcript.apply(event("message.delta", ["text": "\n\nLooking further."]))
        transcript.apply(event("tool.generating", ["name": "web_search"]))
        transcript.apply(event("message.interim", ["text": "Looking further.", "already_streamed": true]))
        transcript.apply(event("tool.start", ["tool_id": "c2", "name": "web_search"]))
        let page = [storedRow(id: 1), storedRow(id: 2), storedRow(id: 3, role: "user", text: "hello"),
                    assistantRow(4, "", calls: ["c1"]), toolRow(5, call: "c1"),
                    assistantRow(6, "Looking further.", calls: ["c2"])]
        transcript.installRereadPage(page, ticket: ticket, reachesStart: true)
        #expect(transcript.isRunning)
        #expect(copies(transcript, "Looking further.") == 1)
        #expect(toolRows(transcript, call: "c1") == 1)
        #expect(transcript.items.filter { $0.text == "hello" }.count == 1, "the prompt shows once")

        // The turn ends; its own re-read brings its rows, and the live items go.
        transcript.apply(event("tool.complete", ["tool_id": "c2", "name": "web_search"]))
        transcript.apply(event("message.delta", ["text": "\n\nDone."]))
        transcript.apply(event("message.complete", completePayload("Done.", rows: [3, 4, 5, 6, 7, 8])))
        let all = page + [toolRow(7, call: "c2"), assistantRow(8, "Done.", calls: [])]
        transcript.installRereadPage(all, ticket: transcript.beginReread(), reachesStart: true)
        #expect(copies(transcript, "Looking further.") == 1)
        #expect(toolRows(transcript, call: "c1") == 1 && toolRows(transcript, call: "c2") == 1)
        #expect(transcript.historyCount == transcript.items.count)
        expectWellFormed(transcript)
    }

    /// The page settles the earlier turn whose read failed, and keeps the open turn's rows
    /// out even when that turn's text repeats the earlier turn's (rows up to its receipt).
    @Test func aPageMidTurnSettlesTheEarlierTurn() {
        var transcript = idle()
        let first = transcript.appendUserPrompt("one")
        transcript.promptAnswered(itemID: first, status: "streaming", userRowID: 3)
        transcript.apply(event("message.start"))
        transcript.apply(event("message.delta", ["text": "Let me look."]))
        transcript.apply(event("message.complete", completePayload("Let me look.", rows: [3, 4])))
        _ = transcript.beginReread()  // it fails

        let second = transcript.appendUserPrompt("two")
        transcript.promptAnswered(itemID: second, status: "streaming", userRowID: 5)
        transcript.apply(event("message.start"))
        transcript.apply(event("tool.start", ["tool_id": "c1", "name": "web_search"]))
        transcript.apply(event("tool.complete", ["tool_id": "c1", "name": "web_search"]))
        transcript.apply(event("message.interim", ["text": "Let me look.", "already_streamed": false]))
        // A retry of the first turn's read lands now.
        let page = [storedRow(id: 1), storedRow(id: 2), storedRow(id: 3, role: "user", text: "one"),
                    assistantRow(4, "Let me look.", calls: []), storedRow(id: 5, role: "user", text: "two"),
                    assistantRow(6, "Let me look.", calls: ["c1"]), toolRow(7, call: "c1")]
        transcript.installRereadPage(page, ticket: transcript.beginReread(), reachesStart: true)
        #expect(copies(transcript, "Let me look.") == 2, "one per turn")
        #expect(transcript.items.filter { $0.text == "one" }.count == 1)
        #expect(transcript.items.filter { $0.text == "two" }.count == 1)
        #expect(toolRows(transcript, call: "c1") == 1)
        #expect(transcript.items.contains { $0.rowID == 4 }, "the first turn's stored reply shows")
    }
}

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct MidTurnRetryTests {
    /// Path B through the session: a retry left over from a failed turn-end read fires
    /// in the middle of the next turn, after it stored a round.
    @Test func aRetryFiringMidTurnShowsNothingTwice() async throws {
        let server = PagedServer(store: FakeMessageStore(rows: [storedRow(id: 1), storedRow(id: 2)]))
        let (connection, transport) = try await server.connect(log: FrameLog())
        let session = try await connection.open(SessionSummary(id: "stored-1"))
        await settle(session)
        session.rereadRetryDelays = [.milliseconds(600)]
        let sid = session.sessionID

        server.store.setMode(.offline)
        try await session.send("one")  // row 3
        transport.sendEvent("message.start", sessionID: sid, seq: 1)
        transport.sendEvent("message.delta", sessionID: sid, seq: 2, payload: ["text": "first reply"])
        server.store.append([storedRow(id: 4, text: "first reply")])
        transport.sendEvent("message.complete", sessionID: sid, seq: 3, payload: completePayload("first reply", rows: [3, 4]))
        #expect(await eventually { session.rereadRetry != nil && session.rereadTask == nil })
        server.store.setMode(.paged)

        // The next turn starts at once and stores a round before the retry fires.
        try await session.send("two")  // row 5, written at submit
        await settle(session)  // the answer's own read, before the turn starts
        transport.sendEvent("message.start", sessionID: sid, seq: 4)
        transport.sendEvent("tool.start", sessionID: sid, seq: 5, payload: ["tool_id": "c1", "name": "web_search"])
        transport.sendEvent("tool.complete", sessionID: sid, seq: 6, payload: ["tool_id": "c1", "name": "web_search"])
        transport.sendEvent("message.delta", sessionID: sid, seq: 7, payload: ["text": "\n\nLooking further."])
        transport.sendEvent("tool.generating", sessionID: sid, seq: 8, payload: ["name": "web_search"])
        // Hermes stores the round after streaming it.
        #expect(await eventually { copies(session.transcript, "Looking further.") == 1 && toolRows(session.transcript, call: "c1") == 1 })
        server.store.append([assistantRow(6, "", calls: ["c1"]),
                             toolRow(7, call: "c1"), assistantRow(8, "Looking further.", calls: ["c2"])])
        transport.sendEvent("message.interim", sessionID: sid, seq: 9,
                            payload: ["text": "Looking further.", "already_streamed": true])
        transport.sendEvent("tool.start", sessionID: sid, seq: 10, payload: ["tool_id": "c2", "name": "web_search"])
        #expect(await eventually { toolRows(session.transcript, call: "c2") == 1 })

        let before = server.store.queries.count
        #expect(await eventually(seconds: 5) { server.store.queries.count > before && session.rereadTask == nil
            && session.rereadRetry == nil })
        #expect(session.transcript.isRunning)
        #expect(copies(session.transcript, "Looking further.") == 1)
        #expect(toolRows(session.transcript, call: "c1") == 1)
        #expect(session.transcript.items.contains { $0.rowID == 4 }, "the retry settled the first turn")
        #expect(copies(session.transcript, "first reply") == 1)
        withExtendedLifetime(connection) {}
    }
}
