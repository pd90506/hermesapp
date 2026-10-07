import Foundation
import HermesProtocol
import Synchronization
import Testing

@testable import HermesKit

// Regression tests for the review of the paged transcript (fix round 2). They use
// only API the first version already had, so they also build against it.

/// An assistant row that calls tools: Hermes stores it before the tools run
/// (`agent/turn_tool_round.py:127-130`), in `_row_to_message_dict` shape
/// (`hermes_state_messages.py:1311-1333`).
private func assistantRow(_ id: Int, _ text: String, calls: [(id: String, name: String, command: String)] = [])
    -> StoredMessage
{
    var row = StoredMessage(id: id, role: "assistant", content: .string(text))
    if !calls.isEmpty {
        row.toolCalls = .array(calls.map { call in
            ["id": .string(call.id), "type": "function",
             "function": ["name": .string(call.name), "arguments": .string(#"{"command":"\#(call.command)"}"#)]]
        })
    }
    return row
}

/// The tool result row (`tool_call_id`, `tool_name`; `hermes_state_common.py:449-480`).
private func toolRow(_ id: Int, call: String, name: String = "terminal") -> StoredMessage {
    var row = StoredMessage(id: id, role: "tool", content: .string("output"))
    row.toolCallID = call
    row.toolName = name
    return row
}

private func userRow(_ id: Int, _ text: String, kind: String? = nil, displayContent: String? = nil) -> StoredMessage {
    var row = StoredMessage(id: id, role: "user", content: .string(text))
    row.displayKind = kind
    row.displayContent = displayContent.map(JSONValue.string)
    return row
}

private func plainRows(_ range: ClosedRange<Int>) -> [StoredMessage] { range.map { storedRow(id: $0) } }

private func event(_ type: String, _ payload: JSONValue? = nil) -> GatewayEvent {
    GatewayEvent(type: type, sessionID: "sid-1", payload: payload)
}

/// `_live_session_payload(omit_messages=True)` + `_resume_reuse_live_locked` with
/// `defer_history` (`server.py:3146-3186`, `methods_session.py:880-895`): a turn running.
private func runningAck(user: String, assistant: String, count: Int) throws -> LiveSessionSnapshot {
    try liveAck(sid: "sid-1", key: "s1", count: count,
                inflight: ["assistant": .string(assistant), "streaming": true, "user": .string(user),
                           "started_at": 1.0, "updated_at": 2.0]).decode(LiveSessionSnapshot.self)
}

/// A deferred ack: nothing running, the history still to be read.
private func idleAck(count: Int) throws -> LiveSessionSnapshot {
    try deferredAck(sid: "sid-1", key: "s1", count: count).decode(LiveSessionSnapshot.self)
}

private func count(_ transcript: Transcript, _ text: String) -> Int {
    transcript.items.filter { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) == text }.count
}

/// How often `segment` appears across all items, also inside a longer live text.
private func occurrences(_ transcript: Transcript, _ segment: String) -> Int {
    transcript.items.reduce(0) { $0 + $1.text.components(separatedBy: segment).count - 1 }
}

private func toolCount(_ transcript: Transcript) -> Int { transcript.items.filter { $0.role == .tool }.count }

@Suite(.timeLimit(.minutes(1))) struct PagingSeamRegressionTests {
    // MARK: Finding 1: a turn read mid-turn

    // MARK: Finding 2: offset drift

    /// A partial receipt (compaction during the turn) names ids that add no display
    /// row. The next page must still reach the row just below the newest page.
    @Test func aPartialReceiptDoesNotSkipOlderRows() async throws {
        let store = FakeMessageStore(count: 300)
        var transcript = Transcript(snapshot: try idleAck(count: 300))
        let first = try await store.messagesPage(SessionMessagesQuery(sessionID: "s1", profile: nil, limit: 120))
        transcript.installLatestPage(first.messages, hasOlder: true)

        // Another client's turn: row 301 is displayed, 9001 is model-only.
        transcript.apply(event("message.delta", ["text": "assistant 301"]))
        store.append([storedRow(id: 301, role: "assistant")])
        transcript.apply(event("message.complete", completePayload("assistant 301", rows: [9001, 301], complete: false)))

        let older = try await store.messagesPage(SessionMessagesQuery(
            sessionID: "s1", profile: nil, limit: 120, offset: transcript.nextOlderOffset))
        transcript.prependOlderPage(older.messages, hasOlder: true)
        let ids = transcript.items.compactMap(\.rowID)
        #expect(ids.contains(180))
        #expect(ids == Array((ids.first ?? 0)...300))
        expectWellFormed(transcript)
    }

    // MARK: Finding 3: the read for a gateway that ignores `order`

    private struct Runaway: Error {}

    /// Ignores `offset` as well: every read answers the same oldest rows.
    private final class StuckSource: SessionMessagesSource, Sendable {
        let rows = (1...600).map { storedRow(id: $0) }
        let calls = Mutex(0)

        func messagesPage(_ query: SessionMessagesQuery) async throws -> SessionMessagesPage {
            let n = calls.withLock { $0 += 1; return $0 }
            if n > 40 { throw Runaway() }
            let page = Array(rows.prefix(query.limit))
            return SessionMessagesPage(messages: page, pagination: SessionMessagesPagination(
                limit: query.limit, offset: query.offset, order: nil, returned: page.count))
        }
    }

    @Test func anOrderlessGatewayThatIgnoresOffsetStops() async {
        let source = StuckSource()
        do {
            let latest = try await ChatSession.fetchLatest(
                SessionMessagesQuery(sessionID: "s", profile: nil, limit: 120), from: source)
            Issue.record("read \(latest.rows.count) rows from a gateway that repeats itself")
        } catch {
            #expect(!(error is Runaway), "the read only ended at the test's own guard")
            #expect(error as? HistoryReadError == .noProgress)
        }
        #expect(source.calls.withLock { $0 } <= 3)
    }

    /// Honours `offset` but holds more rows than the app reads that way.
    private struct LongOrderlessSource: SessionMessagesSource {
        let total: Int

        func messagesPage(_ query: SessionMessagesQuery) async throws -> SessionMessagesPage {
            let ids = (query.offset + 1)...min(total, query.offset + query.limit)
            let page = ids.isEmpty ? [] : ids.map { storedRow(id: $0) }
            return SessionMessagesPage(messages: page, pagination: SessionMessagesPagination(
                limit: query.limit, offset: query.offset, order: nil, returned: page.count))
        }
    }

    @Test func aLongOrderlessHistoryIsNotReadWithoutBound() async {
        do {
            let latest = try await ChatSession.fetchLatest(
                SessionMessagesQuery(sessionID: "s", profile: nil, limit: 120), from: LongOrderlessSource(total: 30_000))
            Issue.record("read all \(latest.rows.count) rows")
        } catch {
            #expect(error as? HistoryReadError == .tooLong(rows: ChatSession.orderlessRowLimit))
        }
    }

    // MARK: Finding 4: projection parity with the old resume

    /// Expected text derived from `_history_to_messages` (`tui_gateway/session_history.py:285-362`):
    /// - Discord notes: `_DISCORD_TRIGGERING_NOTE_RE.sub(r"\1", …)` (:13-15, :307-308);
    /// - skill scaffolds: `describe_skill_invocation(text, separator=" ")` (:239-241, :349-352;
    ///   `agent/skill_commands.py:101-171`): single skill with instruction, bare, auto-load, bundle.
    /// The derivation script is `~/.hermes/cache/scratch/accept-paging2/derive_projection_fixture.py`.
    @Test func storedUserTextMatchesTheGatewayProjection() {
        let note = "[Triggering message id: `1186` \u{2014} use as `message_id` for reply/react/pin via the discord tools.]"
        let skill = #"[IMPORTANT: The user has invoked the "work" skill, indicating they want you to follow its instructions. The full skill content is loaded below.]"#
            + "\n\n# Work\nDo the work.\n\n"
            + "The user has provided the following instruction alongside the skill invocation: fix the  title leak"
            + "\n\n[Runtime note: cwd is /srv]"
        let bare = #"[IMPORTANT: The user has invoked the "work" skill, indicating they want you to follow its instructions. The full skill content is loaded below.]"#
            + "\n\n# Work\nDo the work."
        let auto = #"[IMPORTANT: The "deploy" skill is auto-loaded. Follow its instructions for this session.]"#
            + "\n\n# Deploy\nScripts live in scripts/; then run them with the terminal tool using the absolute path."
            + "\n\nship it\n  now"
        let bundle = #"[IMPORTANT: The user has invoked the "/clean /work" skill bundle, indicating they want you to follow its instructions.]"#
            + "\nUser instruction: tidy up\n\n[Loaded as part of the bundle: clean]\n# Clean"
        let rows = [note + "\nwhat's up?", "hello\n" + note + "\n\nthere", skill, bare, auto, bundle]
            .enumerated().map { userRow($0.offset * 2 + 1, $0.element) }

        var transcript = Transcript()
        transcript.installLatestPage(rows, hasOlder: true)
        #expect(transcript.items.map(\.text) == [
            "what's up?", "hello\nthere", "/work fix the title leak", "/work", "ship it now", "/clean /work tidy up",
        ])
        expectWellFormed(transcript)
    }

    /// Compaction can stamp the session's opening prompt hidden; Desktop keeps it
    /// (`apps/desktop/src/app/chat/transcript-backfill.ts:29-71`, #96875).
    @Test func aCompactedSessionKeepsItsOpeningPrompt() {
        let page = [userRow(1, "hi there", kind: "hidden"), storedRow(id: 2, role: "assistant", text: "hello"),
                    userRow(3, "model scaffolding", kind: "hidden"), storedRow(id: 4, role: "assistant", text: "more")]
        var opening = Transcript()
        opening.installLatestPage(page, hasOlder: false)
        #expect(opening.items.map(\.text) == ["hi there", "hello", "more"])

        // Reached by scrolling up as well.
        var scrolled = Transcript()
        scrolled.installLatestPage(plainRows(5...124), hasOlder: true)
        scrolled.prependOlderPage(page, hasOlder: false)
        #expect(scrolled.items.prefix(3).map(\.text) == ["hi there", "hello", "more"])
    }

    // MARK: Finding 5: matching the echoed prompt

}

