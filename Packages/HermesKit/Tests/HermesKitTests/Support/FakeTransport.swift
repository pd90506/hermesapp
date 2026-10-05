import Foundation
import HermesKit
import HermesProtocol
import Synchronization

/// In-memory `MessageTransport`: tests push server frames with `serverSends`
/// and await client frames with `nextSent()`.
final class FakeTransport: MessageTransport, @unchecked Sendable {
    private struct State {
        var sent: [String] = []
        var waiters: [CheckedContinuation<String, Never>] = []
        var connected = false
        var closed = false
    }

    private let state = Mutex(State())
    private let pair = AsyncThrowingStream<String, any Error>.makeStream()
    private let connectError: (any Error)?
    private let connectDelay: Duration?

    var inbound: AsyncThrowingStream<String, any Error> { pair.stream }

    /// - Parameter connectDelay: a slow handshake that, like the real
    ///   transport, ignores task cancellation.
    init(connectError: (any Error)? = nil, connectDelay: Duration? = nil) {
        self.connectError = connectError
        self.connectDelay = connectDelay
    }

    func connect() async throws {
        if let connectDelay {
            let deadline = ContinuousClock.now + connectDelay
            while ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(5)) }
        }
        if let connectError { throw connectError }
        state.withLock { $0.connected = true }
    }

    func send(_ text: String) async throws {
        let waiter = state.withLock { state -> CheckedContinuation<String, Never>? in
            if !state.waiters.isEmpty { return state.waiters.removeFirst() }
            state.sent.append(text)
            return nil
        }
        waiter?.resume(returning: text)
    }

    func close() async {
        state.withLock { $0.closed = true }
        pair.continuation.finish()
    }

    var isClosed: Bool { state.withLock { $0.closed } }

    /// Handshake completed and not closed since: a live socket.
    var isOpen: Bool { state.withLock { $0.connected && !$0.closed } }

    // MARK: Test helpers

    /// Pushes a raw frame from the "server".
    func serverSends(_ text: String) {
        pair.continuation.yield(text)
    }

    func serverSends(_ value: JSONValue) {
        serverSends(String(decoding: try! JSONEncoder().encode(value), as: UTF8.self))
    }

    /// Simulates the server dropping the connection.
    func serverDrops(code: Int = 1006) {
        pair.continuation.finish(throwing: TransportError.closed(code: code, reason: "dropped"))
    }

    /// Next frame written by the client, parsed.
    func nextSent() async -> JSONValue {
        let text: String = await withCheckedContinuation { continuation in
            let ready = state.withLock { state -> String? in
                if !state.sent.isEmpty { return state.sent.removeFirst() }
                state.waiters.append(continuation)
                return nil
            }
            if let ready { continuation.resume(returning: ready) }
        }
        return try! JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
    }

    // MARK: Canned server frames

    func sendReady(epoch: String = "epoch-1", heartbeat: Bool = false) {
        serverSends([
            "jsonrpc": "2.0", "method": "event",
            "params": ["type": "gateway.ready",
                       "payload": ["skin": [:], "change_events": true, "heartbeat": .bool(heartbeat),
                                   "replay_epoch": .string(epoch)]],
        ])
    }

    func respond(to request: JSONValue, result: JSONValue) {
        serverSends(["jsonrpc": "2.0", "id": request["id"] ?? .null, "result": result])
    }

    func respondError(to request: JSONValue, code: Int, message: String) {
        serverSends(["jsonrpc": "2.0", "id": request["id"] ?? .null,
                     "error": ["code": .number(Double(code)), "message": .string(message)]])
    }

    func sendEvent(_ type: String, sessionID: String = "sid-1", seq: Int? = nil, payload: JSONValue? = nil) {
        var params: [String: JSONValue] = ["type": .string(type), "session_id": .string(sessionID)]
        if let seq { params["seq"] = .number(Double(seq)) }
        if let payload { params["payload"] = payload }
        serverSends(["jsonrpc": "2.0", "method": "event", "params": .object(params)])
    }

    /// Plays the server side of the connect handshake.
    func completeHandshake(epoch: String = "epoch-1", heartbeat: Bool = false) async {
        sendReady(epoch: epoch, heartbeat: heartbeat)
        let capabilities = await nextSent()
        precondition(capabilities["method"]?.stringValue == "client.capabilities")
        respond(to: capabilities, result: ["server_requests": ["approval", "clarify", "sudo", "secret"],
                                           "declines_not_shown": true])
    }
}

extension FakeTransport {
    /// Runs a scripted server on this transport: sends `gateway.ready`, then
    /// answers every client request whose method `handler` returns a result
    /// for (`nil` = leave unanswered). Every client frame is appended to `log`.
    func serve(epoch: String = "epoch-1", log: FrameLog,
               _ handler: @escaping @Sendable (_ method: String, _ params: JSONValue) -> JSONValue?) {
        sendReady(epoch: epoch)
        Task {
            while !self.isClosed {
                let frame = await self.nextSent()
                log.append(frame)
                guard let method = frame["method"]?.stringValue, frame["id"] != nil else { continue }
                if method == "client.capabilities" {
                    self.respond(to: frame, result: ["server_requests": ["approval", "clarify", "sudo", "secret"]])
                } else if let result = handler(method, frame["params"] ?? .null) {
                    self.respond(to: frame, result: result)
                }
            }
        }
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

    init(_ transports: [FakeTransport]) {
        self.transports = Mutex(transports)
    }

    func makeTransport() async throws -> any MessageTransport {
        guard let next = transports.withLock({ $0.isEmpty ? nil : $0.removeFirst() }) else {
            throw TransportError.handshakeFailed("no more fake transports")
        }
        return next
    }
}

/// Polls `condition` on the main actor until it holds or ~3 s pass.
@MainActor
func eventually(_ condition: @MainActor () -> Bool) async -> Bool {
    for _ in 0..<300 {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return condition()
}

/// Reads `GatewayClient.Inbound` items for assertions. Used from one test task only.
final class InboundRecorder: @unchecked Sendable {
    private var iterator: AsyncStream<GatewayClient.Inbound>.AsyncIterator

    init(_ stream: AsyncStream<GatewayClient.Inbound>) {
        iterator = stream.makeAsyncIterator()
    }

    func next() async -> GatewayClient.Inbound? {
        await iterator.next()
    }

    func nextEvent() async -> GatewayEvent? {
        while let item = await iterator.next() {
            if case .event(let event) = item { return event }
        }
        return nil
    }
}
