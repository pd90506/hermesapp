import Foundation
import HermesProtocol
import Testing

@testable import HermesKit

// Issue #5: a sent prompt shows exactly once at every point of its turn, whatever
// order the submit answer, `message.start`, the re-read page and `message.complete`
// arrive in; the wait for the reply is a real waiting state; an assistant row with
// no text has no action bar.

private func event(_ type: String, _ payload: JSONValue? = nil) -> GatewayEvent {
    GatewayEvent(type: type, sessionID: "sid-1", payload: payload)
}

private func copies(_ transcript: Transcript, _ text: String) -> Int {
    transcript.items.filter { $0.text == text }.count
}

/// An idle chat whose history is rows 1...2 (prompt, reply), every row read.
private func idle() -> Transcript {
    var transcript = Transcript()
    transcript.installLatestPage([storedRow(id: 1), storedRow(id: 2)], hasOlder: false)
    return transcript
}

@Suite struct PromptShowsOnceTests {
    /// The race in the issue: the answer asks for a re-read, `message.start` arrives
    /// while it is in flight, and the page lands holding the prompt's row. Before the
    /// fix the read was not quiet, so the bubble stayed beside its stored row for the
    /// whole turn.
    @Test func answerThenStartDuringTheReread() {
        var transcript = idle()
        var rows = [storedRow(id: 1), storedRow(id: 2)]
        let prompt = transcript.appendUserPrompt("hello")
        transcript.promptAnswered(itemID: prompt, status: "streaming", userRowID: 3)
        #expect(transcript.needsReread)
        let ticket = transcript.beginReread()
        transcript.apply(event("message.start"))
        rows.append(storedRow(id: 3, text: "hello"))
        transcript.installRereadPage(rows, ticket: ticket, reachesStart: true)
        #expect(copies(transcript, "hello") == 1, "mid-turn")
        #expect(transcript.items.first { $0.text == "hello" }?.rowID == 3, "the stored row is the one kept")
        expectWellFormed(transcript)

        transcript.apply(event("message.delta", ["text": "hi there"]))
        #expect(copies(transcript, "hello") == 1, "while streaming")
        transcript.apply(event("message.complete", completePayload("hi there", rows: [3, 4])))
        #expect(copies(transcript, "hello") == 1, "at completion")
        rows.append(storedRow(id: 4, text: "hi there"))
        transcript.installRereadPage(rows, ticket: transcript.beginReread(), reachesStart: true)
        #expect(copies(transcript, "hello") == 1, "after the turn's re-read")
        #expect(copies(transcript, "hi there") == 1)
        expectWellFormed(transcript)
    }

    /// The same race when the turn's own re-read then fails: the bubble does not wait
    /// for it, so nothing is left doubled until the next turn or a reopen.
    @Test func answerThenStartWithoutAnotherReread() {
        var transcript = idle()
        let prompt = transcript.appendUserPrompt("hello")
        transcript.promptAnswered(itemID: prompt, status: "streaming", userRowID: 3)
        let ticket = transcript.beginReread()
        transcript.apply(event("message.start"))
        transcript.installRereadPage([storedRow(id: 1), storedRow(id: 2), storedRow(id: 3, text: "hello")],
                                     ticket: ticket, reachesStart: true)
        transcript.apply(event("message.delta", ["text": "hi"]))
        transcript.apply(event("message.complete", completePayload("hi", rows: [3, 4])))
        #expect(copies(transcript, "hello") == 1)
    }

    /// A fast reply: `message.complete` and the re-read it asks for land before the
    /// submit answer. Without the answer there is no row id, so the bubble stays next
    /// to the stored row (never hide unproven content); the answer proves it, and it
    /// goes at once rather than after another round trip.
    @Test func completeBeforeTheAnswer() {
        var transcript = idle()
        let prompt = transcript.appendUserPrompt("hello")
        transcript.apply(event("message.start"))
        transcript.apply(event("message.delta", ["text": "quick"]))
        transcript.apply(event("message.complete", completePayload("quick", rows: [3, 4])))
        let rows = [storedRow(id: 1), storedRow(id: 2), storedRow(id: 3, text: "hello"), storedRow(id: 4, text: "quick")]
        transcript.installRereadPage(rows, ticket: transcript.beginReread(), reachesStart: true)
        #expect(copies(transcript, "hello") == 2, "no answer yet: no proof, the bubble stays")
        transcript.promptAnswered(itemID: prompt, status: "streaming", userRowID: 3)
        #expect(copies(transcript, "hello") == 1, "the answer's row id proves the stored row is this prompt")
        #expect(copies(transcript, "quick") == 1)
        expectWellFormed(transcript)
    }

    /// `message.start` before the answer, the page after it.
    @Test func startThenAnswerThenPage() {
        var transcript = idle()
        let prompt = transcript.appendUserPrompt("hello")
        transcript.apply(event("message.start"))
        transcript.promptAnswered(itemID: prompt, status: "streaming", userRowID: 3)
        let ticket = transcript.beginReread()
        transcript.installRereadPage([storedRow(id: 1), storedRow(id: 2), storedRow(id: 3, text: "hello")],
                                     ticket: ticket, reachesStart: true)
        #expect(copies(transcript, "hello") == 1)
    }

    /// The row id is the only proof: a page that does not show the prompt's row (it
    /// was not stored yet, or the read covered other rows) leaves the bubble.
    @Test func aBubbleWhoseRowIsNotShownStays() {
        var transcript = idle()
        let prompt = transcript.appendUserPrompt("hello")
        transcript.promptAnswered(itemID: prompt, status: "streaming", userRowID: 3)
        let ticket = transcript.beginReread()
        transcript.apply(event("message.start"))
        transcript.installRereadPage([storedRow(id: 1), storedRow(id: 2)], ticket: ticket, reachesStart: true)
        #expect(copies(transcript, "hello") == 1)
        #expect(transcript.items.first { $0.text == "hello" }?.rowID == nil, "still the live bubble")
        // A row with the same text but another id proves nothing either.
        transcript.installRereadPage([storedRow(id: 1), storedRow(id: 2), storedRow(id: 5, role: "user", text: "hello")],
                                     ticket: transcript.beginReread(), reachesStart: true)
        #expect(transcript.items.contains { $0.text == "hello" && $0.rowID == nil }, "text is never matched")
    }

