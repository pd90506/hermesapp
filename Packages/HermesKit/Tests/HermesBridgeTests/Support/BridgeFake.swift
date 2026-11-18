import Foundation
import HermesKit
import HermesProtocol
import Synchronization
@testable import HermesBridge
import Testing

/// A scripted gateway for the bridge tests: an in-memory transport the test drives,
/// answering the methods a connected bridge calls. Only the public HermesKit API.
///
/// Frame shapes copy `Tests/HermesKitTests`' fakes; the payload helpers cite the same
/// Hermes sources (see `Support/ScriptedGateway.swift`).

// MARK: - Transport

/// In-memory `MessageTransport`: tests push server frames with `serverSends`
/// and await client frames with `readSent()`.
final class FakeTransport: MessageTransport, @unchecked Sendable {
    private struct State {
        var sent: [String] = []
        var waiters: [(id: UUID, continuation: CheckedContinuation<String?, Never>)] = []
        var connected = false
        var closed = false
        var finished = false
    }

    private let state = Mutex(State())
    private let pair = AsyncThrowingStream<String, any Error>.makeStream()

    var inbound: AsyncThrowingStream<String, any Error> { pair.stream }

    func connect() async throws { state.withLock { $0.connected = true } }

    func send(_ text: String) async throws {
        let waiter = state.withLock { state -> CheckedContinuation<String?, Never>? in
            if !state.waiters.isEmpty { return state.waiters.removeFirst().continuation }
            state.sent.append(text)
            return nil
        }
        waiter?.resume(returning: text)
    }

    func close() async {
        let waiters = state.withLock { state in
            state.closed = true
            state.finished = true
            defer { state.waiters.removeAll() }
            return state.waiters
        }
        for waiter in waiters { waiter.continuation.resume(returning: nil) }
        pair.continuation.finish()
    }

    var isClosed: Bool { state.withLock { $0.closed } }
    var isOpen: Bool { state.withLock { $0.connected && !$0.closed } }

    // MARK: Test helpers

    func serverSends(_ text: String) { pair.continuation.yield(text) }

    func serverSends(_ value: JSONValue) {
        serverSends(String(decoding: try! JSONEncoder().encode(value), as: UTF8.self))
    }

    /// Server-loop read. Shutdown/cancellation is normal here, not a test issue.
    func readSent() async -> JSONValue? {
        let id = UUID()
        let text: String? = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let ready = state.withLock { state -> String?? in
                    if Task.isCancelled { return .some(nil) }
                    if !state.sent.isEmpty { return .some(state.sent.removeFirst()) }
                    if state.closed || state.finished { return .some(nil) }
                    state.waiters.append((id, continuation))
                    return nil
                }
                if let ready { continuation.resume(returning: ready) }
            }
        } onCancel: {
            let waiter = state.withLock { state in
                state.waiters.firstIndex { $0.id == id }.map { state.waiters.remove(at: $0).continuation }
            }
            waiter?.resume(returning: nil)
        }
        return text.map { try! JSONDecoder().decode(JSONValue.self, from: Data($0.utf8)) }
    }

    func respond(to request: JSONValue, result: JSONValue) {
        serverSends(["jsonrpc": "2.0", "id": request["id"] ?? .null, "result": result])
    }

    func respondError(to request: JSONValue, code: Int, message: String) {
        serverSends(["jsonrpc": "2.0", "id": request["id"] ?? .null,
                     "error": ["code": .number(Double(code)), "message": .string(message)]])
    }

    func sendEvent(_ type: String, sessionID: String = "sid-1", payload: JSONValue? = nil) {
        var params: [String: JSONValue] = ["type": .string(type), "session_id": .string(sessionID)]
        if let payload { params["payload"] = payload }
        serverSends(["jsonrpc": "2.0", "method": "event", "params": .object(params)])
    }

    /// A server→client request, as the gateway delivers it.
    func sendRequest(_ method: String, id: String, params: JSONValue) {
        serverSends(["jsonrpc": "2.0", "id": .string(id), "method": .string(method), "params": params])
    }

    func sendReady(epoch: String = "epoch-1") {
        serverSends([
            "jsonrpc": "2.0", "method": "event",
            "params": ["type": "gateway.ready",
                       "payload": ["skin": [:], "change_events": true, "heartbeat": .bool(false),
                                   "replay_epoch": .string(epoch)]],
        ])
    }
}

