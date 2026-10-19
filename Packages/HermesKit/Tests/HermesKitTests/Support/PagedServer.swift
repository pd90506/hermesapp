import Foundation
@testable import HermesKit
import HermesProtocol
import Synchronization

/// Cold `defer_history` + `omit_messages` resume ack: `_resume_response` from
/// `_resume_deferred` (`methods_session.py:898-914,949-967`). No messages; the
/// stored size as `message_count`; `hydrating`, status `resuming`.
func deferredAck(sid: String, key: String, count: Int) -> JSONValue {
    ["session_id": .string(sid), "resumed": .string(key), "message_count": .number(Double(count)), "messages": [],
     "hydrating": true, "info": ["model": "test-model", "lazy": true], "inflight": nil, "running": false,
     "session_key": .string(key), "started_at": 1_700_000_000, "status": "resuming"]
}

/// Ack when the session was already live (another client, or a running turn):
/// `_live_session_payload(omit_messages=True)` overlaid by `_resume_reuse_live_locked`
/// with `defer_history` (`server.py:3146-3186`, `methods_session.py:880-895`).
func liveAck(sid: String, key: String, count: Int, inflight: JSONValue) -> JSONValue {
    ["session_id": .string(sid), "resumed": .string(key), "session_key": .string(key),
     "message_count": .number(Double(count)), "messages": [], "messages_omitted": true, "hydrating": false,
     "info": ["model": "test-model"], "running": true, "turn_started_at": 1_700_000_100,
     "started_at": 1_700_000_000, "status": "working", "inflight": inflight]
}

/// `message.complete` with its receipt (`prompt_turn.py:873-922,939-940`).
func completePayload(_ text: String, rows: [Int], complete: Bool = true) -> JSONValue {
    ["text": .string(text), "status": "complete",
     "persisted_turn": ["row_ids": .array(rows.map { .number(Double($0)) }), "complete": .bool(complete),
                        "user_row_id": .number(Double(rows[0])), "final_assistant_row_id": .number(Double(rows.last!))]]
}

/// Waits for the newest page and every re-read it set off (`ChatSession.rereadIfNeeded`).
@MainActor
func settle(_ session: ChatSession) async {
    await session.historyTask?.value
    while let reread = session.rereadTask { await reread.value }
}

/// A gateway whose sessions all read from one stored transcript.
final class PagedServer: Sendable {
    let store: FakeMessageStore
    /// When set, `session.resume` finds the session live with this turn running.
    let runningTurn = Mutex<JSONValue?>(nil)
    /// When set, the deferred ack reports this `message_count` instead of the stored size.
    let ackCount = Mutex<Int?>(nil)
    /// When set, `prompt.submit` answers a busy session: `queued`, `redirected` or
    /// `steered`, with no `user_row_id` and no row written by the submit itself
    /// (`tui_gateway/session_auto_continue.py:259,450`).
    let busyStatus = Mutex<String?>(nil)
    /// When set, `prompt.submit` gets no answer; the test fails it with `respondError`.
    let holdSubmits = Mutex(false)
    /// Methods left unanswered; the test answers them (`respond(to:)`) or fails them.
    let held = Mutex<Set<String>>([])
    /// The Bot Chat lineage tip the registry lookup names (default `coder-chat`):
    /// Desktop compressed or replaced the chat.
    let botTip = Mutex<String?>(nil)
    /// The registry has no Bot Chat any more (Desktop deleted it).
    let botChatGone = Mutex(false)
    /// The stored key each runtime session was resumed with.
    let keysBySID = Mutex<[String: String]>([:])
    /// Overrides the stored key `session.activate` reports (a recycled runtime id).
    let activateKey = Mutex<String?>(nil)
    /// Whether `session.activate` reports a turn running.
    let activateRunning = Mutex(false)
    private let counter = Mutex(0)

    init(store: FakeMessageStore) { self.store = store }

    func handle(_ method: String, _ params: JSONValue) -> JSONValue? {
        if held.withLock({ $0.contains(method) }) { return nil }
        return answer(method, params)
    }

