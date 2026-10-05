import Foundation
import HermesProtocol

public enum GatewayClientError: Error, Sendable, Equatable {
    case notConnected
    case alreadyConnected
    case connectionClosed(String?)
    case readyTimeout
    case heartbeatTimeout
    case timeout(method: String)
    case decoding(method: String, String)
    case replayInProgress
}

/// JSON-RPC client for one Hermes TUI-gateway WebSocket connection.
///
/// Responsibilities (see `docs/protocol.md`):
/// - waits for the `gateway.ready` event, then sends
///   `client.capabilities {server_requests: true}`;
/// - correlates request ids (`r1`, `r2`, …) with responses, with timeouts
///   and task cancellation;
/// - writes frames strictly in call order through a single outbox;
/// - fans out `event` notifications and server→client requests to
///   subscribers, tracking the per-session `seq` watermark;
/// - rejects server requests it does not support with -32601;
/// - sends `gateway.ping` heartbeats and drops a silent connection.
///
/// One instance per connection. Reconnecting means creating a new client
/// with a new transport (tickets are single-use); `GatewayConnection` does that.
public actor GatewayClient {
    public struct Configuration: Sendable {
        public var requestTimeout: Duration = .seconds(120)
        public var readyTimeout: Duration = .seconds(15)
        /// `nil` disables heartbeats. Only used when `gateway.ready.heartbeat` is true.
        public var heartbeatInterval: Duration? = .seconds(15)
        public var heartbeatTimeout: Duration = .seconds(45)
        public var supportedServerRequests: Set<String> = ServerRequestMethod.mvpSupported

        public init() {}
    }

    public enum Inbound: Sendable {
        case event(GatewayEvent)
        case serverRequest(ServerRequest)
        /// Terminal. `nil` error means a deliberate `close()`.
        case disconnected((any Error)?)
    }

    public enum State: Sendable, Equatable {
        case idle, connecting, connected, closed
    }

    private let transport: any MessageTransport
    private let configuration: Configuration
    private let outbox: AsyncStream<String>.Continuation
    private let outboxStream: AsyncStream<String>

    public private(set) var state: State = .idle
    public private(set) var ready: GatewayReady?
    public private(set) var capabilities: ClientCapabilitiesResult?
    /// Highest `seq` seen per runtime session id.
    public private(set) var lastSeq: [String: Int] = [:]

    private var pending: [String: CheckedContinuation<JSONValue, any Error>] = [:]
    private var readyWaiters: [CheckedContinuation<GatewayReady, any Error>] = []
    private var subscribers: [UUID: AsyncStream<Inbound>.Continuation] = [:]
    private var openServerRequests: Set<String> = []
    private var replayBuffers: [String: [GatewayEvent]] = [:]
    private var nextRequestNumber = 0
    private var heartbeatNumber = 0
    private var lastInbound = ContinuousClock.now
    private var tasks: [Task<Void, Never>] = []

    public init(transport: any MessageTransport, configuration: Configuration = .init()) {
        self.transport = transport
        self.configuration = configuration
        (outboxStream, outbox) = AsyncStream<String>.makeStream()
    }

    deinit {
        // Dropping the last reference closes the connection.
        for task in tasks { task.cancel() }
        outbox.finish()
        for continuation in subscribers.values {
            continuation.yield(.disconnected(GatewayClientError.connectionClosed("client released")))
            continuation.finish()
        }
        for continuation in pending.values {
            continuation.resume(throwing: GatewayClientError.connectionClosed("client released"))
        }
        if state != .closed {
            Task { [transport] in await transport.close() }
        }
    }

    // MARK: - Subscription

    /// A stream of inbound events and server requests. Subscribe before
    /// `connect()` to observe everything. Ends after `.disconnected`.
    public func inbound() -> AsyncStream<Inbound> {
        let (stream, continuation) = AsyncStream<Inbound>.makeStream()
        guard state != .closed else {
            continuation.yield(.disconnected(GatewayClientError.connectionClosed(nil)))
            continuation.finish()
            return stream
        }
        let key = UUID()
        subscribers[key] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.unsubscribe(key) }
        }
        return stream
    }

    private func unsubscribe(_ key: UUID) {
        subscribers[key] = nil
    }

    private func broadcast(_ item: Inbound) {
        for continuation in subscribers.values { continuation.yield(item) }
    }

    // MARK: - Lifecycle

    /// Opens the transport, waits for `gateway.ready`, and advertises
    /// server-request support. Returns the ready payload.
    @discardableResult
    public func connect() async throws -> GatewayReady {
        guard state == .idle else { throw GatewayClientError.alreadyConnected }
        state = .connecting
        do {
            try await transport.connect()
        } catch {
            state = .closed
            finishSubscribers(error)
            throw error
        }
        lastInbound = .now
        startWriter()
        startReader()
        do {
            let ready = try await waitForReady()
            state = .connected
            capabilities = try await call(
                GatewayMethod.clientCapabilities, params: ClientCapabilitiesParams(serverRequests: true),
                as: ClientCapabilitiesResult.self)
            if ready.heartbeat == true, let interval = configuration.heartbeatInterval {
                startHeartbeat(every: interval)
            }
            return ready
        } catch {
            await connectionEnded(error)
            throw error
        }
    }

    /// Closes the connection deliberately. Pending calls fail with `connectionClosed`.
    public func close() async {
        await connectionEnded(nil)
    }

    private func waitForReady() async throws -> GatewayReady {
        if let ready { return ready }
        let timeout = configuration.readyTimeout
        let timer = Task { [weak self] in
            do { try await Task.sleep(for: timeout) } catch { return }
            await self?.failReadyWaiters(GatewayClientError.readyTimeout)
        }
        defer { timer.cancel() }
        return try await withCheckedThrowingContinuation { readyWaiters.append($0) }
    }

    private func failReadyWaiters(_ error: any Error) {
        let waiters = readyWaiters
        readyWaiters.removeAll()
        for waiter in waiters { waiter.resume(throwing: error) }
    }

    private func connectionEnded(_ error: (any Error)?) async {
        guard state != .closed else { return }
        state = .closed
        for task in tasks { task.cancel() }
        tasks.removeAll()
        outbox.finish()

        let closedError = GatewayClientError.connectionClosed(error.map { String(describing: $0) })
        let calls = pending
        pending.removeAll()
        for continuation in calls.values { continuation.resume(throwing: closedError) }
        failReadyWaiters(error ?? closedError)
        openServerRequests.removeAll()
        replayBuffers.removeAll()

        finishSubscribers(error)
        await transport.close()
    }

    private func finishSubscribers(_ error: (any Error)?) {
        broadcast(.disconnected(error))
        for continuation in subscribers.values { continuation.finish() }
        subscribers.removeAll()
    }

    // MARK: - Calls

    /// Sends a request and awaits its result.
    public func call(_ method: String, params: JSONValue? = nil, timeout: Duration? = nil) async throws -> JSONValue {
        guard state == .connecting || state == .connected else { throw GatewayClientError.notConnected }
        nextRequestNumber += 1
        let id = "r\(nextRequestNumber)"
        let frame = try Self.encode(.request(RPCRequest(id: .string(id), method: method, params: params)))

        let limit = timeout ?? configuration.requestTimeout
        let timer = Task { [weak self] in
            do { try await Task.sleep(for: limit) } catch { return }
            await self?.failPending(id, GatewayClientError.timeout(method: method))
        }
        defer { timer.cancel() }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<JSONValue, any Error>) in
                pending[id] = continuation
                outbox.yield(frame)
            }
        } onCancel: {
            Task { [weak self] in await self?.failPending(id, CancellationError()) }
        }
    }

    /// Typed convenience over `call(_:params:timeout:)`.
    public func call<Params: Encodable & Sendable, Result: Decodable>(
        _ method: String, params: Params, as resultType: Result.Type = Result.self, timeout: Duration? = nil
    ) async throws -> Result {
        let value = try await call(method, params: try JSONValue(encoding: params), timeout: timeout)
        do {
            return try value.decode(Result.self)
        } catch {
            throw GatewayClientError.decoding(method: method, String(describing: error))
        }
    }

    private func failPending(_ id: String, _ error: any Error) {
        pending.removeValue(forKey: id)?.resume(throwing: error)
    }

    // MARK: - Server requests

    /// Answers a server→client request with a result.
    public func respond(to requestID: String, result: JSONValue) throws {
        try sendResponse(RPCResponse(id: .string(requestID), result: result))
    }

    /// Answers a server→client request with an error (e.g. a user decline
    /// the agent should treat as failure).
    public func respond(to requestID: String, error: RPCError) throws {
        try sendResponse(RPCResponse(id: .string(requestID), error: error))
    }

    private func sendResponse(_ response: RPCResponse) throws {
        guard state == .connecting || state == .connected else { throw GatewayClientError.notConnected }
        if let id = response.id { openServerRequests.remove(id.description) }
        outbox.yield(try Self.encode(.response(response)))
    }

    /// Re-delivers unanswered requests returned as `open_requests` by
    /// `session.resume` / `session.activate` / `session.events.since`.
    /// Requests already delivered on this connection are skipped.
    public func redeliver(_ entries: [OpenRequestEntry]) {
        for entry in entries where configuration.supportedServerRequests.contains(entry.method) {
            deliver(ServerRequest(entry))
        }
    }

    private func deliver(_ request: ServerRequest) {
        guard openServerRequests.insert(request.id).inserted else { return }
        broadcast(.serverRequest(request))
    }

    // MARK: - Replay

    public struct ReattachResult: Sendable {
        /// `session.activate` snapshot (messages omitted).
        public var snapshot: LiveSessionSnapshot
        public var replay: SessionEventsSinceResult
        /// The replay can be trusted: not truncated, same backend epoch, and
        /// the server's seq is not behind our watermark. When false nothing
        /// was delivered and the caller must resync with `session.resume`.
        public var isComplete: Bool
    }

    /// Re-attaches a session that was live on a previous connection to the
    /// *same* backend, then replays what was missed.
    ///
    /// 1. Live events for the session are held back from now on.
    /// 2. `session.activate` rebinds event delivery to this socket and cancels
    ///    the orphan reap. `session.events.since` alone does neither
    ///    (`methods_session.py:2603-2617` vs `:1160-1172`), and it answers an
    ///    unknown or reaped session with an empty success. Activate fails with
    ///    4001/4007 instead, which the caller treats as "resume".
    /// 3. `session.events.since` fetches events after `lastSeen`; they are
    ///    delivered before the held-back live ones, deduplicated by `seq`.
    public func reattach(sessionID: String, lastSeen: Int) async throws -> ReattachResult {
        guard replayBuffers[sessionID] == nil else { throw GatewayClientError.replayInProgress }
        lastSeq[sessionID] = max(lastSeq[sessionID] ?? 0, lastSeen)
        replayBuffers[sessionID] = []
        let snapshot: LiveSessionSnapshot
        let result: SessionEventsSinceResult
        do {
            snapshot = try await call(
                GatewayMethod.sessionActivate,
                params: SessionActivateParams(sessionID: sessionID, omitMessages: true),
                as: LiveSessionSnapshot.self)
            result = try await call(
                GatewayMethod.sessionEventsSince,
                params: SessionEventsSinceParams(sessionID: sessionID, lastSeen: lastSeen),
                as: SessionEventsSinceResult.self)
        } catch {
            discardReplay(sessionID)
            throw error
        }
        let complete = !result.truncated && result.epoch == ready?.replayEpoch && result.latestSeq >= lastSeen
        if complete {
            for event in result.events { publish(event) }
            flushReplayBuffer(sessionID)
            redeliver(result.openRequests)
        } else {
            discardReplay(sessionID)
        }
        return ReattachResult(snapshot: snapshot, replay: result, isComplete: complete)
    }

    /// Drops held-back events and the watermark; a `session.resume` follows.
    private func discardReplay(_ sessionID: String) {
        replayBuffers[sessionID] = nil
        lastSeq[sessionID] = nil
    }

    private func flushReplayBuffer(_ sessionID: String) {
        let buffered = replayBuffers.removeValue(forKey: sessionID) ?? []
        for event in buffered { publish(event) }
    }

    // MARK: - Transport loops

    private func startWriter() {
        let stream = outboxStream
        let transport = self.transport
        tasks.append(Task { [weak self] in
            for await frame in stream {
                do {
                    try await transport.send(frame)
                } catch {
                    await self?.connectionEnded(error)
                    return
                }
            }
        })
    }

    private func startReader() {
        let transport = self.transport
        tasks.append(Task { [weak self] in
            do {
                for try await text in transport.inbound {
                    await self?.receive(text)
                }
                await self?.connectionEnded(GatewayClientError.connectionClosed("closed by server"))
            } catch {
                await self?.connectionEnded(error)
            }
        })
    }

    private func startHeartbeat(every interval: Duration) {
        tasks.append(Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: interval) } catch { return }
                await self?.heartbeatTick()
            }
        })
    }

    private func heartbeatTick() async {
        guard state == .connected else { return }
        if ContinuousClock.now - lastInbound > configuration.heartbeatTimeout {
            await connectionEnded(GatewayClientError.heartbeatTimeout)
            return
        }
        heartbeatNumber += 1
        // Not tracked in `pending`: any inbound frame counts as liveness.
        if let frame = try? Self.encode(.request(RPCRequest(
            id: .string("heartbeat-\(heartbeatNumber)"), method: GatewayMethod.gatewayPing)))
        {
            outbox.yield(frame)
        }
    }

    // MARK: - Inbound dispatch

    private func receive(_ text: String) {
        lastInbound = .now
        guard let message = try? RPCMessage.decode(Data(text.utf8)) else { return }
        switch message {
        case .response(let response):
            guard let id = response.id?.description, let continuation = pending.removeValue(forKey: id) else {
                return  // heartbeat reply or late answer to a timed-out call
            }
            if let error = response.error {
                continuation.resume(throwing: error)
            } else {
                continuation.resume(returning: response.result ?? .null)
            }

        case .request(let request):
            guard let id = request.id else {
                if request.method == GatewayEvent.notificationMethod,
                    let event = try? (request.params ?? .null).decode(GatewayEvent.self)
                {
                    receiveEvent(event)
                }
                return
            }
            let params = request.params ?? .object([:])
            if configuration.supportedServerRequests.contains(request.method) {
                deliver(ServerRequest(id: id.description, method: request.method, params: params))
            } else if let frame = try? Self.encode(.response(RPCResponse(id: id, error: Self.decline(request.method)))) {
                outbox.yield(frame)
            }
        }
    }

    private func receiveEvent(_ event: GatewayEvent) {
        if event.type == EventType.gatewayReady, case .gatewayReady(let payload) = event.kind {
            ready = payload
            let waiters = readyWaiters
            readyWaiters.removeAll()
            for waiter in waiters { waiter.resume(returning: payload) }
        }
        if let sid = event.sessionID, replayBuffers[sid] != nil {
            replayBuffers[sid]?.append(event)
            return
        }
        publish(event)
    }

    /// Delivers an event unless its `seq` was already seen.
    private func publish(_ event: GatewayEvent) {
        if let sid = event.sessionID, !sid.isEmpty, let seq = event.seq {
            if let last = lastSeq[sid], seq <= last { return }
            lastSeq[sid] = seq
        }
        if event.type == EventType.requestCancel, case .requestCancel(let cancel) = event.kind {
            openServerRequests.remove(cancel.id)
        }
        broadcast(.event(event))
    }

    /// The error for a server request this client does not handle: 4404 ("not
    /// shown here") for window-owned bridges so a Desktop window sharing the
    /// session can still answer; -32601 otherwise so the agent fails fast.
    static func decline(_ method: String) -> RPCError {
        if ServerRequestMethod.windowOwned.contains(method) {
            return RPCError(code: ServerRequestMethod.notShownCode, message: "not shown in this client")
        }
        return RPCError(code: RPCError.methodNotFound, message: "unsupported by client: \(method)")
    }

    private static func encode(_ message: RPCMessage) throws -> String {
        String(decoding: try message.encoded(), as: UTF8.self)
    }
}