/// Thread-safe record of frames a fake server received.
final class FrameLog: Sendable {
    private let frames = Mutex<[JSONValue]>([])
    func append(_ frame: JSONValue) { frames.withLock { $0.append(frame) } }
    var all: [JSONValue] { frames.withLock { $0 } }
    func requests(_ method: String) -> [JSONValue] { all.filter { $0["method"]?.stringValue == method } }
}

/// Hands out pre-built transports, one per connection attempt.
final class FakeConnector: GatewayConnector, @unchecked Sendable {
    private let transports: Mutex<[FakeTransport]>
    let messagesSource: (any SessionMessagesSource)?
    let cronSource: (any CronSource)?
    let searchSource: (any SessionSearchSource)?

    init(_ transports: [FakeTransport], messages: (any SessionMessagesSource)? = nil,
         cron: (any CronSource)? = nil, search: (any SessionSearchSource)? = nil) {
        self.transports = Mutex(transports)
        self.messagesSource = messages
        self.cronSource = cron
        self.searchSource = search
    }

    func makeTransport() async throws -> any MessageTransport {
        guard let next = transports.withLock({ $0.isEmpty ? nil : $0.removeFirst() }) else {
            throw TransportError.handshakeFailed("no more fake transports")
        }
        return next
    }
}

// MARK: - Server

/// A scripted gateway with canned answers, as the bridge's flows need them:
/// a connect (`client.capabilities`, `profiles.list`), opening a chat
/// (`session.list` / `session.create` / `session.resume`) and the calls the
/// desktop commands make.
final class BridgeServer: Sendable {
    let log = FrameLog()
    let transport = FakeTransport()
    private let replies: Mutex<[String: @Sendable (JSONValue) -> JSONValue?]>

    /// A roster with one profile, `coder`, its Bot Chat and one stored session.
    static let roster: JSONValue = [
        profileRow("coder", canonical: ["id": "coder-chat", "resolved_id": "coder-chat", "root_title": "Bot Chat",
                                        "title": "Bot Chat", "preview": "hi", "started_at": 1_700_000_000,
                                        "last_active": 1_700_000_000, "message_count": 2, "live_message_count": 2]),
    ]

    init(_ replies: [String: @Sendable (JSONValue) -> JSONValue?] = [:]) {
        self.replies = Mutex(replies)
    }

    func on(_ method: String, _ reply: @escaping @Sendable (JSONValue) -> JSONValue?) {
        replies.withLock { $0[method] = reply }
    }

    func start() {
        transport.sendReady()
        Task {
            while !self.transport.isClosed {
                guard let frame = await self.transport.readSent() else { break }
                self.log.append(frame)
                guard let method = frame["method"]?.stringValue, frame["id"] != nil else { continue }
                switch method {
                case "client.capabilities":
                    self.transport.respond(to: frame,
                        result: ["server_requests": ["approval", "clarify", "sudo", "secret"], "declines_not_shown": true])
                case "profiles.list":
                    self.transport.respond(to: frame,
                        result: ["profiles": Self.roster, "bot_mode_protocol": true, "install_id": "test"])
                case "session.list":
                    self.transport.respond(to: frame, result: ["sessions": []])
                case "prompt.submit":
                    self.transport.respond(to: frame, result: ["status": "streaming"])
                default:
                    let handler = self.replies.withLock { $0[method] }
                    if let result = handler?(frame["params"] ?? .null) {
                        self.transport.respond(to: frame, result: result)
                    }
                }
            }
        }
    }

