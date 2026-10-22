import Foundation
import HermesProtocol
import Testing

@testable import HermesKit

/// Tool activity, interim commentary, provider waits, steers and side questions
/// (`docs/protocol.md` §5, §10.7).
@Suite struct TranscriptRichContentTests {
    private func event(_ type: String, _ payload: JSONValue? = nil) -> GatewayEvent {
        GatewayEvent(type: type, sessionID: "sid-1", payload: payload)
    }

    /// Payloads per `contracts/events.py:261-303` (`tool_progress.py:276-362`).
    @Test func toolActivityCarriesArgsOutputAndDiff() throws {
        var transcript = Transcript()
        transcript.appendUserPrompt("fix the typo")
        transcript.apply(event("message.delta", ["text": "On it."]))
        transcript.apply(event("tool.generating", ["name": "patch"]))
        #expect(transcript.generatingTool == "patch")
        #expect(transcript.items.last?.isActive == false)  // the text segment was sealed

        transcript.apply(event("tool.start", ["tool_id": "call_1", "name": "patch", "context": "README.md",
                                              "args": ["path": "README.md", "old": "teh", "new": "the"]]))
        #expect(transcript.generatingTool == nil)
        let running = try #require(transcript.items.last?.tool)
        #expect(running.phase == .running && running.context == "README.md")
        #expect(running.args?["path"] == "README.md")

        transcript.apply(event("tool.complete", [
            "tool_id": "call_1", "name": "patch", "duration_s": 0.4, "summary": "1 change",
            "result": ["success": true], "inline_diff": "-teh\n+the",
        ]))
        let done = try #require(transcript.items.last?.tool)
        #expect(done.phase == .complete && done.summary == "1 change" && done.durationSeconds == 0.4)
        #expect(done.output == #"{"success":true}"#)
        #expect(done.inlineDiff == "-teh\n+the")
        #expect(transcript.items.last?.detail == "1 change")

        transcript.apply(event("tool.start", ["tool_id": "call_2", "name": "terminal", "context": "make"]))
        transcript.apply(event("tool.complete", ["tool_id": "call_2", "name": "terminal", "result_text": "ok\n",
                                                 "error": "exit 2"]))
        #expect(transcript.items.last?.tool?.phase == .failed)
        #expect(transcript.items.last?.tool?.output == "ok\n")
        expectWellFormed(transcript)
    }

    /// A tool still running when the turn ends is not left spinning.
    @Test func aToolStillRunningAtTheEndIsComplete() {
        var transcript = Transcript()
        transcript.appendUserPrompt("go")
        transcript.apply(event("tool.start", ["tool_id": "t1", "name": "terminal"]))
        transcript.apply(event("message.complete", ["text": "", "status": "interrupted"]))
        #expect(transcript.items.last?.tool?.phase == .complete)
        expectWellFormed(transcript)
    }

    /// `thinking.delta` is mostly spinner text: only an explained provider wait
    /// is kept, and it never reaches `status` or the reasoning
    /// (`message-stream.ts:195-205`, `store/provider-wait.ts:43-53`).
    @Test func thinkingDeltaKeepsOnlyExplainedProviderWaits() {
        var transcript = Transcript()
        transcript.appendUserPrompt("q")
        transcript.apply(event("thinking.delta", ["text": "(｡•́︿•̀｡) pondering…"]))
        #expect(transcript.providerWait == nil && transcript.status == nil)

        transcript.apply(event("thinking.delta", ["text": "⏳ still waiting on the provider (45s)"]))
        #expect(transcript.providerWait == "⏳ still waiting on the provider (45s)")
        #expect(transcript.status == nil)
        // A non-matching frame clears it (`setSessionProviderWait(…, "")`).
        transcript.apply(event("thinking.delta", ["text": "(ᵔᴥᵔ) thinking"]))
        #expect(transcript.providerWait == nil)

        transcript.apply(event("thinking.delta", ["text": "↻ rate limited, retrying in 5s"]))
        transcript.apply(event("tool.generating", ["name": "terminal"]))
        #expect(transcript.providerWait == nil)  // superseded by model output
        transcript.apply(event("thinking.delta", ["text": "⏳ waiting on provider"]))
        #expect(transcript.generatingTool == nil)  // `DRAFT_SUPERSEDING_EVENT_TYPES`
        transcript.apply(event("reasoning.delta", ["text": "Let me think."]))
        #expect(transcript.providerWait == nil)
        #expect(transcript.items.last?.reasoning == "Let me think.")
        #expect(transcript.items.last?.text == "")
    }