    /// Queued and steered sends during a running turn get no `user_row_id`
    /// (`contracts/prompt_voice.py:69-71`). Without that proof the bubble is never
    /// dropped mid-turn; it settles after the quiet re-reads, as before, and shows
    /// once in the end.
    @Test(arguments: ["queued", "steered"])
    func sendsDuringATurnWithoutRowIDs(status: String) {
        var transcript = idle()
        let first = transcript.appendUserPrompt("first")
        transcript.promptAnswered(itemID: first, status: "streaming", userRowID: 3)
        transcript.apply(event("message.start"))
        transcript.apply(event("message.delta", ["text": "working"]))
        let second = transcript.appendUserPrompt("second")
        transcript.promptAnswered(itemID: second, status: status)
        var rows = [storedRow(id: 1), storedRow(id: 2), storedRow(id: 3, text: "first"), storedRow(id: 5, role: "user", text: "second")]
        transcript.installRereadPage(rows, ticket: transcript.beginReread(), reachesStart: true)
        #expect(transcript.items.contains { $0.text == "second" && $0.rowID == nil }, "no proof yet: the bubble stays")
        #expect(copies(transcript, "first") == 1, "the first prompt is proven by its row id")

        transcript.apply(event("message.complete", completePayload("working", rows: [3, 4])))
        rows = [storedRow(id: 1), storedRow(id: 2), storedRow(id: 3, text: "first"), storedRow(id: 4, text: "working"),
                storedRow(id: 5, role: "user", text: "second")]
        for _ in 0..<3 where transcript.needsReread {
            transcript.installRereadPage(rows, ticket: transcript.beginReread(), reachesStart: true)
        }
        #expect(copies(transcript, "second") == 1, "settled by the quiet re-reads")
        #expect(copies(transcript, "first") == 1)
        expectWellFormed(transcript)
    }
}

@Suite struct WaitingRowTests {
    private let sent = Date(timeIntervalSince1970: 1_000)

    @Test func showsFromTheSendUntilTheFirstText() {
        var transcript = idle()
        #expect(transcript.waiting == nil)
        let prompt = transcript.appendUserPrompt("hello", sentAt: sent)
        #expect(transcript.waiting == Transcript.Waiting(since: sent, hint: nil), "before the answer")
        #expect(transcript.waiting?.label == "Thinking…")
        transcript.promptAnswered(itemID: prompt, status: "streaming", userRowID: 3)
        #expect(transcript.waiting?.since == sent, "after the answer")
        transcript.apply(event("message.start"))
        #expect(transcript.waiting?.since == sent, "after message.start: counted from the send, not the start")
        transcript.apply(event("reasoning.delta", ["text": "Let me think"]))
        #expect(transcript.waiting != nil, "reasoning alone is not the reply")
        transcript.apply(event("message.delta", ["text": " "]))
        #expect(transcript.waiting != nil, "whitespace is not visible text")
        transcript.apply(event("message.delta", ["text": "Hi"]))
        #expect(transcript.waiting == nil, "the reply shows")
        transcript.apply(event("message.complete", completePayload("Hi", rows: [3, 4])))
        #expect(transcript.waiting == nil)
    }

    @Test func aToolRowEndsTheWait() {
        var transcript = idle()
        transcript.appendUserPrompt("run it", sentAt: sent)
        transcript.apply(event("message.start"))
        transcript.apply(event("tool.start", ["tool_id": "t1", "name": "terminal"]))
        #expect(transcript.waiting == nil)
    }

    @Test func outlivesTheBubbleItWaitsOn() {
        // The race fix drops the bubble mid-wait: the row keeps counting from the send.
        var transcript = idle()
        let prompt = transcript.appendUserPrompt("hello", sentAt: sent)
        transcript.promptAnswered(itemID: prompt, status: "streaming", userRowID: 3)
        let ticket = transcript.beginReread()
        transcript.apply(event("message.start"))
        transcript.installRereadPage([storedRow(id: 1), storedRow(id: 2), storedRow(id: 3, text: "hello")],
                                     ticket: ticket, reachesStart: true)
        #expect(transcript.waiting?.since == sent)
    }

    @Test func stopsWhenTheTurnEndsWithoutText() {
        var interrupted = idle()
        interrupted.appendUserPrompt("hello", sentAt: sent)
        interrupted.apply(event("message.start"))
        var payload = completePayload("", rows: [3]).objectValue ?? [:]
        payload["status"] = "interrupted"
        interrupted.apply(event("message.complete", .object(payload)))
        #expect(interrupted.waiting == nil)

        var failed = idle()
        let prompt = failed.appendUserPrompt("hello", sentAt: sent)
        failed.submitFailed("no connection", itemID: prompt)
        #expect(failed.waiting == nil)
    }

    @Test func aTurnThisChatDidNotSendHasNoSendTime() throws {
        var transcript = idle()
        transcript.apply(event("message.start"))
        let waiting = try #require(transcript.waiting)
        #expect(waiting.since == nil)
    }

