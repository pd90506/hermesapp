import Foundation
import HermesKit
import HermesProtocol
import Synchronization

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// A stored transcript served like `GET /api/sessions/{id}/messages`
/// (`hermes_cli/web_routers/sessions.py:685-729`): `order=latest` pages back
/// from the newest row and returns the page oldest first, exactly as
/// `rows[::-1][offset:][:limit][::-1]` (`hermes_state_messages.py:1409`).
/// Limits are clamped to 500 (:702) and `pagination` echoes the request.
///
/// `hold()` makes the next reads wait until `release()`, to land them mid-flight.
final class FakeMessageStore: SessionMessagesSource, Sendable {
    enum Mode: Sendable {
        case paged
        /// A gateway older than paging: everything, no `pagination`.
        case noPagination
        /// Every read fails like this.
        case failing(DashboardError)
        /// Every read fails like a dropped network.
        case offline
    }

    private struct State {
        var rows: [StoredMessage]
        var mode: Mode = .paged
        var queries: [SessionMessagesQuery] = []
        var held = false
        var waiters: [(id: UUID, continuation: CheckedContinuation<Void, Never>)] = []
        var cancelled = 0
        var inFlight = 0
        var maxInFlight = 0
        var served = 0
    }

    private let state: Mutex<State>
    /// A held read ends with `CancellationError` when its task is cancelled,
    /// like a `URLSession` request.
    let honoursCancellation: Bool

    init(rows: [StoredMessage], mode: Mode = .paged, honoursCancellation: Bool = false) {
        state = Mutex(State(rows: rows, mode: mode))
        self.honoursCancellation = honoursCancellation
    }

    /// `count` alternating user/assistant rows with ids `1...count`.
    convenience init(count: Int, mode: Mode = .paged, honoursCancellation: Bool = false) {
        self.init(rows: (1...max(count, 1)).prefix(count).map { storedRow(id: $0) }, mode: mode,
                  honoursCancellation: honoursCancellation)
    }

    var queries: [SessionMessagesQuery] { state.withLock { $0.queries } }
    var maxInFlight: Int { state.withLock { $0.maxInFlight } }
    var rows: [StoredMessage] { state.withLock { $0.rows } }

    func setMode(_ mode: Mode) { state.withLock { $0.mode = mode } }

    /// Rows written after a page was read (a turn, another client).
    func append(_ new: [StoredMessage]) { state.withLock { $0.rows += new } }

    /// A row that leaves the display read: Hermes deactivates a queued prompt's
    /// accept-time row when the prompt runs (`session_auto_continue.py:387-390`).
    func remove(id: Int) { state.withLock { $0.rows.removeAll { $0.id == id } } }

    func hold() { state.withLock { $0.held = true } }

    func release() {
        let waiters = state.withLock { state -> [CheckedContinuation<Void, Never>] in
            state.held = false
            defer { state.waiters = [] }
            return state.waiters.map(\.continuation)
        }
        for waiter in waiters { waiter.resume() }
    }

    /// Serves the oldest held read only; later reads stay held.
    func releaseOldest() {
        let waiter = state.withLock { $0.waiters.isEmpty ? nil : $0.waiters.removeFirst() }
        waiter?.continuation.resume()
    }

    /// Held reads that ended because their task was cancelled.
    var cancelled: Int { state.withLock { $0.cancelled } }

    /// Serves the newest held read only; earlier reads stay held.
    func releaseNewest() {
        let waiter = state.withLock { $0.waiters.isEmpty ? nil : $0.waiters.removeLast() }
        waiter?.continuation.resume()
    }

    /// Rewrites a row in place (Hermes merges a second queued prompt into the first
    /// one's accept-time row, `session_auto_continue.py:308-335`).
    func replace(_ row: StoredMessage) {
        state.withLock { state in
            if let index = state.rows.firstIndex(where: { $0.id == row.id }) { state.rows[index] = row }
        }
    }

    /// Reads waiting in `hold()`.
    var heldCount: Int { state.withLock { $0.waiters.count } }

    /// Reads answered so far.
    var served: Int { state.withLock { $0.served } }

    func messagesPage(_ query: SessionMessagesQuery) async throws -> SessionMessagesPage {
        let held = state.withLock { state -> Bool in
            state.queries.append(query)
            state.inFlight += 1
            state.maxInFlight = max(state.maxInFlight, state.inFlight)
            return state.held
        }
        if held {
            let id = UUID()
            await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    let stillHeld = state.withLock { state -> Bool in
                        // Checked under the lock `onCancel` takes: a cancel either sees
                        // this waiter or is seen here.
                        let wait = state.held && !(honoursCancellation && Task.isCancelled)
                        if wait { state.waiters.append((id, continuation)) }
                        return wait
                    }
                    if !stillHeld { continuation.resume() }
                }
            } onCancel: {
                guard honoursCancellation else { return }
                let waiter = state.withLock { state -> CheckedContinuation<Void, Never>? in
                    guard let index = state.waiters.firstIndex(where: { $0.id == id }) else { return nil }
                    return state.waiters.remove(at: index).continuation
                }
                waiter?.resume()
            }
            if honoursCancellation, Task.isCancelled {
                state.withLock {
                    $0.inFlight -= 1
                    $0.cancelled += 1
                }
                throw CancellationError()
            }
        }
        // The rows are read when the request is served, not when it was sent.
        return try state.withLock { state in
            state.inFlight -= 1
            state.served += 1
            switch state.mode {
            case .failing(let error):
                throw error
            case .offline:
                throw URLError(.notConnectedToInternet)
            case .noPagination:
                return SessionMessagesPage(sessionID: query.sessionID, profile: query.profile,
                                           messages: state.rows, pagination: nil)
            case .paged:
                let limit = min(query.limit, 500)
                let page: [StoredMessage]
                switch query.order {
                case .latest: page = Array(state.rows.reversed().dropFirst(query.offset).prefix(limit).reversed())
                case .oldest: page = Array(state.rows.dropFirst(query.offset).prefix(limit))
                }
                return SessionMessagesPage(
                    sessionID: query.sessionID, profile: query.profile, messages: page,
                    pagination: SessionMessagesPagination(limit: limit, offset: query.offset,
                                                          order: query.order.rawValue, returned: page.count))
            }
        }
    }
}

/// Decodes a JSON fixture.
func decodeJSON<T: Decodable>(_ text: String, as type: T.Type = T.self) throws -> T {
    try JSONDecoder().decode(T.self, from: Data(text.utf8))
}

/// A plain stored row: odd ids are user prompts, even ids assistant replies.
func storedRow(id: Int, role: String? = nil, text: String? = nil) -> StoredMessage {
    let role = role ?? (id % 2 == 1 ? "user" : "assistant")
    var row = StoredMessage(id: id, role: role, content: .string(text ?? "\(role) \(id)"))
    row.timestamp = 1_700_000_000 + Double(id)
    return row
}
