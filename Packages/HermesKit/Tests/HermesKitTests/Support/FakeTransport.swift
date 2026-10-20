import Foundation
import HermesKit
import HermesProtocol
import Synchronization
import Testing

/// In-memory `MessageTransport`: tests push server frames with `serverSends`
/// and await client frames with `nextSent()`.
// Mutable state is mutex protected; the stream continuation is Sendable.
final class FakeTransport: MessageTransport, @unchecked Sendable {
    private struct State {
        var sent: [String] = []
        var waiters: [(id: UUID, continuation: CheckedContinuation<String?, Never>)] = []
        var connected = false
        /// The client closed the transport.
        var closed = false
        /// Closed or dropped: no frame will follow those already sent.
        var finished = false
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
        let waiter = state.withLock { state -> CheckedContinuation<String?, Never>? in
            if !state.waiters.isEmpty { return state.waiters.removeFirst().continuation }
            state.sent.append(text)
            return nil
        }
        waiter?.resume(returning: text)
    }

    func close() async {
        state.withLock { $0.closed = true }
        finishReaders()
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

    private func finishReaders() {
        let waiters = state.withLock { state in
            state.finished = true
            defer { state.waiters.removeAll() }
            return state.waiters
        }
        for waiter in waiters { waiter.continuation.resume(returning: nil) }
    }

    /// Simulates the server dropping the connection.
    func serverDrops(code: Int = 1006) {
        finishReaders()
        pair.continuation.finish(throwing: TransportError.closed(code: code, reason: "dropped"))
    }

    /// Assertion-facing read: a missing frame records the caller's location.
    func nextSent(sourceLocation: SourceLocation = #_sourceLocation) async -> JSONValue {
        guard let frame = await readSent() else {
            Issue.record("transport closed or task cancelled while waiting for a client frame",
                         sourceLocation: sourceLocation)
            return .null
        }
        return frame
    }

    /// Server-loop read. Shutdown/cancellation is normal here, not a test issue.
    /// Registration, cancellation and send/close all remove a waiter under the
    /// same mutex; the winner resumes it once, outside the lock.
    func readSent() async -> JSONValue? {
        let id = UUID()
        let text: String? = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let ready = state.withLock { state -> String?? in
                    if Task.isCancelled { return .some(nil) }
                    if !state.sent.isEmpty { return .some(state.sent.removeFirst()) }
                    if state.finished { return .some(nil) }
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

    /// Test synchronization: lets cancellation tests wait for registration.
    var pendingReaders: Int { state.withLock { $0.waiters.count } }

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
        guard capabilities["method"]?.stringValue == "client.capabilities" else {
            Issue.record("expected client.capabilities, got \(capabilities)")
            return
        }
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
                guard let frame = await self.readSent() else { break }
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
    let messagesSource: (any SessionMessagesSource)?
    let cronSource: (any CronSource)?
    let sessionLinkSource: (any SessionLinkSource)?

    init(_ transports: [FakeTransport], messages: (any SessionMessagesSource)? = nil,
         cron: (any CronSource)? = nil, links: (any SessionLinkSource)? = nil) {
        self.transports = Mutex(transports)
        self.messagesSource = messages
        self.cronSource = cron
        self.sessionLinkSource = links
    }

    func makeTransport() async throws -> any MessageTransport {
        guard let next = transports.withLock({ $0.isEmpty ? nil : $0.removeFirst() }) else {
            throw TransportError.handshakeFailed("no more fake transports")
        }
        return next
    }
}

/// Polls main-actor state until it holds, every 10 ms, `seconds * 100` times.
/// Counts polls rather than wall time: on a starved runner each poll takes longer,
/// so the budget stretches with the load instead of running out before the awaited
/// work could run. Cancellation (a test's time limit) stops polling.
@MainActor
func eventually(seconds: Int = 3, _ condition: @MainActor () -> Bool) async -> Bool {
    for _ in 0..<(seconds * 100) {
        if condition() { return true }
        do { try await Task.sleep(for: .milliseconds(10)) } catch { break }
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