    /// Hints override "Thinking…": status, then provider wait, then the drafted tool,
    /// then the slow agent-build notice.
    @Test func hintPriority() {
        var transcript = idle()
        transcript.appendUserPrompt("hello", sentAt: sent)
        transcript.apply(event("notification.show", ["text": "Still starting the agent", "key": "agent-build-slow",
                                                       "kind": "agent"]))
        #expect(transcript.waiting?.hint == "Still starting the agent")
        transcript.apply(event("notification.show", ["text": "Other notice", "key": "credits"]))
        #expect(transcript.waiting?.hint == "Still starting the agent", "other notices are not wait hints")
        transcript.apply(event("notification.clear", ["key": "agent-build-slow"]))
        #expect(transcript.waiting?.hint == nil)
        transcript.apply(event("notification.show", ["text": "Still starting the agent", "key": "agent-build-slow"]))

        transcript.apply(event("message.start"))
        transcript.apply(event("tool.generating", ["name": "patch"]))
        #expect(transcript.waiting?.hint == "Drafting patch…", "drafting beats the build notice")
        transcript.apply(event("thinking.delta", ["text": "⏳ still waiting on the provider (45s)"]))
        #expect(transcript.waiting?.hint == "⏳ still waiting on the provider (45s)", "provider wait beats the rest")
        transcript.apply(event("status.update", ["kind": "compacting", "text": "Summarizing thread"]))
        #expect(transcript.waiting?.hint == "Summarizing thread", "status beats everything")
        #expect(transcript.waiting?.label == "Summarizing thread")
    }

    @Test func theLabelIsNeverABareEllipsis() {
        #expect(Transcript.Waiting(since: nil, hint: nil).label == "Thinking…")
        #expect(Transcript.Waiting(since: nil, hint: nil).label != "…")
    }

    @Test func elapsedText() {
        let start = Date(timeIntervalSince1970: 0)
        #expect(Transcript.Waiting.elapsedText(from: start, to: start) == "0s")
        #expect(Transcript.Waiting.elapsedText(from: start, to: start.addingTimeInterval(4.9)) == "4s")
        #expect(Transcript.Waiting.elapsedText(from: start, to: start.addingTimeInterval(65)) == "1m 05s")
        #expect(Transcript.Waiting.elapsedText(from: start, to: start.addingTimeInterval(3_725)) == "1h 02m")
        #expect(Transcript.Waiting.elapsedText(from: start, to: start.addingTimeInterval(-3)) == "0s")
    }
}

@Suite struct ActionBarRowTests {
    @Test func anEmptyReplyIsNotTheNewestMessage() {
        var transcript = idle()
        transcript.appendUserPrompt("hello")
        transcript.apply(event("message.start"))
        let prompt = transcript.items.last { $0.role == .user }
        #expect(ConversationMarkdown.newestMessageID(in: transcript.items) == prompt?.id,
                "the prompt keeps its bar while the reply is empty")
        let reply = transcript.items.last { $0.role == .assistant }
        #expect(reply.map(ConversationMarkdown.hasActionBar) == false)

        transcript.apply(event("reasoning.delta", ["text": "thinking"]))
        #expect(ConversationMarkdown.newestMessageID(in: transcript.items) == prompt?.id, "reasoning has nothing to copy")
        transcript.apply(event("message.delta", ["text": "Hi"]))
        let replied = transcript.items.last { $0.role == .assistant }
        #expect(ConversationMarkdown.newestMessageID(in: transcript.items) == replied?.id, "text arrived: the bar moves")
        #expect(replied.map(ConversationMarkdown.hasActionBar) == true)
    }
}

// Review round 2: the waiting row and the running state end with the turn, whatever
// way it ends; "Interrupted" shows; only output since the send counts.

private func complete(_ text: String, status: String, rows: [Int]) -> JSONValue {
    var payload = completePayload(text, rows: rows).objectValue ?? [:]
    payload["status"] = .string(status)
    if status == "error" { payload["error"] = "agent initialization failed" }
    return .object(payload)
}

@Suite struct TurnEndTests {
    private let sent = Date(timeIntervalSince1970: 2_000)

    /// M1: Stop during a cold agent build. Hermes answered `streaming`, then sends only
    /// `error` ("Turn cancelled before the agent was ready", `methods_prompt.py:625-635`).
    @Test func anErrorBeforeTheTurnStartsEndsTheWait() {
        var transcript = idle()
        let prompt = transcript.appendUserPrompt("hello", sentAt: sent)
        transcript.promptAnswered(itemID: prompt, status: "streaming", userRowID: 3)
        transcript.apply(event("error", ["message": "Turn cancelled before the agent was ready"]))
        #expect(transcript.waiting == nil)
        #expect(!transcript.isRunning)
        #expect(transcript.lastError == "Turn cancelled before the agent was ready")
        #expect(copies(transcript, "hello") == 1, "the bubble stays: nothing proves its row")
    }

    /// The same error before the answer: the submit is still in flight and its answer
    /// decides; nothing ends yet.
    @Test func anErrorBeforeTheAnswerWaitsForTheAnswer() {
        var transcript = idle()
        let prompt = transcript.appendUserPrompt("hello", sentAt: sent)
        transcript.apply(event("error", ["message": "something else"]))
        #expect(transcript.isRunning)
        transcript.submitFailed("no connection", itemID: prompt)
        #expect(!transcript.isRunning)
        #expect(transcript.waiting == nil)
    }

    /// A failed pending model switch sends `error` at turn start and the turn goes on
    /// (`session_compression.py:197-211`, `prompt_turn.py:685`). The `error` closes the
    /// turn while it has shown nothing (R3); its next streamed event opens it again, and
    /// nothing of its reply is lost. With show-reasoning off the first is the API call's
    /// `thinking.delta` spinner frame (round 5, S1).
    @Test(arguments: ["message.delta", "reasoning.delta", "thinking.delta"])
    func anErrorAtTurnStartDoesNotLoseTheTurn(next: String) throws {
        var transcript = idle()
        let prompt = transcript.appendUserPrompt("hello", sentAt: sent)
        transcript.promptAnswered(itemID: prompt, status: "streaming", userRowID: 3)
        transcript.apply(event("message.start"))
        transcript.apply(event("error", ["message": "Could not switch model: boom"]))
        #expect(transcript.lastError == "Could not switch model: boom")
        transcript.apply(event(next, ["text": "Hi"]))
        #expect(transcript.isRunning, "the turn's next event brings running back")
        transcript.apply(event("message.delta", ["text": " there"]))
        transcript.apply(event("message.complete", completePayload("Hi there", rows: [3, 4])))
        #expect(!transcript.isRunning)
        let reply = try #require(transcript.items.last { $0.role == .assistant && $0.rowID == nil })
        #expect(reply.text.hasSuffix(" there"))
        #expect(next != "reasoning.delta" || reply.reasoning == "Hi", "the reasoning is kept")
        #expect(copies(transcript, "hello") == 1)
    }

