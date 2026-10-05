import Foundation
import HermesProtocol
import Observation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// App-level connection to one Hermes gateway: owns the current
/// `GatewayClient`, the session list, the active `ChatSession`, and
/// automatic reconnect with replay.
///
/// Restoring the active session on a new socket (see `docs/protocol.md` §7):
/// - same backend (`replay_epoch` unchanged since the last *successful*
///   restore) and a known `seq` watermark → `GatewayClient.reattach`
///   (`session.activate` + `session.events.since`);
/// - otherwise, or if that reports the session gone / the replay incomplete
///   → `session.resume` by the stored key and rebuild the transcript.
@MainActor
@Observable
public final class GatewayConnection {
    public enum State: Sendable, Equatable {
        case disconnected
        case connecting
        case connected
        case reconnecting(attempt: Int)
        case failed(String)
    }

    public private(set) var state: State = .disconnected
    public private(set) var sessions: [SessionSummary] = []
    public private(set) var activeSession: ChatSession?
    /// Server requests for sessions other than the active one (badge-worthy:
    /// the agent is blocked until someone answers).
    public private(set) var otherSessionRequests: [ServerRequest] = []

    /// Stop retrying after this many failed attempts (`nil` = retry forever).
    @ObservationIgnored public var maxReconnectAttempts: Int? = 20

    @ObservationIgnored private(set) var client: GatewayClient?
    @ObservationIgnored private var connector: (any GatewayConnector)?
    @ObservationIgnored private var inboundTask: Task<Void, Never>?
    @ObservationIgnored private var reconnectTask: Task<Void, Never>?
    /// Epoch the active session's `seq` watermark belongs to. Committed only
    /// after a restore succeeded, so a failed attempt on a restarted backend
    /// cannot make the next attempt believe it is on the same process.
    @ObservationIgnored private var committedEpoch: String?
    /// Bumped by every connect/disconnect; async work started under an older
    /// generation discards its result (and closes its socket) instead of
    /// overwriting newer state.
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private let configuration: GatewayClient.Configuration
    @ObservationIgnored private let backoff: @Sendable (Int) -> Duration

    public init(
        configuration: GatewayClient.Configuration = .init(),
        backoff: @escaping @Sendable (Int) -> Duration = GatewayConnection.exponentialBackoff
    ) {
        self.configuration = configuration
        self.backoff = backoff
    }

    /// 0.5 s, 1 s, 2 s, … capped at 30 s, with ±20 % jitter.
    public nonisolated static func exponentialBackoff(attempt: Int) -> Duration {
        let base = min(30.0, 0.5 * pow(2.0, Double(max(0, attempt - 1))))
        return .milliseconds(Int(base * Double.random(in: 0.8...1.2) * 1000))
    }

    // MARK: - Connect / disconnect

    /// Connects (or reconnects after `.failed`) with `connector`. An existing
    /// `activeSession` is restored on the new socket; if the server reports it
    /// gone (4001/4007) it is cleared, any other restore error fails the
    /// connect and keeps the session for the next attempt. Call `disconnect()`
    /// first when switching servers.
    public func connect(using connector: any GatewayConnector) async throws {
        // Capture the generation at the bump, before any await: overlapping
        // calls must each own a distinct generation.
        let gen = beginGeneration()
        await discardClient()
        guard gen == generation else { throw CancellationError() }
        self.connector = connector
        state = .connecting
        do {
            let ready = try await establish(gen)
            do {
                try await restoreActiveSession(ready: ready, gen: gen)
            } catch let error as RPCError where Self.sessionGoneCodes.contains(error.code) {
                // The server no longer knows the session (deleted, or reaped and gone):
                // stay connected, drop it from screen. Other codes (4009 "disconnect
                // interrupt settling", 5000, -32000, …) are transient: fail the connect below.
                guard gen == generation else { throw CancellationError() }
                activeSession = nil
            }
            guard gen == generation else { throw CancellationError() }
            committedEpoch = ready.replayEpoch
            state = .connected
        } catch {
            guard gen == generation else { throw CancellationError() }
            await discardClient()
            state = .failed(Self.describe(error))
            self.connector = nil
            throw error
        }
        try? await refreshSessions()
    }