    /// A row added mid-turn (steer, note, `/btw`, queued prompt) seals the reply
    /// so far; later deltas open a new bubble below it, and nothing keeps
    /// streaming after `message.complete` (`use-prompt-actions/index.ts:817-825`).
    @Test func rowsAddedMidTurnNeverLeaveABubbleStreaming() {
        var transcript = Transcript()
        transcript.appendUserPrompt("write the report")
        transcript.apply(event("message.start"))
        transcript.apply(event("message.delta", ["text": "Draft one."]))
        let steer = transcript.appendUserPrompt("make it shorter", displayKind: "steer")
        transcript.apply(event("tool.start", ["tool_id": "call_1", "name": "read_file"]))
        transcript.apply(event("tool.complete", ["tool_id": "call_1", "name": "read_file"]))
        transcript.apply(event("message.delta", ["text": "Shorter."]))
        transcript.beginSideQuestion(taskID: "btw_1", question: "which file?")
        transcript.appendNote("Tokens: 12")
        transcript.apply(event("message.delta", ["text": " Done."]))
        let plan = transcript.appendUserPrompt("/plan next")  // a queued skill kickoff
        transcript.apply(event("message.complete", ["text": "Shorter. Done.", "status": "complete"]))

        #expect(transcript.items.map(\.text) == ["write the report", "Draft one.", "make it shorter", "", "Shorter.",
                                                 "", "Tokens: 12", " Done.", "/plan next"])
        #expect(transcript.items[2].isSteer)
        #expect(transcript.items.filter(\.isActive).isEmpty)
        // The side question still waits for its answer, without spinning.
        #expect(transcript.items[5].sideQuestion?.isPending == true)
        // The prompts sent during the turn are not answered yet: they still wait (the
        // queued kickoff has a turn of its own to come), so the session is not idle.
        #expect(transcript.isRunning)
        transcript.promptAnswered(itemID: steer, status: "steered")
        transcript.promptAnswered(itemID: plan, status: "queued")
        #expect(transcript.isRunning, "the queued kickoff's turn has not started")
        transcript.apply(event("message.start"))
        transcript.apply(event("message.complete", ["text": "", "status": "complete"]))
        #expect(!transcript.isRunning)
        expectWellFormed(transcript)
    }

    /// A redirect reaches Hermes a moment after its row shows: text the old call streamed
    /// meanwhile stays in the reply above the row, as Hermes stores it. The corrected call's
    /// first delta starts with a paragraph break (`stream_delivery.py:305-310`) and opens
    /// the bubble below.
    @Test func aRedirectKeepsTheOldReplysLateTextAboveIt() {
        var transcript = Transcript()
        transcript.appendUserPrompt("explain the encoder")
        transcript.apply(event("message.start"))
        transcript.apply(event("message.delta", ["text": "D reads it and A con"]))
        transcript.appendUserPrompt("mostly the T+1 latent")
        transcript.apply(event("message.delta", ["text": "verts it: the same one"]))
        transcript.apply(event("message.delta", ["text": "."]))
        transcript.apply(event("message.delta", ["text": "\n\nRight, T+1 is freer."]))
        transcript.apply(event("message.delta", ["text": " Because"]))
        transcript.apply(event("message.complete", ["text": "Right, T+1 is freer. Because", "status": "complete"]))

        #expect(transcript.items.map(\.text) == ["explain the encoder", "D reads it and A converts it: the same one.",
                                                 "mostly the T+1 latent", "\n\nRight, T+1 is freer. Because"])
        #expect(transcript.items.filter(\.isActive).isEmpty)
        expectWellFormed(transcript)
    }

    /// Any other event of the turn ends the old call's text: a reasoning delta of the
    /// corrected call opens the bubble below, and so does its text after it.
    @Test func aRedirectsLateTextEndsWithTheNextEvent() {
        var transcript = Transcript()
        transcript.appendUserPrompt("q")
        transcript.apply(event("message.start"))
        transcript.apply(event("message.delta", ["text": "Part"]))
        transcript.appendUserPrompt("shorter")
        transcript.apply(event("reasoning.delta", ["text": "The user wants it shorter."]))
        transcript.apply(event("message.delta", ["text": "Short."]))

        let texts = transcript.items.map(\.text)
        #expect(texts == ["q", "Part", "shorter", "Short."])
        #expect(transcript.items.last?.reasoning == "The user wants it shorter.")
    }

    /// A steer waits for a tool result, so the old reply's paragraphs stay above it
    /// until its round ends.
    @Test func aSteerKeepsTheRoundsTextAboveIt() {
        var transcript = Transcript()
        transcript.appendUserPrompt("q")
        transcript.apply(event("message.start"))
        transcript.apply(event("message.delta", ["text": "First."]))
        let steer = transcript.appendUserPrompt("also check B", displayKind: "steer")
        transcript.promptAnswered(itemID: steer, status: "steered")
        transcript.apply(event("message.delta", ["text": "\n\nSecond."]))
        transcript.apply(event("tool.start", ["tool_id": "call_1", "name": "read_file"]))
        transcript.apply(event("tool.complete", ["tool_id": "call_1", "name": "read_file"]))
        transcript.apply(event("message.delta", ["text": "\n\nChecked B."]))

        #expect(transcript.items.map(\.text) == ["q", "First.\n\nSecond.", "also check B", "", "\n\nChecked B."])
    }

    /// A prompt sent while a reply streams goes out as `prompt.submit`; Hermes's busy mode
    /// decides. Answered `steered`, the old reply's paragraphs stay above it as for a steer.
    @Test func aPromptHermesSteeredKeepsTheRoundsTextAboveIt() {
        var transcript = Transcript()
        transcript.appendUserPrompt("q")
        transcript.apply(event("message.start"))
        transcript.apply(event("message.delta", ["text": "First."]))
        let prompt = transcript.appendUserPrompt("also check B")
        transcript.apply(event("message.delta", ["text": " Still first."]))
        transcript.promptAnswered(itemID: prompt, status: "steered")
        transcript.apply(event("message.delta", ["text": "\n\nSecond."]))
        transcript.apply(event("message.complete", ["text": "First. Still first.\n\nSecond.", "status": "complete"]))

        #expect(transcript.items.map(\.text) == ["q", "First. Still first.\n\nSecond.", "also check B"])
    }

    /// Desktop seals the streaming bubble with the authoritative interim text
    /// (`use-message-stream/index.ts:646-659`), even when only part of it streamed.
    @Test func interimReplacesAPartlyStreamedBubble() {
        var transcript = Transcript()
        transcript.appendUserPrompt("q")
        transcript.apply(event("message.delta", ["text": "Let me ch"]))
        transcript.apply(event("message.interim", ["text": "Let me check the logs.", "already_streamed": false]))
        transcript.apply(event("message.interim", ["text": "Let me check the logs.", "already_streamed": false]))

        let assistants = transcript.items.filter { $0.role == .assistant }
        #expect(assistants.map(\.text) == ["Let me check the logs."])
        #expect(assistants.first?.isInterim == true && assistants.first?.isActive == false)
    }

    /// `message.interim` (`prompt_turn.py:768-773`) marks commentary beside tool calls.
    @Test func interimCommentaryIsMarkedAndSealed() {
        var transcript = Transcript()
        transcript.appendUserPrompt("q")
        // Not streamed: the interim text arrives on its own.
        transcript.apply(event("message.interim", ["text": "I'll check the logs first.", "already_streamed": false]))
        transcript.apply(event("tool.start", ["tool_id": "t1", "name": "terminal"]))
        transcript.apply(event("tool.complete", ["tool_id": "t1", "name": "terminal"]))
        // Streamed, then confirmed as interim.
        transcript.apply(event("message.delta", ["text": "Now the config."]))
        transcript.apply(event("message.interim", ["text": "Now the config.", "already_streamed": true]))
        transcript.apply(event("message.delta", ["text": "All good."]))
        transcript.apply(event("message.complete", ["text": "All good.", "status": "complete"]))

        let assistants = transcript.items.filter { $0.role == .assistant }
        #expect(assistants.map(\.text) == ["I'll check the logs first.", "Now the config.", "All good."])
        #expect(assistants.map(\.isInterim) == [true, true, false])
        #expect(assistants.allSatisfy { !$0.isActive })
        expectWellFormed(transcript)
    }

    @Test func reasoningAvailableReplacesStreamedReasoningBeforeTheReply() {
        var transcript = Transcript()
        transcript.apply(event("reasoning.delta", ["text": "partial"]))
        transcript.apply(event("reasoning.available", ["text": "the whole block"]))
        #expect(transcript.items.last?.reasoning == "the whole block")
        transcript.apply(event("message.delta", ["text": "Answer"]))
        transcript.apply(event("reasoning.available", ["text": "late block"]))
        #expect(transcript.items.last?.reasoning == "the whole block")
    }

    /// Desktop leaves a message with reply text alone, even when its reasoning is
    /// still empty (`use-message-stream/index.ts:531-533`).
    @Test func reasoningAvailableAfterTheReplyStartedIsIgnored() {
        var transcript = Transcript()
        transcript.apply(event("message.delta", ["text": "Answer"]))
        transcript.apply(event("reasoning.available", ["text": "late block"]))
        #expect(transcript.items.last?.text == "Answer")
        #expect(transcript.items.last?.reasoning == "")
    }

    /// `btw.complete` can beat the `prompt.btw` reply: one row, not two with one id.
    @Test func aBtwAnswerBeforeItsQuestionMakesOneRow() {
        var transcript = Transcript()
        transcript.apply(event("btw.complete", ["task_id": "btw_7", "text": "error: no snapshot"]))
        transcript.beginSideQuestion(taskID: "btw_7", question: "why?")
        #expect(transcript.items.count == 1)
        #expect(transcript.items[0].sideQuestion == SideQuestion(taskID: "btw_7", question: "why?",
                                                                answer: "error: no snapshot"))
    }

    /// `background.complete` (`events.py:451`, `methods_prompt.py:1039-1060`).
    @Test func backgroundTaskAnswerFillsItsRow() {
        var transcript = Transcript()
        transcript.beginSideQuestion(taskID: "bg_1", question: "summarise the logs", kind: .background)
        transcript.apply(event("background.complete", ["task_id": "bg_1", "text": "3 errors"]))
        #expect(transcript.items.last?.sideQuestion?.answer == "3 errors")
        #expect(transcript.items.last?.sideQuestion?.kind == .background)
        #expect(transcript.items.last?.isActive == false)
    }

    @Test func btwAnswerFromAnotherClientIsShown() throws {
        var transcript = Transcript()
        transcript.apply(event("btw.complete", ["task_id": "btw_9", "text": "error: no snapshot", "question": "why?"]))
        let side = try #require(transcript.items.last?.sideQuestion)
        #expect(side.question == "why?" && side.isError && !side.isPending)
    }

    /// `_history_to_messages` tool rows: `{role:"tool", name, context, args?, tool_call_id, content?}`;
    /// steer rows have `display_kind:"steer"` (`session_history.py:309-334,318-321`).
    @Test func snapshotHistoryKeepsToolCallsAndSteers() throws {
        let raw: JSONValue = [
            "session_id": "sid-1", "session_key": "stored-1", "message_count": 4, "running": false,
            "messages": [
                ["role": "user", "text": "write it"],
                ["role": "tool", "name": "write_file", "context": "notes.md", "tool_call_id": "call_9",
                 "args": ["path": "notes.md"], "content": "{\"bytes\": 12}"],
                ["role": "user", "text": "make it shorter", "display_kind": "steer"],
                ["role": "assistant", "text": "Done.", "reasoning": "Short is better."],
            ],
        ]
        let transcript = Transcript(snapshot: try raw.decode(LiveSessionSnapshot.self))
        let tool = try #require(transcript.items[1].tool)
        #expect(tool.toolID == "call_9" && tool.name == "write_file" && tool.phase == .complete)
        #expect(tool.output == "{\"bytes\": 12}" && tool.args?["path"] == "notes.md")
        #expect(transcript.items[2].isSteer)
        #expect(transcript.items[3].reasoning == "Short is better.")
    }
}