    /// M1: a refused `@` context: `message.start`, `error`, then the turn body's
    /// closing `session.info` with `running: false` (`prompt_turn.py:715-718`, `:1196-1225`).
    /// The `error` already ends the empty turn (R3); the report changes nothing more.
    @Test func aTurnEndedWithoutCompleteEndsWithTheIdleReport() {
        var transcript = idle()
        let prompt = transcript.appendUserPrompt("read @secret", sentAt: sent)
        transcript.promptAnswered(itemID: prompt, status: "streaming", userRowID: 3)
        transcript.apply(event("message.start"))
        transcript.apply(event("error", ["message": "Context injection refused."]))
        #expect(transcript.waiting == nil)
        #expect(!transcript.isRunning)
        transcript.serverReportsIdle()
        #expect(transcript.waiting == nil)
        #expect(!transcript.isRunning)
        #expect(!transcript.items.contains { $0.role == .assistant && $0.rowID == nil }, "no empty reply row is left")
        #expect(copies(transcript, "read @secret") == 1)
    }

    /// A failed build: `error`, then a `message.complete` with `status: error`.
    @Test func anErrorThenAnErrorComplete() {
        var transcript = idle()
        let prompt = transcript.appendUserPrompt("hello", sentAt: sent)
        transcript.promptAnswered(itemID: prompt, status: "streaming", userRowID: 3)
        transcript.apply(event("error", ["message": "agent initialization failed"]))
        // `_emit_terminal_turn_error`'s frame: no `persisted_turn` (`session_auto_continue.py:578-583`).
        transcript.apply(event("message.complete", ["text": "Agent failed to start.", "status": "error",
                                                    "error": "agent initialization failed", "recoverable": true]))
        #expect(!transcript.isRunning)
        #expect(transcript.waiting == nil)
        #expect(copies(transcript, "Agent failed to start.") == 1)
    }

    /// The idle report never cuts a turn that shows output: that one ends with its
    /// own `message.complete`.
    @Test func theIdleReportLeavesATurnWithOutput() {
        var transcript = idle()
        let prompt = transcript.appendUserPrompt("hello", sentAt: sent)
        transcript.promptAnswered(itemID: prompt, status: "streaming", userRowID: 3)
        transcript.apply(event("message.start"))
        transcript.apply(event("message.delta", ["text": "Hi"]))
        transcript.serverReportsIdle()
        #expect(transcript.isRunning)
        #expect(copies(transcript, "Hi") == 1)
    }

    /// M2: a revisit (or a reclaimed runtime) that finds the session idle before any
    /// `message.start` arrived here.
    @Test func aRevisitThatFindsTheSessionIdleEndsTheWait() {
        var transcript = idle()
        let prompt = transcript.appendUserPrompt("hello", sentAt: sent)
        transcript.promptAnswered(itemID: prompt, status: "streaming", userRowID: 3)
        transcript.reconcileRunning(false)
        #expect(!transcript.isRunning)
        #expect(transcript.waiting == nil)
    }

    @Test func aRevisitKeepsAnUnansweredSubmit() {
        var transcript = idle()
        transcript.appendUserPrompt("hello", sentAt: sent)
        transcript.reconcileRunning(false)
        #expect(transcript.isRunning, "the submit's answer decides")
        #expect(transcript.waiting?.since == sent)
    }

    /// S1: Stop before any text, through the reducer: the reply shows "Interrupted" and
    /// keeps it across re-reads, after the turn's stored prompt.
    @Test func stopBeforeAnyTextShowsInterrupted() throws {
        var transcript = idle()
        var rows = [storedRow(id: 1), storedRow(id: 2)]
        let prompt = transcript.appendUserPrompt("hello", sentAt: sent)
        transcript.promptAnswered(itemID: prompt, status: "streaming", userRowID: 3)
        transcript.apply(event("message.start"))
        transcript.apply(event("message.complete", complete("", status: "interrupted", rows: [3])))
        let mark = try #require(transcript.items.last { $0.outcome == "interrupted" })
        #expect(mark.role == .assistant && mark.text.isEmpty)
        #expect(!ConversationMarkdown.hasActionBar(mark))
        #expect(transcript.waiting == nil)
        #expect(!transcript.isRunning)

        rows.append(storedRow(id: 3, text: "hello"))
        transcript.installRereadPage(rows, ticket: transcript.beginReread(), reachesStart: true)
        let order = transcript.items.map(\.id)
        let markIndex = try #require(order.firstIndex(of: mark.id), "the mark survives the re-read")
        let promptIndex = try #require(transcript.items.firstIndex { $0.rowID == 3 })
        #expect(markIndex == promptIndex + 1, "right after its prompt")
        #expect(copies(transcript, "hello") == 1)

        // The next turn goes below it.
        let next = transcript.appendUserPrompt("again")
        transcript.promptAnswered(itemID: next, status: "streaming", userRowID: 5)
        transcript.apply(event("message.start"))
        transcript.apply(event("message.delta", ["text": "ok"]))
        transcript.apply(event("message.complete", completePayload("ok", rows: [5, 6])))
        rows += [storedRow(id: 5, text: "again"), storedRow(id: 6, text: "ok")]
        transcript.installRereadPage(rows, ticket: transcript.beginReread(), reachesStart: true)
        let after = try #require(transcript.items.firstIndex { $0.id == mark.id })
        let nextPrompt = try #require(transcript.items.firstIndex { $0.rowID == 5 })
        #expect(after < nextPrompt)
        expectWellFormed(transcript)
    }

