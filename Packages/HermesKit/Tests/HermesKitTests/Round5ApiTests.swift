import Foundation
import HermesProtocol
import Testing

@testable import HermesKit

// Issue #5, round 5: tests of API new in this round (S3's snapshot, N-a's retry handle).

private func event(_ type: String, _ payload: JSONValue? = nil) -> GatewayEvent {
    GatewayEvent(type: type, sessionID: "sid-1", payload: payload)
}

/// An idle chat whose history is rows 1...2 (prompt, reply), every row read.
private func idle() -> Transcript {
    var transcript = Transcript()
    transcript.installLatestPage([storedRow(id: 1), storedRow(id: 2)], hasOlder: false)
    return transcript
}

/// S3: Stop while an image prompt's submit is still unanswered. Hermes queues it, then the
/// Stop clears the queue (both handled inline in arrival order, `rpc_dispatch.py:62`), but
/// the `queued` answer can reach the chat after the Stop's.
@Suite struct StopBeforeTheQueuedAnswerTests {
    /// The review's repro, with the prompt unanswered when the Stop was sent.
    @Test func aQueuedAnswerAfterTheStopExpectsNoStart() {
        var transcript = idle()
        let first = transcript.appendUserPrompt("first")
        transcript.promptAnswered(itemID: first, status: "streaming", userRowID: 3)
        transcript.apply(event("message.start"))
        transcript.apply(event("message.delta", ["text": "partial"]))
        let image = transcript.appendUserPrompt("with image")
        let sentBeforeStop = transcript.unansweredPrompts
        #expect(sentBeforeStop == [image])
        transcript.serverClearedQueue(sentBeforeStop: sentBeforeStop)
        transcript.promptAnswered(itemID: image, status: "queued")
        transcript.apply(event("message.complete", ["text": "partial", "status": "interrupted"]))
        transcript.serverReportsIdle()
        #expect(!transcript.isRunning)
        #expect(transcript.items.contains { $0.text == "with image" }, "its bubble stays")
    }

    /// A prompt sent after the Stop is queued for a turn that does start.
    @Test func aPromptSentAfterTheStopStillWaits() {
        var transcript = idle()
        let first = transcript.appendUserPrompt("first")
        transcript.promptAnswered(itemID: first, status: "streaming", userRowID: 3)
        transcript.apply(event("message.start"))
        let sentBeforeStop = transcript.unansweredPrompts
        let later = transcript.appendUserPrompt("after the stop")
        transcript.serverClearedQueue(sentBeforeStop: sentBeforeStop)
        transcript.promptAnswered(itemID: later, status: "queued")
        transcript.apply(event("message.complete", ["text": "", "status": "interrupted"]))
        transcript.serverReportsIdle()
        #expect(transcript.isRunning, "its message.start is still to come")
    }
}

/// N-a: the pending re-read retry.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct RereadRetryCancelTests {
    /// One turn whose re-read the gateway answers or fails: `text` sent, replied to.
    private func turn(_ session: ChatSession, _ server: PagedServer, _ transport: FakeTransport,
                      _ text: String, seq: inout Int) async throws {
        try await session.send(text)
        let prompt = try #require(server.store.rows.last?.id)
        transport.sendEvent("message.start", sessionID: session.sessionID, seq: seq)
        transport.sendEvent("message.delta", sessionID: session.sessionID, seq: seq + 1, payload: ["text": .string("re: " + text)])
        server.store.append([storedRow(id: prompt + 1, text: "re: " + text)])
        transport.sendEvent("message.complete", sessionID: session.sessionID, seq: seq + 2,
                            payload: completePayload("re: " + text, rows: [prompt, prompt + 1]))
        seq += 3
    }

    /// N-a: a rebuild and a forgotten chat cancel the pending retry.
    @Test(arguments: [false, true])
    func aRebuildOrForgetCancelsThePendingRetry(forget: Bool) async throws {
        let server = PagedServer(store: FakeMessageStore(rows: [storedRow(id: 1), storedRow(id: 2)]))
        let (connection, transport) = try await server.connect(log: FrameLog())
        let session = try await connection.open(SessionSummary(id: "stored-1"))
        await settle(session)
        session.rereadRetryDelays = [.seconds(30)]
        server.store.setMode(.offline)
        var seq = 1
        try await turn(session, server, transport, "one", seq: &seq)
        #expect(await eventually { session.rereadRetry != nil })
        if forget {
            connection.forget(session)
        } else {
            session.reset(to: LiveSessionSnapshot(sessionID: session.sessionID, messages: [], running: false),
                          storedSessionID: "stored-1")
        }
        #expect(session.rereadRetry == nil)
        withExtendedLifetime(connection) {}
    }
}