    /// `session.resume` answering a resumed session (`methods_session.py:908-911`:
    /// `session_key`, no `stored_session_id`).
    static func resumed(sid: String, key: String, openRequests: JSONValue? = nil) -> JSONValue {
        var payload: [String: JSONValue] = [
            "session_id": .string(sid), "resumed": .string(key), "session_key": .string(key), "message_count": 0,
            "messages": [], "info": ["model": "test-model"], "running": false, "status": "idle", "inflight": nil,
        ]
        if let openRequests { payload["open_requests"] = openRequests }
        return .object(payload)
    }

    /// `session.create` result (`contracts/sessions.py:142-147`).
    static func created(sid: String, key: String) -> JSONValue {
        ["session_id": .string(sid), "stored_session_id": .string(key), "message_count": 0, "messages": [],
         "info": ["model": "test-model"]]
    }

    static func profileRow(_ name: String, isDefault: Bool = true,
                           canonical: JSONValue? = nil) -> JSONValue {
        var row: [String: JSONValue] = [
            "name": .string(name), "path": .string("/srv/hermes/profiles/\(name)"), "is_default": .bool(isDefault),
            "model": "test-model", "provider": "test-provider", "description": "", "display_name": .string(name),
            "skill_count": 3, "previous_names": [], "role": nil,
            "last_session": nil, "worker_session": nil, "canonical_session": canonical ?? nil,
            "ui_meta_revisions": [:], "has_avatar": false,
        ]
        return .object(row)
    }
}

// MARK: - Awaiting main-actor state

/// Polls main-actor state until it holds, every 10 ms, `seconds * 100` times, as
/// `Tests/HermesKitTests`' `eventually`.
@MainActor
func eventually(seconds: Int = 3, _ condition: @MainActor () -> Bool) async -> Bool {
    for _ in 0..<(seconds * 100) {
        if condition() { return true }
        do { try await Task.sleep(for: .milliseconds(10)) } catch { break }
    }
    return condition()
}

/// Collects what the bridge emits. The events are parsed on demand: the mutex holds
/// only strings (Sendable), as the other bridge suites' outboxes do.
final class Outbox: Sendable {
    private let events = Mutex<[String]>([])
    func append(_ json: String) { events.withLock { $0.append(json) } }

    private var parsed: [[String: Any]] {
        events.withLock { $0 }.map { (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any] ?? [:] }
    }

    var all: [[String: Any]] { parsed }
    var last: [String: Any] { parsed.last ?? [:] }
    func last(_ type: String) -> [String: Any]? { parsed.last(where: { $0["type"] as? String == type }) }
}

// MARK: - The bridge over the fake

@MainActor
extension Bridge {
    /// A bridge connected to `server` (its roster already read): the connect's snapshots
    /// are in `outbox` by the time this returns.
    static func connected(_ server: BridgeServer, outbox: Outbox,
                          cron: (any CronSource)? = nil, search: (any SessionSearchSource)? = nil) async throws -> Bridge {
        server.start()
        let connector = FakeConnector([server.transport], cron: cron, search: search)
        let bridge = Bridge(emit: { outbox.append($0) }) { _, _ in connector }
        try await bridge.receive(#"{"id":"c0","method":"connect","params":{"url":"http://hermes.test","token":"t"}}"#)
        return bridge
    }

    /// Opens a new side chat of `profile`, whose snapshots are in `outbox` too.
    static func openedChat(_ bridge: Bridge, outbox: Outbox, server: BridgeServer,
                           profile: String = "coder", sid: String = "rt-1", key: String = "stored-1") async throws -> String {
        server.on("session.create") { _ in BridgeServer.created(sid: sid, key: key) }
        let id = "open-\(sid)"
        try await bridge.receive(#"{"id":"\#(id)","method":"newChat","params":{"profile":"\#(profile)"}}"#)
        return id
    }
}