    /// S2: an earlier turn that failed leaves its partial reply live (unstored). It is
    /// not the new prompt's reply and must not end its wait.
    @Test func anEarlierFailedReplyDoesNotEndANewWait() {
        var transcript = idle()
        let first = transcript.appendUserPrompt("first")
        transcript.promptAnswered(itemID: first, status: "streaming", userRowID: 3)
        transcript.apply(event("message.start"))
        transcript.apply(event("message.delta", ["text": "partial answer"]))
        transcript.apply(event("message.complete", complete("partial answer", status: "error", rows: [3])))
        #expect(copies(transcript, "partial answer") == 1)

        let second = transcript.appendUserPrompt("second", sentAt: sent)
        transcript.promptAnswered(itemID: second, status: "streaming", userRowID: 5)
        let ticket = transcript.beginReread()
        transcript.apply(event("message.start"))
        transcript.installRereadPage([storedRow(id: 1), storedRow(id: 2), storedRow(id: 3, text: "first"),
                                      storedRow(id: 5, text: "second")], ticket: ticket, reachesStart: true)
        #expect(copies(transcript, "second") == 1, "the bubble went by its row id")
        #expect(copies(transcript, "partial answer") == 1, "the failed reply stays")
        #expect(transcript.waiting?.since == sent, "the new prompt is still waiting")
    }

    /// S5: a prompt sent just before the running turn completes keeps its waiting row
    /// and its send time through that completion and into its own turn.
    @Test func aPromptSentJustBeforeTheTurnEndsKeepsItsWait() {
        var transcript = idle()
        let first = transcript.appendUserPrompt("first")
        transcript.promptAnswered(itemID: first, status: "streaming", userRowID: 3)
        transcript.apply(event("message.start"))
        transcript.apply(event("message.delta", ["text": "first reply"]))
        let second = transcript.appendUserPrompt("second", sentAt: sent)
        transcript.apply(event("message.complete", completePayload("first reply", rows: [3, 4])))
        #expect(transcript.isRunning)
        #expect(transcript.waiting?.since == sent)
        transcript.promptAnswered(itemID: second, status: "streaming", userRowID: 5)
        transcript.apply(event("message.start"))
        #expect(transcript.waiting?.since == sent)
        transcript.apply(event("message.delta", ["text": "second reply"]))
        #expect(transcript.waiting == nil)
    }

    /// A queued prompt keeps the session running between the turn it waited behind and
    /// its own, also across that turn's closing `running: false`.
    @Test func aQueuedPromptKeepsItsWaitBetweenTurns() {
        var transcript = idle()
        let first = transcript.appendUserPrompt("first")
        transcript.promptAnswered(itemID: first, status: "streaming", userRowID: 3)
        transcript.apply(event("message.start"))
        transcript.apply(event("message.delta", ["text": "first reply"]))
        let second = transcript.appendUserPrompt("second", sentAt: sent)
        transcript.promptAnswered(itemID: second, status: "queued")
        transcript.apply(event("message.complete", completePayload("first reply", rows: [3, 4])))
        transcript.serverReportsIdle()
        #expect(transcript.isRunning)
        #expect(transcript.waiting?.since == sent)
        transcript.apply(event("message.start"))
        #expect(transcript.waiting?.since == sent)
    }

    /// A queued prompt whose turn never comes (Hermes merged it or dropped a stale
    /// queue entry, sending nothing, `prompt_turn.py:135-146`) stops keeping the
    /// session running once the quiet re-reads have settled it.
    @Test func aQueuedPromptWhoseTurnNeverComesStopsWaiting() {
        var transcript = idle()
        let first = transcript.appendUserPrompt("first")
        transcript.promptAnswered(itemID: first, status: "streaming", userRowID: 3)
        transcript.apply(event("message.start"))
        transcript.apply(event("message.delta", ["text": "first reply"]))
        let second = transcript.appendUserPrompt("second", sentAt: sent)
        transcript.promptAnswered(itemID: second, status: "queued")
        transcript.apply(event("message.complete", completePayload("first reply", rows: [3, 4])))
        let rows = [storedRow(id: 1), storedRow(id: 2), storedRow(id: 3, text: "first"),
                    storedRow(id: 4, text: "first reply"), storedRow(id: 5, role: "user", text: "second")]
        for _ in 0..<3 where transcript.needsReread {
            transcript.installRereadPage(rows, ticket: transcript.beginReread(), reachesStart: true)
        }
        #expect(!transcript.isRunning)
        #expect(transcript.waiting == nil)
        #expect(copies(transcript, "second") == 1)
    }

    /// A steer joins the running turn: it never waits for a turn of its own.
    @Test func aSteerDoesNotKeepTheSessionRunning() {
        var transcript = idle()
        let first = transcript.appendUserPrompt("first")
        transcript.promptAnswered(itemID: first, status: "streaming", userRowID: 3)
        transcript.apply(event("message.start"))
        let steer = transcript.appendUserPrompt("shorter", displayKind: "steer")
        transcript.promptAnswered(itemID: steer, status: "steered")
        transcript.apply(event("message.delta", ["text": "done"]))
        transcript.apply(event("message.complete", completePayload("done", rows: [3, 4])))
        #expect(!transcript.isRunning)
    }
}

/// The `session.info` wiring: `ChatSession` hands `running: false` to the transcript.
@MainActor
@Suite struct SessionIdleReportTests {
    private func session() throws -> ChatSession {
        let snapshot = try deferredAck(sid: "sid-1", key: "stored-1", count: 0).decode(LiveSessionSnapshot.self)
        return ChatSession(snapshot: snapshot, title: nil, connection: nil)
    }

