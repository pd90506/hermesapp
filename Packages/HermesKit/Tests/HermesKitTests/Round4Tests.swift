import Foundation
import HermesProtocol
import Testing

@testable import HermesKit

private func event(_ type: String, _ payload: JSONValue? = nil) -> GatewayEvent {
    GatewayEvent(type: type, sessionID: "sid-1", payload: payload)
}

/// R1 as a transcript fact: `serverClearedQueue` ends queued expectations only.
@Suite struct ServerClearedQueueTests {
    @Test func aClearedQueueEndsQueuedExpectationsOnly() {
        var transcript = Transcript()
        transcript.installLatestPage([storedRow(id: 1), storedRow(id: 2)], hasOlder: false)
        let first = transcript.appendUserPrompt("first")
        transcript.promptAnswered(itemID: first, status: "streaming", userRowID: 3)
        transcript.apply(event("message.start"))
        let queued = transcript.appendUserPrompt("queued")
        transcript.promptAnswered(itemID: queued, status: "queued")
        let unanswered = transcript.appendUserPrompt("unanswered")
        transcript.apply(event("message.complete", ["text": "", "status": "interrupted"]))
        transcript.serverClearedQueue()
        #expect(transcript.isRunning, "the unanswered submit still waits for its answer")
        transcript.submitFailed("boom", itemID: unanswered)
        #expect(!transcript.isRunning)
        #expect(transcript.items.contains { $0.text == "queued" }, "its bubble stays")
    }
}

/// The re-read audit: a failed re-read is tried again, so it is never the only way out.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct RereadRetryTests {
    @Test func aFailedRereadIsTriedAgain() async throws {
        let server = PagedServer(store: FakeMessageStore(rows: [storedRow(id: 1), storedRow(id: 2)]))
        let (connection, transport) = try await server.connect(log: FrameLog())
        let session = try await connection.open(SessionSummary(id: "stored-1"))
        await settle(session)
        session.rereadRetryDelays = [.milliseconds(20), .milliseconds(20), .milliseconds(20)]
        try await session.send("hello")  // row 3
        await settle(session)  // the answer's own read, served before the outage
        // Every read waits in the store until the test serves it: no step races the retry timer.
        server.store.setMode(.offline)
        server.store.hold()
        transport.sendEvent("message.start", sessionID: session.sessionID, seq: 1)
        transport.sendEvent("message.delta", sessionID: session.sessionID, seq: 2, payload: ["text": "hi"])
        server.store.append([storedRow(id: 4, text: "hi")])
        transport.sendEvent("message.complete", sessionID: session.sessionID, seq: 3,
                            payload: completePayload("hi", rows: [3, 4]))
        #expect(await eventually(seconds: 20) { server.store.heldCount == 1 })
        server.store.releaseOldest()  // the turn-end read fails
        // Its retry fires and waits, unserved.
        #expect(await eventually(seconds: 20) { server.store.heldCount == 1 && session.rereadRetry == nil })
        #expect(session.transcript.historyCount < session.transcript.items.count, "the failed read settled nothing")
        server.store.setMode(.paged)
        server.store.release()
        #expect(await eventually(seconds: 20) { session.transcript.historyCount == session.transcript.items.count },
                "the retry settled the turn")
        #expect(session.transcript.items.filter { $0.text == "hello" }.count == 1)
        withExtendedLifetime(connection) {}
    }
}
