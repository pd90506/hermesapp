import Foundation
import HermesProtocol
import Observation

/// UI-facing state of one attached gateway session.
///
/// Created by `GatewayConnection` (`newSession` / `open`). All calls go
/// through the connection's *current* client, so the same object survives
/// reconnects.
@MainActor
@Observable
public final class ChatSession: Identifiable {
    /// Runtime id used in calls on the current connection.
    public private(set) var sessionID: String
    /// Durable DB key (stable across reconnects and backend restarts).
    public private(set) var storedSessionID: String?
    public private(set) var title: String?
    public private(set) var info: SessionLiveInfo?
    public private(set) var transcript: Transcript
    /// Highest event `seq` applied — the watermark for `session.events.since`.
    public private(set) var lastSeq: Int?

    @ObservationIgnored weak var connection: GatewayConnection?

    public nonisolated var id: ObjectIdentifier { ObjectIdentifier(self) }

    /// - Parameter storedSessionID: the key the caller already knows (the
    ///   `session.list` row id); resume payloads only carry it as `session_key`.
    init(snapshot: LiveSessionSnapshot, storedSessionID: String? = nil, title: String?, connection: GatewayConnection?) {
        self.sessionID = snapshot.sessionID
        self.storedSessionID = snapshot.storedKey ?? storedSessionID
        self.title = title ?? snapshot.info?.title
        self.info = snapshot.info
        self.transcript = Transcript(snapshot: snapshot)
        self.connection = connection
    }

    /// Replaces local state with a fresh snapshot (after a cold resume).
    func reset(to snapshot: LiveSessionSnapshot) {
        sessionID = snapshot.sessionID
        storedSessionID = snapshot.storedKey ?? storedSessionID
        if let info = snapshot.info {
            self.info = info
            if let title = info.title, !title.isEmpty { self.title = title }
        }
        transcript = Transcript(snapshot: snapshot)
        lastSeq = nil
    }

    /// After a fast-path reattach: pick up the (possibly rotated) stored key.
    func update(from snapshot: LiveSessionSnapshot) {
        if let key = snapshot.storedKey { storedSessionID = key }
        if let info = snapshot.info { self.info = info }
    }

    /// Drops pending requests the server no longer lists as open.
    func retainRequests(ids: Set<String>) {
        for request in transcript.pendingRequests where !ids.contains(request.id) {
            transcript.removeRequest(id: request.id)
        }
    }

    func apply(_ event: GatewayEvent) {
        if let seq = event.seq, event.sessionID == sessionID { lastSeq = max(lastSeq ?? 0, seq) }
        switch event.kind {
        case .sessionTitle(let change):
            if change.sessionID == storedSessionID || change.sessionID == sessionID { title = change.title }
        case .sessionInfo(let newInfo):
            info = newInfo
            if let title = newInfo.title, !title.isEmpty { self.title = title }
            // Compression can rotate the stored key mid-session.
            if let key = newInfo.storedSessionID, !key.isEmpty { storedSessionID = key }
        default:
            transcript.apply(event)
        }
    }

    func receive(_ request: ServerRequest) {
        transcript.addRequest(request)
    }

    // MARK: - Actions

    /// Shows the prompt immediately, then submits it. The reply streams in as events.
    public func send(_ text: String) async throws {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        transcript.appendUserPrompt(trimmed)
        do {
            let client = try currentClient()
            try await client.submitPrompt(sessionID: sessionID, text: trimmed)
        } catch {
            transcript.submitFailed(GatewayConnection.describe(error))
            throw error
        }
    }

    /// Stops the running turn.
    public func interrupt() async throws {
        try await currentClient().interrupt(sessionID: sessionID)
    }

    public func answer(_ request: ServerRequest, approval choice: ApprovalChoice, all: Bool = false) async throws {
        try await currentClient().answer(request, approval: ApprovalAnswer(choice: choice, all: all ? true : nil))
        transcript.removeRequest(id: request.id)
    }

    /// `answers == nil` cancels the clarify request.
    public func answer(_ request: ServerRequest, clarify answers: [String: String?]?) async throws {
        try await currentClient().answer(request, clarify: ClarifyAnswer(answers: answers))
        transcript.removeRequest(id: request.id)
    }

    /// sudo / secret prompts. An empty string means "skip".
    public func answer(_ request: ServerRequest, value: String) async throws {
        try await currentClient().answer(request, value: ValueAnswer(value: value))
        transcript.removeRequest(id: request.id)
    }

    private func currentClient() throws -> GatewayClient {
        guard let client = connection?.client else { throw GatewayClientError.notConnected }
        return client
    }
}