    @Test func runningFalseEndsATurnThatShowedNothing() throws {
        let session = try session()
        session.apply(event("message.start"))
        #expect(session.transcript.waiting != nil)
        session.apply(event("session.info", ["running": true]))
        #expect(session.transcript.isRunning, "running: true changes nothing")
        session.apply(event("session.info", ["running": false]))
        #expect(!session.transcript.isRunning)
        #expect(session.transcript.waiting == nil)
    }

    @Test func runningFalseLeavesATurnWithOutput() throws {
        let session = try session()
        session.apply(event("message.start"))
        session.apply(event("message.delta", ["text": "Hi"]))
        session.apply(event("session.info", ["running": false]))
        #expect(session.transcript.isRunning, "its message.complete ends it")
    }
}

// Round 3: the running/waiting lifecycle from server facts (review P1-P5).

/// `message.complete` for a stopped turn, without a receipt (`persisted_turn`).
private func stoppedWithoutReceipt() -> JSONValue {
    ["text": "", "status": "interrupted"]
}

@Suite struct LifecycleTests {
    private let sent = Date(timeIntervalSince1970: 3_000)

    /// A reply streaming, then a second prompt sent while it runs.
    private func replyWithTypeAhead() -> (Transcript, String) {
        var transcript = idle()
        let first = transcript.appendUserPrompt("first")
        transcript.promptAnswered(itemID: first, status: "streaming", userRowID: 3)
        transcript.apply(event("message.start"))
        transcript.apply(event("message.delta", ["text": "first reply"]))
        let second = transcript.appendUserPrompt("also this", sentAt: sent)
        return (transcript, second)
    }

    /// P1 (F1): `steered` answered after the turn's `message.complete` and its closing
    /// `running: false` (Hermes checks `running`, then steers outside the lock,
    /// `session_auto_continue.py:412-428`). Nothing runs any more.
    @Test func aSteerAnsweredAfterTheTurnEndedStopsEverything() {
        var (transcript, second) = replyWithTypeAhead()
        transcript.apply(event("message.complete", completePayload("first reply", rows: [3, 4])))
        transcript.serverReportsIdle()
        #expect(transcript.isRunning, "the submit is not answered yet")
        transcript.promptAnswered(itemID: second, status: "steered")
        #expect(!transcript.isRunning)
        #expect(transcript.waiting == nil)
        #expect(copies(transcript, "also this") == 1, "the bubble stays")
    }

    /// The same without the idle report in between.
    @Test func aSteerAnsweredAfterCompleteStopsEverything() {
        var (transcript, second) = replyWithTypeAhead()
        transcript.apply(event("message.complete", completePayload("first reply", rows: [3, 4])))
        transcript.promptAnswered(itemID: second, status: "steered")
        #expect(!transcript.isRunning)
        #expect(transcript.waiting == nil)
    }

    /// F1, Panda's case (`busy_input_mode: interrupt`, `server.py:378-380`): a send during
    /// a reply is answered `redirected`, a correction inside the running turn
    /// (`interrupt_control.py:277-281`). The turn's end ends everything, with no re-read.
    @Test func aRedirectEndsWithItsTurn() {
        var (transcript, second) = replyWithTypeAhead()
        transcript.promptAnswered(itemID: second, status: "redirected")
        #expect(transcript.isRunning)
        transcript.apply(event("message.delta", ["text": " corrected"]))
        transcript.apply(event("message.complete", completePayload("first reply corrected", rows: [3, 4, 5, 6])))
        #expect(!transcript.isRunning, "no re-read needed")
        #expect(transcript.waiting == nil)
    }

    /// P2 (F1): a redirect, then Stop before any new text: no "Thinking…" under the
    /// stopped turn, also after a re-read that fails (installs nothing).
    @Test func aRedirectThenStopLeavesNothingRunning() {
        var (transcript, second) = replyWithTypeAhead()
        transcript.promptAnswered(itemID: second, status: "redirected")
        transcript.apply(event("message.complete", stoppedWithoutReceipt()))
        transcript.serverReportsIdle()
        #expect(!transcript.isRunning)
        #expect(transcript.waiting == nil)
        transcript.installRereadPage([], ticket: transcript.beginReread(), reachesStart: true)  // a failed read
        #expect(!transcript.isRunning)
        #expect(transcript.waiting == nil)
        #expect(copies(transcript, "also this") == 1)
        #expect(copies(transcript, "first reply") == 1)
    }

    /// A queued prompt still expects its own turn across the closing report.
    @Test func aQueuedPromptStillWaitsForItsTurn() {
        var (transcript, second) = replyWithTypeAhead()
        transcript.promptAnswered(itemID: second, status: "queued")
        transcript.apply(event("message.complete", completePayload("first reply", rows: [3, 4])))
        transcript.serverReportsIdle()
        #expect(transcript.isRunning)
        #expect(transcript.waiting?.since == sent)
        transcript.apply(event("message.start"))
        transcript.apply(event("message.delta", ["text": "second reply"]))
        transcript.apply(event("message.complete", completePayload("second reply", rows: [5, 6])))
        #expect(!transcript.isRunning)
    }

