import Foundation
import HermesProtocol
import Testing

@testable import HermesKit

@Suite struct TranscriptTests {
    private func event(_ type: String, _ payload: JSONValue? = nil) -> GatewayEvent {
        GatewayEvent(type: type, sessionID: "sid-1", payload: payload)
    }

    @Test func streamsDeltasAndReasoningIntoOneAssistantItem() {
        var transcript = Transcript()
        transcript.appendUserPrompt("hi")
        transcript.apply(event("message.start"))
        transcript.apply(event("reasoning.delta", ["text": "thinking…"]))
        transcript.apply(event("message.delta", ["text": "Hel"]))
        transcript.apply(event("message.delta", ["text": "lo"]))
        #expect(transcript.isRunning)
        #expect(transcript.items.count == 2)
        #expect(transcript.items[1].text == "Hello")
        #expect(transcript.items[1].reasoning == "thinking…")
        #expect(transcript.items[1].isActive)

        transcript.apply(event("message.complete", ["text": "Hello", "status": "complete"]))
        #expect(!transcript.isRunning)
        #expect(transcript.items.count == 2)
        #expect(!transcript.items[1].isActive)
        #expect(transcript.items[1].outcome == "complete")
        expectWellFormed(transcript)
    }

    @Test func toolCallsSplitAssistantSegments() {
        var transcript = Transcript()
        transcript.appendUserPrompt("list files")
        transcript.apply(event("message.start"))
        transcript.apply(event("message.delta", ["text": "Let me look."]))
        transcript.apply(event("tool.start", ["tool_id": "t1", "name": "terminal", "context": "ls"]))
        transcript.apply(event("tool.complete", ["tool_id": "t1", "name": "terminal", "summary": "3 files",
                                                 "duration_s": 0.2]))
        transcript.apply(event("message.delta", ["text": "Done."]))
        transcript.apply(event("message.complete", ["text": "Done.", "status": "complete"]))

        let roles = transcript.items.map(\.role)
        #expect(roles == [.user, .assistant, .tool, .assistant])
        #expect(transcript.items[1].text == "Let me look.")
        #expect(transcript.items[2].toolName == "terminal")
        #expect(transcript.items[2].detail == "3 files")
        #expect(!transcript.items[2].isActive)
        #expect(transcript.items[3].text == "Done.")
        expectWellFormed(transcript)
    }

    @Test func completeWithoutDeltasStillShowsReply() {
        var transcript = Transcript()
        transcript.appendUserPrompt("q")
        transcript.apply(event("message.complete", ["text": "Answer", "status": "complete"]))
        #expect(transcript.items.last?.text == "Answer")
        #expect(transcript.items.last?.role == .assistant)
        expectWellFormed(transcript)
    }

    @Test func errorTurnSetsLastError() {
        var transcript = Transcript()
        transcript.appendUserPrompt("q")
        transcript.apply(event("message.complete", ["text": "", "status": "error", "error": "provider down"]))
        #expect(!transcript.isRunning)
        #expect(transcript.lastError == "provider down")
        expectWellFormed(transcript)
    }

    @Test func interimAlreadyStreamedSealsSegment() {
        var transcript = Transcript()
        transcript.apply(event("message.delta", ["text": "Checking"]))
        transcript.apply(event("message.interim", ["text": "Checking", "already_streamed": true]))
        transcript.apply(event("message.delta", ["text": "Result"]))
        #expect(transcript.items.map(\.text) == ["Checking", "Result"])
        expectWellFormed(transcript)
    }

    @Test func rebuildsFromSnapshotWithInflightTurn() {
        let snapshot = LiveSessionSnapshot(
            sessionID: "sid-1",
            messages: [TranscriptMessage(role: "user", text: "first"),
                       TranscriptMessage(role: "assistant", text: "reply"),
                       TranscriptMessage(role: "user", text: "second")],
            running: true,
            inflight: InflightTurn(assistant: "partial", streaming: true, user: "second"))
        var transcript = Transcript(snapshot: snapshot)
        #expect(transcript.items.map(\.text) == ["first", "reply", "second", "partial"])
        #expect(transcript.isRunning)
        #expect(transcript.items.last?.isActive == true)

        transcript.apply(event("message.delta", ["text": " more"]))
        #expect(transcript.items.last?.text == "partial more")
        expectWellFormed(transcript)
    }