    /// Closes the connection and forgets all session state.
    public func disconnect() async {
        let gen = beginGeneration()
        await discardClient()
        guard gen == generation else { return }  // a newer connect() superseded this call
        connector = nil
        activeSession = nil
        otherSessionRequests = []
        sessions = []
        committedEpoch = nil
        state = .disconnected
    }

    /// Invalidates in-flight work synchronously and returns the new generation.
    private func beginGeneration() -> Int {
        generation += 1
        reconnectTask?.cancel()
        reconnectTask = nil
        return generation
    }

    /// Restore errors meaning the session no longer exists on the server:
    /// 4001 session not found (`server.py:1237`), 4007 no longer live / stored
    /// session not found (`session_lifecycle.py:820`, `methods_session.py:833`).
    static let sessionGoneCodes: Set<Int> = [4001, 4007]

    private func discardClient() async {
        inboundTask?.cancel()
        inboundTask = nil
        let old = client
        client = nil
        await old?.close()
    }

    /// Opens a socket and installs the client. Throws `CancellationError`
    /// (after closing what it opened) if the generation moved on meanwhile.
    private func establish(_ gen: Int) async throws -> GatewayReady {
        guard let connector else { throw GatewayClientError.notConnected }
        let transport = try await connector.makeTransport()
        guard gen == generation else {
            await transport.close()
            throw CancellationError()
        }
        let newClient = GatewayClient(transport: transport, configuration: configuration)
        let stream = await newClient.inbound()
        let ready = try await newClient.connect()
        guard gen == generation else {
            await newClient.close()
            throw CancellationError()
        }
        client = newClient
        inboundTask?.cancel()
        inboundTask = Task { [weak self] in
            for await item in stream {
                self?.handle(item, from: newClient)
            }
        }
        return ready
    }

    // MARK: - Sessions

    public func refreshSessions(limit: Int = 50) async throws {
        guard let client else { throw GatewayClientError.notConnected }
        sessions = try await client.listSessions(limit: limit)
    }

    /// Creates a new live session and makes it active.
    @discardableResult
    public func newSession(title: String? = nil) async throws -> ChatSession {
        guard let client else { throw GatewayClientError.notConnected }
        let created = try await client.createSession(SessionCreateParams(title: title))
        let session = ChatSession(snapshot: created.snapshot, storedSessionID: created.storedSessionID,
                                  title: title, connection: self)
        activate(session)
        return session
    }

    /// Resumes a stored session and makes it active. Returns the current
    /// session unchanged if it already is that stored session.
    @discardableResult
    public func open(_ summary: SessionSummary) async throws -> ChatSession {
        if let current = activeSession, current.storedSessionID == summary.id { return current }
        guard let client else { throw GatewayClientError.notConnected }
        let snapshot = try await client.resumeSession(storedSessionID: summary.id)
        let session = ChatSession(snapshot: snapshot, storedSessionID: summary.id, title: summary.title,
                                  connection: self)
        activate(session)
        await client.redeliver(snapshot.openRequests ?? [])
        return session
    }

    private func activate(_ session: ChatSession) {
        activeSession = session
        // Requests already queued for this session move into its transcript.
        let mine = otherSessionRequests.filter { $0.sessionID == session.sessionID }
        otherSessionRequests.removeAll { $0.sessionID == session.sessionID }
        for request in mine { session.receive(request) }
    }

    // MARK: - Inbound

    private func handle(_ item: GatewayClient.Inbound, from source: GatewayClient) {
        guard source === client else { return }  // stale connection
        switch item {
        case .event(let event):
            if case .sessionTitle(let change) = event.kind,
                let index = sessions.firstIndex(where: { $0.id == change.sessionID })
            {
                sessions[index].title = change.title
            }
            if case .requestCancel(let cancel) = event.kind {
                otherSessionRequests.removeAll { $0.id == cancel.id }
            }
            guard let session = activeSession else { return }
            let sid = event.sessionID ?? ""
            if sid.isEmpty || sid == session.sessionID { session.apply(event) }

        case .serverRequest(let request):
            if let session = activeSession, request.sessionID == session.sessionID {
                session.receive(request)
            } else if !otherSessionRequests.contains(where: { $0.id == request.id }) {
                otherSessionRequests.append(request)
            }

        case .disconnected(let error):
            client = nil
            inboundTask = nil
            if error != nil, connector != nil { startReconnect() }
        }
    }