    /// P3 (F2): Stop before any text in turn A, and the next prompt goes out before A's
    /// re-read lands. A's "Interrupted" stays right after A's prompt, not under B.
    @Test(arguments: [true, false])
    func theInterruptedMarkStaysWithItsTurn(withReceipt: Bool) throws {
        var transcript = idle()
        var rows = [storedRow(id: 1), storedRow(id: 2)]
        let first = transcript.appendUserPrompt("first")
        transcript.promptAnswered(itemID: first, status: "streaming", userRowID: 3)
        transcript.apply(event("message.start"))
        transcript.apply(event("message.complete", withReceipt ? complete("", status: "interrupted", rows: [3])
                                                               : stoppedWithoutReceipt()))
        let mark = try #require(transcript.items.last { $0.outcome == "interrupted" })
        let ticket = transcript.beginReread()

        let second = transcript.appendUserPrompt("second")
        transcript.promptAnswered(itemID: second, status: "streaming", userRowID: 5)
        transcript.apply(event("message.start"))
        rows += [storedRow(id: 3, text: "first"), storedRow(id: 5, text: "second")]
        transcript.installRereadPage(rows, ticket: ticket, reachesStart: true)
        func expectOrder(_ when: String) throws {
            let markIndex = try #require(transcript.items.firstIndex { $0.id == mark.id }, "the mark is gone \(when)")
            let firstIndex = try #require(transcript.items.firstIndex { $0.rowID == 3 })
            let secondIndex = try #require(transcript.items.firstIndex { $0.rowID == 5 })
            #expect(markIndex == firstIndex + 1, "\(when): the mark is not right after its prompt")
            #expect(markIndex < secondIndex, "\(when): the mark went under the next prompt")
        }
        try expectOrder("mid-turn")

        transcript.apply(event("message.delta", ["text": "second reply"]))
        transcript.apply(event("message.complete", completePayload("second reply", rows: [5, 6])))
        rows.append(storedRow(id: 6, text: "second reply"))
        transcript.installRereadPage(rows, ticket: transcript.beginReread(), reachesStart: true)
        try expectOrder("after the next turn")
        #expect(transcript.items.filter { $0.outcome == "interrupted" }.count == 1)
        expectWellFormed(transcript)
    }

    /// P4 (F3): with show-reasoning on, Stop before any text keeps the reasoning and
    /// "Interrupted" across the re-reads (Hermes stores no row for an empty partial).
    @Test func stopAfterReasoningKeepsTheReasoningAndTheMark() throws {
        var transcript = idle()
        var rows = [storedRow(id: 1), storedRow(id: 2)]
        let prompt = transcript.appendUserPrompt("hello")
        transcript.promptAnswered(itemID: prompt, status: "streaming", userRowID: 3)
        transcript.apply(event("message.start"))
        transcript.apply(event("reasoning.delta", ["text": "let me think"]))
        transcript.apply(event("message.complete", complete("", status: "interrupted", rows: [3])))
        rows.append(storedRow(id: 3, text: "hello"))
        for _ in 0..<3 where transcript.needsReread {
            transcript.installRereadPage(rows, ticket: transcript.beginReread(), reachesStart: true)
        }
        let mark = try #require(transcript.items.first { $0.outcome == "interrupted" })
        #expect(mark.reasoning == "let me think")
        #expect(transcript.items.filter { $0.outcome == "interrupted" }.count == 1)
        #expect(!transcript.isRunning)
        expectWellFormed(transcript)
    }

    /// P5 (F4): a stale `running: false` after `message.start` while the turn shows only
    /// reasoning: the turn goes on, its reasoning stays, and so does the Stop button.
    @Test func aStaleIdleReportDoesNotCutAReasoningTurn() throws {
        var transcript = idle()
        let prompt = transcript.appendUserPrompt("hello", sentAt: sent)
        transcript.promptAnswered(itemID: prompt, status: "streaming", userRowID: 3)
        transcript.apply(event("message.start"))
        transcript.apply(event("reasoning.delta", ["text": "step one. "]))
        transcript.serverReportsIdle()
        let ticket = transcript.beginReread()
        transcript.apply(event("reasoning.delta", ["text": "step two."]))
        transcript.installRereadPage([storedRow(id: 1), storedRow(id: 2), storedRow(id: 3, text: "hello")],
                                     ticket: ticket, reachesStart: true)
        #expect(transcript.isRunning)
        let reply = try #require(transcript.items.last { $0.role == .assistant && $0.rowID == nil })
        #expect(reply.reasoning == "step one. step two.")
        #expect(transcript.waiting?.since == sent)
    }

    /// F4: any streamed event of a turn opens it, and with it the running state, also
    /// after a report that closed an empty one.
    @Test func streamedEventsAlwaysMeanRunning() {
        for type in ["reasoning.delta", "tool.generating", "tool.start", "message.interim"] {
            var transcript = idle()
            transcript.apply(event("message.start"))
            transcript.serverReportsIdle()  // an empty turn: closed
            #expect(!transcript.isRunning)
            let payload: JSONValue = switch type {
            case "tool.generating": ["name": "terminal"]
            case "tool.start": ["tool_id": "t1", "name": "terminal"]
            case "message.interim": ["text": "checking", "already_streamed": false]
            default: ["text": "thinking"]
            }
            transcript.apply(event(type, payload))
            #expect(transcript.isRunning, "\(type) did not bring the running state back")
        }
    }

    /// Hermes marks the session running before it answers `streaming`
    /// (`methods_prompt.py:668`), so `running: false` after that answer, with no turn
    /// open, means no turn is coming (one that could not start, `prompt_turn.py:1238-1245`).
    /// A submit not answered yet still waits for its answer.
    @Test func anIdleReportEndsAStreamingExpectationButNotAnUnansweredSubmit() {
        var answered = idle()
        let prompt = answered.appendUserPrompt("hello", sentAt: sent)
        answered.promptAnswered(itemID: prompt, status: "streaming", userRowID: 3)
        answered.serverReportsIdle()
        #expect(!answered.isRunning)
        #expect(answered.waiting == nil)

        var unanswered = idle()
        unanswered.appendUserPrompt("hello", sentAt: sent)
        unanswered.serverReportsIdle()
        #expect(unanswered.isRunning)
        #expect(unanswered.waiting?.since == sent)
    }