    /// S5: a retained failed turn (`inflight.error`, `streaming:false`) is over.
    @Test func retainedFailedInflightTurnDoesNotSpin() throws {
        let raw: JSONValue = [
            "session_id": "sid-1", "session_key": "stored-1", "message_count": 1,
            "messages": [["role": "user", "text": "do it"]],
            "running": false, "status": "idle",
            "inflight": ["assistant": "partial", "streaming": false, "user": "do it",
                         "error": "provider timed out", "status": "error", "recoverable": true],
        ]
        let snapshot = try raw.decode(LiveSessionSnapshot.self)
        let transcript = Transcript(snapshot: snapshot)
        #expect(!transcript.isRunning)
        #expect(transcript.lastError == "provider timed out")
        #expect(transcript.items.map(\.text) == ["do it", "partial"])
        #expect(transcript.items.last?.isActive == false)
        #expect(transcript.items.last?.outcome == "error")
        expectWellFormed(transcript)
    }

    /// S6: `message.complete.text` is `str | JsonValue`; a non-string must not
    /// demote the terminal frame to `.unknown` and leave the turn running.
    @Test func nonStringCompleteTextStillEndsTheTurn() {
        var transcript = Transcript()
        transcript.appendUserPrompt("q")
        let event = event("message.complete", ["text": ["answer": 42], "status": "complete"])
        guard case .messageComplete(let complete) = event.kind else {
            Issue.record("message.complete with object text decoded as \(event.kind)"); return
        }
        #expect(complete.textValue == #"{"answer":42}"#)
        transcript.apply(event)
        #expect(!transcript.isRunning)
        #expect(transcript.items.last?.text == #"{"answer":42}"#)

        let parts = GatewayEvent(type: "message.complete", payload: ["text": [["type": "text", "text": "a"],
                                                                              ["type": "text", "text": "b"]]])
        guard case .messageComplete(let fromParts) = parts.kind else { Issue.record("parts"); return }
        #expect(fromParts.textValue == "ab")
        expectWellFormed(transcript)
    }

    /// A stored tool row is a finished call (only results are stored,
    /// `session_history.py:322-334`), so a later `tool.start` with the same id is a
    /// new call: providers can number calls per response. It gets its own row, and
    /// the stored one keeps its state. (This test used to expect the stored row to
    /// be reused, which hid the new call.)
    @Test func aStartReusingAStoredCallIDGetsItsOwnRow() {
        var message = TranscriptMessage(role: "tool")
        message.toolCallID = "call-1"
        message.name = "terminal"
        message.context = "ls"
        var transcript = Transcript(snapshot: LiveSessionSnapshot(sessionID: "sid-1", messages: [message], running: true))
        transcript.apply(event("tool.start", ["tool_id": "call-1", "name": "terminal"]))
        transcript.apply(event("tool.complete", ["tool_id": "call-1", "name": "terminal", "summary": "ok"]))
        let tools = transcript.items.filter { $0.role == .tool }
        #expect(tools.map(\.detail) == ["ls", "ok"])
        #expect(tools.allSatisfy { !$0.isActive })
        expectWellFormed(transcript)
    }

    @Test func requestsAreAddedOnceAndCancelled() {
        var transcript = Transcript()
        let approval = ServerRequest(id: "srq-1", method: "approval",
                                     params: ["session_id": "sid-1", "request_id": "ap-1"])
        transcript.addRequest(approval)
        transcript.addRequest(approval)
        transcript.addRequest(ServerRequest(id: "srq-2", method: "sudo", params: ["session_id": "sid-1"]))
        #expect(transcript.pendingRequests.count == 2)

        transcript.apply(event("request.cancel", ["id": "srq-2", "method": "sudo", "reason": "timeout"]))
        #expect(transcript.pendingRequests.map(\.id) == ["srq-1"])

        transcript.apply(GatewayEvent(type: "approval.cancelled", sessionID: "",
                                      payload: ["session_id": "sid-1", "stored_session_id": "s",
                                                "reason": "interrupted", "cancelled_count": 1,
                                                "request_ids": ["ap-1"]]))
        #expect(transcript.pendingRequests.isEmpty)
        expectWellFormed(transcript)
    }
}