    /// What this gateway answers, held or not.
    func answer(_ method: String, _ params: JSONValue) -> JSONValue? {
        switch method {
        case "session.activate":
            // `_live_session_payload(omit_messages=True)` (`server.py:3146-3186`,
            // `methods_session.py:1160-1172`): no messages, the stored key, idle.
            let sid = params["session_id"]?.stringValue ?? ""
            return ["session_id": .string(sid), "session_key": .string(activateKey.withLock { $0 } ?? keysBySID.withLock { $0[sid] } ?? sid),
                    "message_count": .number(Double(store.rows.count)), "messages": [], "messages_omitted": true,
                    "info": ["model": "test-model"], "running": .bool(activateRunning.withLock { $0 }),
                    "status": "idle", "inflight": nil]
        case "profiles.list":
            return ["profiles": [profileRowPayload("default", isDefault: true),
                                 profileRowPayload("coder", canonical: canonicalPayload(id: "coder-chat"))],
                    "bot_mode_protocol": true, "install_id": "test"]
        case "session.list":
            if params["title"] == "Bot Chat" {
                if botChatGone.withLock({ $0 }) { return ["sessions": []] }
                let tip = botTip.withLock { $0 } ?? "coder-chat"
                return ["sessions": [["id": "coder-chat", "resolved_id": .string(tip), "title": "Bot Chat",
                                      "preview": "", "started_at": 1_700_000_000,
                                      "message_count": .number(Double(store.rows.count)), "source": "desktop"]]]
            }
            return ["sessions": [["id": "stored-1", "title": "Earlier", "message_count": .number(Double(store.rows.count))]]]
        case "session.resume":
            let key = params["session_id"]?.stringValue ?? ""
            let n = counter.withLock { $0 += 1; return $0 }
            keysBySID.withLock { $0["rt-\(n)"] = key }
            if let inflight = runningTurn.withLock({ $0 }) {
                return liveAck(sid: "rt-\(n)", key: key, count: store.rows.count, inflight: inflight)
            }
            return deferredAck(sid: "rt-\(n)", key: key, count: ackCount.withLock { $0 } ?? store.rows.count)
        case "prompt.submit":
            if holdSubmits.withLock({ $0 }) { return nil }
            if let status = busyStatus.withLock({ $0 }) { return ["status": .string(status)] }
            // No text (an image-only prompt): `_write_submit_user_row` returns early
            // (`tui_gateway/session_workdir.py:621`), so no row and no `user_row_id`
            // (`methods_prompt.py:815-820`); the turn stores the `@image:` row when it runs.
            if (params["text"]?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return ["status": "streaming"]
            }
            // The prompt's row is written at submit (`methods_prompt.py:817-820`).
            let id = (store.rows.last?.id ?? 0) + 1
            store.append([storedRow(id: id, role: "user", text: params["text"]?.stringValue)])
            return ["status": "streaming", "user_row_id": .number(Double(id))]
        case "image.attach_bytes":
            // `_attached_image_result` (`methods_prompt.py:886-914,1222-1226`).
            let n = counter.withLock { $0 += 1; return $0 }
            let ext = ((params["filename"]?.stringValue ?? "x.png") as NSString).pathExtension
            let path = "/home/u/.hermes/images/upload_20261006_120000_\(n).\(ext)"
            return ["attached": true, "path": .string(path), "count": 1, "remainder": "",
                    "text": .string("[User attached image: \((path as NSString).lastPathComponent)]"),
                    "bytes": 4, "name": .string((path as NSString).lastPathComponent)]
        case "image.detach":
            return ["detached": true, "count": 0]  // `methods_prompt.py:998-1010`
        case "session.interrupt":
            return ["status": "interrupted"]  // `methods_session_interrupt.py:64`
        case "session.branch":
            // `_branch_live`'s answer (`tui_gateway/methods_session_branch.py:133-138`).
            let count = params["count"]?.intValue ?? store.rows.count
            return ["session_id": "rt-branch-1", "stored_session_id": "branch-1", "title": "Earlier #2",
                    "parent": "stored-1", "message_count": .number(Double(count)), "messages": [],
                    "info": ["model": "test-model"]]
        default:
            return nil
        }
    }

    /// A connected `GatewayConnection` reading pages from `store`, roster loaded.
    @MainActor
    func connect(log: FrameLog, epoch: String = "E1",
                 extra: [FakeTransport] = []) async throws -> (GatewayConnection, FakeTransport) {
        let transport = FakeTransport()
        transport.serve(epoch: epoch, log: log, handle)
        var configuration = GatewayClient.Configuration()
        configuration.heartbeatInterval = nil
        let connection = GatewayConnection(configuration: configuration, backoff: { _ in .milliseconds(1) })
        try await connection.connect(using: FakeConnector([transport] + extra, messages: store))
        try await connection.refreshBots()
        return (connection, transport)
    }
}