    /// A chat shown again while the server runs a turn: running until that turn's events
    /// say otherwise, and an idle report ends it.
    @Test func serverBusyLastsUntilTheServerSaysOtherwise() {
        var completed = idle()
        completed.reconcileRunning(true)
        #expect(completed.isRunning)
        completed.apply(event("message.complete", completePayload("done", rows: [3, 4])))
        #expect(!completed.isRunning)

        var reported = idle()
        reported.reconcileRunning(true)
        reported.serverReportsIdle()
        #expect(!reported.isRunning)
    }
}

// Round 4: server facts the round-3 design missed (review R1-R3).

/// A stored assistant row that calls a tool, and the tool's row.
private func toolRound(_ assistant: Int, _ tool: Int, call: String) -> [StoredMessage] {
    var row = StoredMessage(id: assistant, role: "assistant", content: .string(""))
    row.toolCalls = [["id": .string(call), "type": "function",
                      "function": ["name": "terminal", "arguments": #"{"command":"ls"}"#]]]
    var result = StoredMessage(id: tool, role: "tool", content: "output")
    result.toolCallID = call
    result.toolName = "terminal"
    return [row, result]
}

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct StopWithAQueuedPromptTests {
    /// R1: an image sent during a reply is queued (`session_auto_continue.py:419`), then
    /// Stop. `session.interrupt` clears Hermes's queue (`session_lifecycle.py:708-712`), so
    /// that prompt's `message.start` never comes; with every re-read failing, nothing else
    /// would end its wait.
    @Test func stopWithAQueuedPromptLeavesNothingRunning() async throws {
        let server = PagedServer(store: FakeMessageStore(rows: [storedRow(id: 1), storedRow(id: 2)]))
        let (connection, transport) = try await server.connect(log: FrameLog())
        let session = try await connection.open(SessionSummary(id: "stored-1"))
        await settle(session)
        try await session.send("first")  // streaming, row 3 written at submit
        transport.sendEvent("message.start", sessionID: session.sessionID, seq: 1)
        transport.sendEvent("message.delta", sessionID: session.sessionID, seq: 2, payload: ["text": "partial"])
        #expect(await eventually { copies(session.transcript, "partial") == 1 })

        server.busyStatus.withLock { $0 = "queued" }
        try await session.send("with image")
        // Hermes persists a queued prompt's row when it accepts it (`session_auto_continue.py:441`).
        server.store.append([storedRow(id: 4, role: "user", text: "with image")])
        server.store.setMode(.offline)  // every re-read fails from here on
        #expect(session.transcript.isRunning)

        try await session.interrupt()
        transport.sendEvent("message.complete", sessionID: session.sessionID, seq: 3,
                            payload: ["text": "partial", "status": "interrupted"])
        transport.sendEvent("session.info", sessionID: session.sessionID, seq: 4, payload: ["running": false])
        #expect(await eventually { !session.transcript.isRunning })
        #expect(session.transcript.waiting == nil)
        #expect(copies(session.transcript, "with image") == 1, "the queued prompt still shows")
        #expect(copies(session.transcript, "partial") == 1)
        withExtendedLifetime(connection) {}
    }
}

@Suite struct Round4TranscriptTests {
    /// R2: "Interrupted" goes after the turn's last committed row, below its own tool
    /// rows, not right after its prompt (`persisted_turn.row_ids`, `prompt_turn.py:897-903`).
    @Test func theInterruptedMarkFollowsTheTurnsToolRows() throws {
        var transcript = idle()
        let prompt = transcript.appendUserPrompt("look around")
        transcript.promptAnswered(itemID: prompt, status: "streaming", userRowID: 3)
        transcript.apply(event("message.start"))
        transcript.apply(event("tool.start", ["tool_id": "c1", "name": "terminal"]))
        transcript.apply(event("tool.complete", ["tool_id": "c1", "name": "terminal"]))
        transcript.apply(event("reasoning.delta", ["text": "next step"]))
        var payload = completePayload("", rows: [3, 4, 5]).objectValue ?? [:]
        payload["status"] = "interrupted"
        transcript.apply(event("message.complete", .object(payload)))
        let rows = [storedRow(id: 1), storedRow(id: 2), storedRow(id: 3, text: "look around")]
            + toolRound(4, 5, call: "c1")
        for _ in 0..<3 where transcript.needsReread {
            transcript.installRereadPage(rows, ticket: transcript.beginReread(), reachesStart: true)
        }
        let mark = try #require(transcript.items.firstIndex { $0.outcome == "interrupted" })
        let toolRow = try #require(transcript.items.firstIndex { $0.rowID == 5 })
        #expect(mark == toolRow + 1, "the mark is not right after the turn's last row")
        #expect(transcript.items[mark].reasoning == "next step")
        #expect(transcript.items.filter { $0.role == .tool }.count == 1)
        expectWellFormed(transcript)
    }

    /// R3: a follow-up turn refused after its `message.start` (`_dispatch_followup_turn`,
    /// `prompt_turn.py:421-436`, then `:123-134`) sends `error` and nothing else.
    @Test func aFollowUpRefusedAfterItsStartEndsWithItsError() {
        var transcript = idle()
        transcript.apply(event("message.start"))
        #expect(transcript.isRunning)
        transcript.apply(event("error", ["message": "session is owned by another backend"]))
        #expect(!transcript.isRunning)
        #expect(transcript.waiting == nil)
        #expect(transcript.lastError == "session is owned by another backend")
        #expect(!transcript.items.contains { $0.role == .assistant && $0.rowID == nil })
    }

    /// An `error` never closes a turn that has shown something.
    @Test(arguments: ["message.delta", "reasoning.delta", "tool.start"])
    func anErrorLeavesATurnThatShowedSomething(shown: String) {
        var transcript = idle()
        transcript.apply(event("message.start"))
        let payload: JSONValue = shown == "tool.start" ? ["tool_id": "t1", "name": "terminal"] : ["text": "partial"]
        transcript.apply(event(shown, payload))
        transcript.apply(event("error", ["message": "something"]))
        #expect(transcript.isRunning)
    }
}

