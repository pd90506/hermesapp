import Foundation
import HermesProtocol
import Testing

@testable import HermesKit

/// Rows only this device shows (notes, `/btw` and `/bg` answers) in a transcript
/// whose stored rows are re-read, and the stored-row projection of steers, file
/// references and tool calls (`docs/protocol.md` §4.1).
@Suite struct TranscriptLocalRowsTests {
    private func event(_ type: String, _ payload: JSONValue? = nil) -> GatewayEvent {
        GatewayEvent(type: type, sessionID: "sid-1", payload: payload)
    }

    /// One turn: a prompt stored at submit (row `userRow`), its reply stored before
    /// `message.complete`, then the re-read that settles both.
    private func runTurn(_ transcript: inout Transcript, prompt: String, reply: String, userRow: Int,
                         noteMidTurn: String? = nil, stored: [StoredMessage]) {
        let id = transcript.appendUserPrompt(prompt)
        transcript.promptAnswered(itemID: id, status: "streaming", userRowID: userRow)
        transcript.apply(event("message.start"))
        transcript.apply(event("message.delta", ["text": .string(reply)]))
        if let noteMidTurn { transcript.appendNote(noteMidTurn) }
        transcript.apply(event("message.complete", ["text": .string(reply), "status": "complete"]))
        #expect(transcript.needsReread)
        let ticket = transcript.beginReread()
        transcript.installRereadPage(stored, ticket: ticket, reachesStart: true)
    }