    // MARK: - Reconnect

    private func startReconnect() {
        guard reconnectTask == nil else { return }
        let gen = generation
        reconnectTask = Task { [weak self] in
            await self?.reconnectLoop(gen)
        }
    }

    private func reconnectLoop(_ gen: Int) async {
        var attempt = 0
        while gen == generation, connector != nil {
            attempt += 1
            state = .reconnecting(attempt: attempt)
            do { try await Task.sleep(for: backoff(attempt)) } catch { return }
            guard gen == generation else { return }
            do {
                let ready = try await establish(gen)
                try await restoreActiveSession(ready: ready, gen: gen)
                guard gen == generation else { return }
                committedEpoch = ready.replayEpoch
                state = .connected
                reconnectTask = nil
                try? await refreshSessions()
                return
            } catch {
                guard gen == generation else { return }
                // Never keep a half-restored socket around (it would linger
                // until deinit, still subscribed to the session).
                await discardClient()
                if case DashboardError.unauthenticated(let reason) = error {
                    state = .failed("Authentication failed\(reason.map { ": \($0)" } ?? "")")
                    break
                }
                if case DashboardError.invalidCredentials = error {
                    state = .failed(Self.describe(error))
                    break
                }
                if let max = maxReconnectAttempts, attempt >= max {
                    state = .failed(Self.describe(error))
                    break
                }
            }
        }
        if gen == generation { reconnectTask = nil }
    }

    private func restoreActiveSession(ready: GatewayReady, gen: Int) async throws {
        guard let session = activeSession, let client else { return }
        if let committedEpoch, committedEpoch == ready.replayEpoch, let lastSeq = session.lastSeq {
            do {
                let result = try await client.reattach(sessionID: session.sessionID, lastSeen: lastSeq)
                guard gen == generation else { throw CancellationError() }
                if result.isComplete {
                    session.update(from: result.snapshot)
                    let open = (result.replay.openRequests + (result.snapshot.openRequests ?? [])).map(\.id)
                    session.retainRequests(ids: Set(open))
                    return
                }
            } catch is RPCError {
                // 4001 not found / 4007 no longer live: the runtime session is gone; resume it.
            }
        }
        let snapshot = try await client.resumeSession(storedSessionID: session.storedSessionID ?? session.sessionID)
        guard gen == generation else { throw CancellationError() }
        session.reset(to: snapshot)
        await client.redeliver(snapshot.openRequests ?? [])
        // A disconnect() during that last hop must not be overwritten by the caller's `.connected`.
        guard gen == generation else { throw CancellationError() }
    }

    // MARK: - Errors

    /// A short user-facing message for errors thrown by this package. Never
    /// includes request URLs (a `?token=` credential could be in them).
    public nonisolated static func describe(_ error: any Error) -> String {
        switch error {
        case let rpc as RPCError: return rpc.message
        case DashboardError.unauthenticated: return "Not signed in, or the session expired."
        case DashboardError.invalidCredentials: return "Username or password was rejected."
        case DashboardError.rateLimited: return "Too many login attempts; wait a minute."
        case DashboardError.http(let status, _): return "The dashboard answered HTTP \(status)."
        case TransportError.handshakeFailed(let detail):
            // The gateway rejects bad tickets/tokens AND host/origin mismatches
            // before accepting, which surfaces as a bare HTTP 403 on the upgrade.
            return "The gateway refused the WebSocket (expired ticket/token or host check): \(detail)"
        case GatewayClientError.readyTimeout: return "The gateway did not respond."
        case let urlError as URLError: return urlError.localizedDescription
        default: return String(describing: error)
        }
    }
}
