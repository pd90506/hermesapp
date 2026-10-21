import HermesProtocol
import Testing
@testable import HermesKit

struct PendingOutgoingTests {
    @Test func pendingSurvivesSameChatRebuildAndSettlesByStoredRowID() {
        var old = Transcript()
        old.installLatestPage([], hasOlder: false)
        let id = old.appendUserPrompt("hello")
        var resumed = Transcript()
        resumed.installLatestPage([], hasOlder: false)
        resumed.adoptPendingPrompts(of: old, ids: [id])
        #expect(resumed.items.map(\.id) == [id])
        #expect(resumed.items.first?.outgoingStatus == "Sending…")
        // Only explicitly owned ids are taken over; another chat receives none.
        var other = Transcript()
        other.installLatestPage([], hasOlder: false)
        other.adoptPendingPrompts(of: old, ids: [])
        #expect(other.items.isEmpty)
        resumed.promptAnswered(itemID: id, status: "streaming", userRowID: 7)
        #expect(resumed.items.first?.outgoingStatus == nil)
        var row = StoredMessage(id: 7, role: "user", content: .string("hello"))
        row.timestamp = 200
        let ticket = resumed.beginReread()
        resumed.installRereadPage([row], ticket: ticket, reachesStart: true)
        #expect(resumed.items.filter { $0.role == .user }.count == 1)
        #expect(resumed.items.first?.rowID == 7)
    }

    @Test func rebuiltPendingIsReconciledByLateInitialPage() {
        var old = Transcript()
        let id = old.appendUserPrompt("same words")
        var rebuilt = Transcript()
        rebuilt.adoptPendingPrompts(of: old, ids: [id])
        rebuilt.promptAnswered(itemID: id, status: "streaming", userRowID: 9)
        // Identity is the proof: a different row with identical text is retained.
        let other = StoredMessage(id: 8, role: "user", content: .string("same words"))
        let confirmed = StoredMessage(id: 9, role: "user", content: .string("same words"))
        rebuilt.installLatestPage([other, confirmed], hasOlder: false)
        #expect(rebuilt.items.filter { $0.role == .user }.count == 2)
        #expect(rebuilt.items.compactMap(\.rowID) == [8, 9])
        #expect(!rebuilt.holdsPrompt(id))
    }

    @Test func queuedAndFailedRowsKeepHonestStateAndContent() {
        var transcript = Transcript()
        let queued = transcript.appendUserPrompt("first")
        transcript.promptAnswered(itemID: queued, status: "queued")
        #expect(transcript.items.first?.outgoingStatus == "Queued")
        let failed = transcript.appendUserPrompt("second")
        transcript.submitFailed("connection lost; acceptance unknown", itemID: failed)
        #expect(transcript.items.last?.text == "second")
        #expect(transcript.items.last?.outgoingStatus?.contains("Not confirmed") == true)
        #expect(transcript.items.first?.id == queued)
    }

    /// A lost socket's reason reads as words on the bubble, not as the error's enum dump
    /// (seen on the iOS simulator: "Not confirmed · connectionClosed(Optional(…))").
    @Test func connectionFailuresReadAsWords() {
        var transcript = Transcript()
        let id = transcript.appendUserPrompt("hello")
        let reason = GatewayConnection.describe(GatewayClientError.connectionClosed("closed(code: nil, reason: nil)"))
        transcript.submitFailed(reason, itemID: id, dispatched: true)
        #expect(transcript.items.last?.outgoingStatus == "Not confirmed · The connection to the gateway was lost.")
        #expect(GatewayConnection.describe(GatewayClientError.timeout(method: "prompt.submit"))
            == "The gateway did not answer in time.")
        #expect(GatewayConnection.describe(GatewayClientError.notConnected) == "Not connected to the gateway.")
    }
}
