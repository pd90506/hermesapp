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