    @Test func aNoteKeepsItsPlaceWhenLaterTurnsAreReRead() {
        var transcript = Transcript()
        var rows = [storedRow(id: 1), storedRow(id: 2)]
        transcript.installLatestPage(rows, hasOlder: false)
        transcript.appendNote("Saved transcript.")
        #expect(transcript.historyCount == 3)  // nothing unsettled ahead of it

        rows += [storedRow(id: 3, text: "next"), storedRow(id: 4, text: "reply")]
        runTurn(&transcript, prompt: "next", reply: "reply", userRow: 3, stored: rows)
        #expect(transcript.items.map(\.text) == ["user 1", "assistant 2", "Saved transcript.", "next", "reply"])

        rows += [storedRow(id: 5, text: "again"), storedRow(id: 6, text: "more")]
        runTurn(&transcript, prompt: "again", reply: "more", userRow: 5, stored: rows)
        #expect(transcript.items.map(\.text) == ["user 1", "assistant 2", "Saved transcript.", "next", "reply",
                                                 "again", "more"])
        #expect(transcript.items.allSatisfy { $0.rowID != nil || $0.role == .system })
        expectWellFormed(transcript)
    }

    /// Older pages go above a note, which stays after the stored row it followed,
    /// also through the next re-read.
    @Test func aNoteSurvivesLoadingOlderPages() {
        var transcript = Transcript()
        transcript.installLatestPage([storedRow(id: 3), storedRow(id: 4)], hasOlder: true)
        transcript.appendNote("Saved transcript.")
        transcript.prependOlderPage([storedRow(id: 1), storedRow(id: 2)], hasOlder: false)

        #expect(transcript.items.map(\.text) == ["user 1", "assistant 2", "user 3", "assistant 4", "Saved transcript."])
        expectWellFormed(transcript)

        let rows = (1...6).map { storedRow(id: $0) }
        runTurn(&transcript, prompt: "user 5", reply: "assistant 6", userRow: 5, stored: rows)
        #expect(transcript.items.map(\.text) == ["user 1", "assistant 2", "user 3", "assistant 4", "Saved transcript.",
                                                 "user 5", "assistant 6"])
        expectWellFormed(transcript)
    }

    /// A note added while a turn streams goes below that turn once its rows are stored.
    @Test func aNoteAddedMidTurnFollowsThatTurn() {
        var transcript = Transcript()
        transcript.installLatestPage([], hasOlder: false)
        let rows = [storedRow(id: 1, text: "go"), storedRow(id: 2, text: "done")]
        runTurn(&transcript, prompt: "go", reply: "done", userRow: 1, noteMidTurn: "Tokens: 12", stored: rows)

        #expect(transcript.items.map(\.text) == ["go", "done", "Tokens: 12"])
        #expect(transcript.historyCount == 3)
        expectWellFormed(transcript)
    }

    /// A `/btw` asked while the history loads follows it, answer included.
    @Test func aSideQuestionAskedWhileLoadingFollowsTheHistory() {
        var transcript = Transcript()
        transcript.beginSideQuestion(taskID: "btw_1", question: "which branch?")
        #expect(transcript.historyCount == 0)
        transcript.installLatestPage([storedRow(id: 1), storedRow(id: 2)], hasOlder: false)
        transcript.apply(event("btw.complete", ["task_id": "btw_1", "text": "main"]))

        #expect(transcript.items.map(\.id) == ["row-1", "row-2", "btw-btw_1"])
        #expect(transcript.historyCount == 3)
        #expect(transcript.items[2].sideQuestion?.answer == "main")
        expectWellFormed(transcript)
    }

    /// A note added while a turn runs with nothing shown yet (a tool being drafted)
    /// still goes below that turn's rows.
    @Test func aNoteDuringATurnWithNoLiveRowsFollowsIt() {
        var transcript = Transcript()
        transcript.installLatestPage([storedRow(id: 1), storedRow(id: 2)], hasOlder: false)
        transcript.apply(event("tool.generating", ["name": "terminal"]))
        transcript.appendNote("Tokens: 12")
        transcript.apply(event("message.delta", ["text": "done"]))
        transcript.apply(event("message.complete", ["text": "done", "status": "complete"]))
        let ticket = transcript.beginReread()
        transcript.installRereadPage([storedRow(id: 1), storedRow(id: 2), storedRow(id: 3, role: "assistant", text: "done")],
                                     ticket: ticket, reachesStart: true)

        #expect(transcript.items.map(\.text) == ["user 1", "assistant 2", "done", "Tokens: 12"])
        expectWellFormed(transcript)
    }

    /// A failed turn's partial reply is not stored (`session_auto_continue.py:524-552`):
    /// the part a note sealed off stays too, not only the segment still streaming.
    @Test func aFailedReplySplitByANoteStaysWhole() {
        var transcript = Transcript()
        transcript.installLatestPage([], hasOlder: false)
        let id = transcript.appendUserPrompt("go")
        transcript.promptAnswered(itemID: id, status: "streaming", userRowID: 1)
        transcript.apply(event("message.start"))
        transcript.apply(event("message.delta", ["text": "Part one."]))
        transcript.appendNote("Tokens: 12")
        transcript.apply(event("message.delta", ["text": " Part two."]))
        transcript.apply(event("message.complete", ["text": "", "status": "error", "error": "provider down"]))
        let ticket = transcript.beginReread()
        transcript.installRereadPage([storedRow(id: 1, text: "go")], ticket: ticket, reachesStart: true)

        #expect(transcript.items.map(\.text) == ["go", "Part one.", "Tokens: 12", " Part two."])
        #expect(transcript.lastError == "provider down")
        expectWellFormed(transcript)
    }

    /// The final text of a reply split between words by a tool is not added again.
    @Test func aReplySplitBetweenWordsIsNotRepeated() {
        var transcript = Transcript()
        transcript.appendUserPrompt("q")
        transcript.apply(event("message.delta", ["text": "foo"]))
        transcript.apply(event("tool.start", ["tool_id": "t1", "name": "terminal"]))
        transcript.apply(event("tool.complete", ["tool_id": "t1", "name": "terminal"]))
        transcript.apply(event("message.delta", ["text": "bar"]))
        transcript.appendNote("note")
        transcript.apply(event("message.complete", ["text": "foo bar", "status": "complete"]))

        #expect(transcript.items.filter { $0.role == .assistant }.map(\.text) == ["foo", "bar"])
    }

    // MARK: Stored rows

    /// Steers carry `display_kind: "steer"` and their own words as `display_content`
    /// (`web_routers/sessions.py:663-667`); a prompt with files starts with one
    /// `@file:` line each (`ChatSession.send`); edit tools keep their output
    /// (`session_history.py:331`).
    @Test func storedRowsShowSteersFilesAndToolCalls() throws {
        let files = storedRow(id: 1, role: "user",
                              text: "@file:attachments/report.pdf\n@file:\"attachments/my notes.txt\"\n\nSummarise these")
        var call = StoredMessage(id: 2, role: "assistant", content: .string(""))
        call.toolCalls = [["id": "call_1", "function": ["name": "write_file", "arguments": #"{"path":"notes.md"}"#]]]
        var tool = StoredMessage(id: 3, role: "tool", content: .string(#"{"bytes": 12}"#))
        tool.toolCallID = "call_1"
        var steer = StoredMessage(id: 4, role: "user", content: .string("[STEER]\nmake it shorter\n[/STEER]"))
        steer.displayKind = "steer"
        steer.displayContent = .string("make it shorter")
        let prose = storedRow(id: 5, role: "user", text: "see @file:notes.md please")

        var transcript = Transcript()
        transcript.installLatestPage([files, call, tool, steer, prose], hasOlder: false)

        let items = transcript.items
        #expect(items.map(\.text) == ["Summarise these", "", "make it shorter", "see @file:notes.md please"])
        #expect(items[0].attachments == ["report.pdf", "my notes.txt"])
        let activity = try #require(items[1].tool)
        #expect(activity.name == "write_file" && activity.phase == .complete && activity.toolID == "call_1")
        #expect(activity.args?["path"] == "notes.md" && activity.output == #"{"bytes": 12}"#)
        #expect(items[2].isSteer && !items[3].isSteer && items[3].attachments.isEmpty)
    }

    @Test func leadingReferencesOnly() {
        #expect(AttachmentRefs.splitLeading("@folder:src\n@file:`a b.txt`\nhi") == ("hi", ["src", "a b.txt"]))
        #expect(AttachmentRefs.splitLeading("hi\n@file:a.txt") == ("hi\n@file:a.txt", []))
        #expect(AttachmentRefs.splitLeading("@file:a.txt b") == ("@file:a.txt b", []))  // not a lone reference
        #expect(AttachmentRefs.displayName("attachments/report-2.pdf") == "report-2.pdf")
    }
}
