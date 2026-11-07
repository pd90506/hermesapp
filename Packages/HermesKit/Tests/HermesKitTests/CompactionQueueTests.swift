import Foundation
import HermesProtocol
import Testing

@testable import HermesKit

private func event(_ type: String, _ payload: JSONValue? = nil) -> GatewayEvent {
    GatewayEvent(type: type, sessionID: "sid-1", payload: payload)
}

/// Compaction shows in the composer, whoever started it; queued prompts wait above it.
@Suite struct CompactionQueueTests {
    /// Automatic compaction in a turn (`agent/conversation_compression.py:72-99`): the
    /// composer's row, not the chat's status line.
    @Test func automaticCompactionShowsInTheComposerNotTheChat() {
        var transcript = Transcript()
        transcript.apply(event("message.start"))
        transcript.apply(event("status.update", ["kind": "compacting",
                                                 "text": "🗜️ Compacting context — summarizing earlier conversation so I can continue..."]))
        #expect(transcript.isCompacting)
        #expect(transcript.status == nil)
        #expect(transcript.waiting?.hint == nil)
        transcript.apply(event("status.update", ["kind": "compacted",
                                                 "text": "✓ Context compaction complete — continuing turn..."]))
        #expect(!transcript.isCompacting)
        #expect(transcript.status == nil)
    }

    @Test func aTurnsEndEndsItsCompaction() {
        var transcript = Transcript()
        transcript.apply(event("message.start"))
        transcript.apply(event("status.update", ["kind": "compacting", "text": "Compacting context"]))
        transcript.apply(event("message.complete", ["status": "complete", "text": "done"]))
        #expect(!transcript.isCompacting)
    }

    /// `/compress` from any client: `compressing`, then `ready` sent without text, which
    /// arrives as `{kind: "status", text: "ready"}` (`methods_session.py:2092,2115`).
    @Test func aCompressFromAnyClientShowsUntilReady() {
        var transcript = Transcript()
        transcript.apply(event("status.update", ["kind": "compressing", "text": "compressing 96 messages…"]))
        #expect(transcript.isCompacting)
        transcript.apply(event("status.update", ["kind": "status", "text": "ready"]))
        #expect(!transcript.isCompacting)
    }

    @MainActor @Test func theComposerShowsEveryCompaction() {
        let session = ChatSession(snapshot: LiveSessionSnapshot(sessionID: "sid-1", messages: [], running: false),
                                  title: nil, connection: nil)
        let composer = ChatComposer(session: session)
        #expect(!composer.showsCompressing)
        session.apply(event("message.start"))
        session.apply(event("status.update", ["kind": "compacting", "text": "Compacting context"]))
        #expect(composer.showsCompressing)
        session.apply(event("status.update", ["kind": "compacted", "text": "done"]))
        #expect(!composer.showsCompressing)
    }

    /// Queued behind the running turn: out of the chat until its turn starts, then at the end.
    @Test func aQueuedPromptWaitsAboveTheComposerUntilItsTurn() {
        var transcript = Transcript()
        let first = transcript.appendUserPrompt("first")
        transcript.promptAnswered(itemID: first, status: "streaming", userRowID: 1)
        transcript.apply(event("message.start"))
        transcript.apply(event("message.delta", ["text": "Working"]))
        let second = transcript.appendUserPrompt("second")
        transcript.promptAnswered(itemID: second, status: "queued")
        #expect(transcript.queuedPrompts.map(\.id) == [second])
        #expect(!transcript.blocks.flatMap(\.items).contains { $0.id == second })
        #expect(!transcript.promptMarks.contains { $0.id == second })

        transcript.apply(event("message.delta", ["text": " on it"]))
        transcript.apply(event("message.complete", ["status": "complete", "text": "Working on it"]))
        #expect(transcript.queuedPrompts.map(\.id) == [second], "still waiting between the turns")

        transcript.apply(event("message.start"))
        #expect(transcript.queuedPrompts.isEmpty)
        let users = transcript.items.filter { $0.role == .user }.map(\.id)
        #expect(users.last == second)
        #expect(transcript.items.firstIndex { $0.id == second }! > transcript.items.firstIndex { $0.text == "Working on it" }!)
        #expect(transcript.blocks.flatMap(\.items).contains { $0.id == second })
    }

    /// Queued behind a `/compress` (`session_compression.py:242-259`): no turn ran before it.
    @Test func aPromptQueuedBehindACompressStartsAfterIt() {
        var transcript = Transcript()
        transcript.reconcileRunning(true)
        transcript.apply(event("status.update", ["kind": "compressing", "text": "compressing…"]))
        let prompt = transcript.appendUserPrompt("after the compress")
        transcript.promptAnswered(itemID: prompt, status: "queued")
        #expect(transcript.queuedPrompts.map(\.id) == [prompt])
        transcript.apply(event("status.update", ["kind": "status", "text": "ready"]))
        transcript.serverReportsIdle()
        #expect(transcript.queuedPrompts.map(\.id) == [prompt])
        transcript.apply(event("message.start"))
        #expect(transcript.queuedPrompts.isEmpty)
    }

    /// A Stop clears Hermes's queue; the rows it stored stay, so the prompts show as sent.
    @Test func aStopReturnsQueuedPromptsToTheChat() {
        var transcript = Transcript()
        transcript.apply(event("message.start"))
        let prompt = transcript.appendUserPrompt("later")
        transcript.promptAnswered(itemID: prompt, status: "queued")
        transcript.serverClearedQueue()
        #expect(transcript.queuedPrompts.isEmpty)
        #expect(transcript.blocks.flatMap(\.items).contains { $0.id == prompt })
    }

    /// Answered `queued` after its own turn began: it is not waiting.
    @Test func aQueuedAnswerAfterItsTurnStartedIsNotWaiting() {
        var transcript = Transcript()
        let prompt = transcript.appendUserPrompt("now")
        transcript.apply(event("message.start"))
        transcript.promptAnswered(itemID: prompt, status: "queued")
        #expect(transcript.queuedPrompts.isEmpty)
    }

    @Test func aCompressionsResultIsMarked() {
        var transcript = Transcript()
        transcript.appendNote("Compressed: 196 → 40 messages", displayKind: TranscriptItem.compressionDisplayKind)
        transcript.appendNote("Saved transcript.")
        #expect(transcript.items.map(\.isCompressionNote) == [true, false])
    }
}