/// Connection-level nits.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct PagingNitRegressionTests {
    /// `message_count` is the tip segment's counter; 0 must not skip the read.
    @Test func anEmptyCountStillReadsThePage() async throws {
        let server = PagedServer(store: FakeMessageStore(count: 50))
        server.ackCount.withLock { $0 = 0 }
        let (connection, _) = try await server.connect(log: FrameLog())
        let session = try await connection.openBotChat(profile: "coder")
        await session.historyTask?.value
        #expect(server.store.queries.count == 1)
        #expect(session.transcript.items.compactMap(\.rowID) == Array(1...50))
        expectWellFormed(session.transcript)
    }

    /// A cold restore cancels the read still in flight for the replaced transcript.
    @Test func aRestoreCancelsTheStaleRead() async throws {
        let store = FakeMessageStore(count: 300, honoursCancellation: true)
        let server = PagedServer(store: store)
        let second = FakeTransport()
        second.serve(epoch: "E2", log: FrameLog(), server.handle)
        let (connection, first) = try await server.connect(log: FrameLog(), extra: [second])
        store.hold()
        let session = try await connection.openBotChat(profile: "coder")
        #expect(await eventually { store.heldCount == 1 })

        first.serverDrops()
        #expect(await eventually { store.cancelled == 1 && connection.state == .connected })
        store.release()
        #expect(await eventually { session.historyLoad == .idle && session.transcript.paging.isLoaded })
        #expect(session.transcript.items.compactMap(\.rowID) == Array(181...300))
        expectWellFormed(session.transcript)
    }
}
