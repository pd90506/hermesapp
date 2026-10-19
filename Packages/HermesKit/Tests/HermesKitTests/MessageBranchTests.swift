import Foundation
import HermesProtocol
import Testing

@testable import HermesKit

// Branch from a message: `session.branch` with the count of the parent's visible turns up
// to that message, as Desktop's "Branch in new chat" (`MessageBranch`).

private func row(_ id: Int, _ role: String, _ text: String?) -> StoredMessage {
    StoredMessage(id: id, role: role, content: text.map(JSONValue.string))
}

/// A turn with a tool call between its two replies, as Hermes stores it: the tool rows
/// and the call-only assistant row are not copied (`_visible_branch_history`,
/// `tui_gateway/methods_session_branch.py:21-25`).
private let rows: [StoredMessage] = [
    row(1, "user", "first"),
    row(2, "assistant", "Looking."),
    row(3, "assistant", nil),       // the call, no text
    row(4, "tool", "{\"ok\":true}"),
    row(5, "assistant", "Found it."),
    row(6, "user", "second"),
    row(7, "assistant", "Done."),
]

@MainActor
@Suite struct MessageBranchCountTests {
    private func shown(_ rows: [StoredMessage]) -> [TranscriptItem] {
        var calls: StoredMessageProjection.ToolCalls = [:]
        return StoredMessageProjection.items(from: rows, toolCalls: &calls, startsSession: true)
    }

    @Test func countsTheCopiedRowsThroughTheMessagesRow() throws {
        let items = shown(rows)
        func count(_ rowID: Int) throws -> Int? {
            MessageBranch.count(through: try #require(items.first { $0.rowID == rowID }), shown: items, stored: rows)
        }
        #expect(try count(2) == 2)
        #expect(try count(5) == 3, "the tool rows and the empty call row are not copied")
        #expect(try count(7) == 5)
        #expect(try count(6) == 4)
    }

    /// A reply shown live, before the re-read gave it its row: found by its text, counted
    /// from the end, so the same text earlier in the chat is not taken for it.
    @Test func aLiveReplyIsFoundByItsTextFromTheEnd() throws {
        let stored = rows + [row(8, "user", "again"), row(9, "assistant", "Done.")]
        var items = shown(Array(stored.dropLast()))
        items.append(TranscriptItem(id: "live-1", role: .assistant, text: "Done."))
        #expect(MessageBranch.count(through: items.last!, shown: items, stored: stored) == 7)
    }

    @Test func aMessageNotStoredYetHasNoCount() {
        let items = shown(rows) + [TranscriptItem(id: "live-1", role: .assistant, text: "Not stored")]
        #expect(MessageBranch.count(through: items.last!, shown: items, stored: rows) == nil)
        var gone = TranscriptItem(id: "row-99", role: .assistant, text: "Gone")
        gone.rowID = 99
        #expect(MessageBranch.count(through: gone, shown: items, stored: rows) == nil)
    }
}

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct MessageBranchTests {
    /// The branch is made on the chat's live runtime with the count, and opened.
    @Test func branchingAtAReplyOpensTheBranch() async throws {
        let store = FakeMessageStore(rows: rows)
        let server = PagedServer(store: store)
        let log = FrameLog()
        let (connection, _) = try await server.connect(log: log)
        let session = try await connection.open(SessionSummary(id: "stored-1"))
        await settle(session)
        let reply = try #require(session.transcript.items.first { $0.rowID == 5 })

        let branch = try await connection.branch(session, at: reply)

        let params = try #require(log.requests("session.branch").first?["params"])
        #expect(params["session_id"]?.stringValue == session.sessionID)
        #expect(params["count"]?.intValue == 3)
        #expect(params["idempotency_key"]?.stringValue?.isEmpty == false)
        // The whole transcript was read, oldest first, to count.
        #expect(store.queries.contains { $0.order == .oldest && $0.offset == 0 })
        #expect(branch.storedSessionID == "branch-1")
        #expect(connection.activeSession === branch)
    }

    @Test func aRunningChatIsNotBranched() async throws {
        let server = PagedServer(store: FakeMessageStore(rows: rows))
        let log = FrameLog()
        let (connection, transport) = try await server.connect(log: log)
        let session = try await connection.open(SessionSummary(id: "stored-1"))
        await settle(session)
        let reply = try #require(session.transcript.items.first { $0.rowID == 7 })
        try await session.send("third")
        transport.sendEvent("message.start", sessionID: session.sessionID, seq: 1)
        #expect(await eventually { session.transcript.isRunning })

        await #expect(throws: MessageBranchError.busy) { try await connection.branch(session, at: reply) }
        #expect(log.requests("session.branch").isEmpty)
    }
}
