import Foundation
import HermesProtocol

/// Typed wrappers for the MVP methods in `docs/protocol.md`.
extension GatewayClient {
    /// Human-facing stored sessions, most recent first.
    public func listSessions(limit: Int? = nil) async throws -> [SessionSummary] {
        try await listSessions(SessionListParams(limit: limit))
    }

    /// `session.list` with any params: a profile's listing, or an exact-title lookup.
    public func listSessions(_ params: SessionListParams) async throws -> [SessionSummary] {
        try await call(GatewayMethod.sessionList, params: params, as: SessionListResult.self).sessions
    }

    /// The profile roster, each row with its Bot Chat / newest / worker session.
    public func listProfiles() async throws -> [ProfileRow] {
        try await call(GatewayMethod.profilesList, params: ProfilesListParams(), as: ProfilesListResult.self).profiles
    }

    /// Sets a live session's title; persists its row if it has none yet.
    @discardableResult
    public func setTitle(sessionID: String, title: String) async throws -> SessionTitleResult {
        try await call(GatewayMethod.sessionTitle, params: SessionTitleParams(sessionID: sessionID, title: title))
    }

    /// Mints a new live session. Its DB row appears with the first prompt.
    public func createSession(_ params: SessionCreateParams = .init()) async throws -> SessionCreateResult {
        try await call(GatewayMethod.sessionCreate, params: params)
    }

    /// Attaches to a stored session (reusing it if already live). The
    /// returned `sessionID` is the runtime id for later calls; pass
    /// `openRequests` to `redeliver(_:)` once the UI is ready to show them.
    /// `profile` names the profile whose state.db holds the row (`nil` = launch profile).
    ///
    /// Never asks for the transcript: the ack stays bounded however long the
    /// history is (`omit_messages` + `defer_history`, as Hermes Desktop resumes).
    /// Read the transcript in pages with `SessionMessagesSource`.
    public func resumeSession(storedSessionID: String, source: String? = nil,
                              profile: String? = nil) async throws -> LiveSessionSnapshot {
        try await call(GatewayMethod.sessionResume,
                       params: SessionResumeParams(sessionID: storedSessionID, source: source, profile: profile,
                                                   omitMessages: true, deferHistory: true))
    }

    public func history(sessionID: String) async throws -> SessionHistoryResult {
        try await call(GatewayMethod.sessionHistory, params: SessionIDParams(sessionID: sessionID))
    }

    /// Tears down the live session; the stored row stays resumable.
    @discardableResult
    public func closeSession(sessionID: String) async throws -> Bool {
        try await call(GatewayMethod.sessionClose, params: SessionIDParams(sessionID: sessionID),
                       as: SessionCloseResult.self).closed
    }

    /// Stops the running turn. Open server requests of the session are cancelled.
    @discardableResult
    public func interrupt(sessionID: String) async throws -> SessionInterruptResult {
        try await call(GatewayMethod.sessionInterrupt, params: SessionIDParams(sessionID: sessionID))
    }

    /// Sends a user turn. Returns immediately (`status == "streaming"` for an
    /// idle session); the reply arrives as events ending in `message.complete`.
    @discardableResult
    public func submitPrompt(sessionID: String, text: String) async throws -> PromptSubmitResult {
        // The ack can lag behind a busy session; Desktop allows the full agent-turn
        // ceiling (`apps/desktop/src/api/client.ts:27`, 1 800 s) so the ack timeout
        // never reports a failure for a turn the server is still running.
        try await call(GatewayMethod.promptSubmit, params: PromptSubmitParams(sessionID: sessionID, text: text),
                       timeout: Self.promptSubmitTimeout)
    }

    /// `PROMPT_SUBMIT_REQUEST_TIMEOUT_MS` in the Desktop app.
    public static let promptSubmitTimeout: Duration = .seconds(1800)

    /// Re-attaches this connection to an already-live session (cancels its
    /// orphan reap). Returns the same snapshot shape as resume.
    public func activateSession(sessionID: String, omitMessages: Bool = false) async throws -> LiveSessionSnapshot {
        try await call(GatewayMethod.sessionActivate,
                       params: SessionActivateParams(sessionID: sessionID, omitMessages: omitMessages))
    }

    // MARK: Answering server requests

    public func answer(_ request: ServerRequest, approval: ApprovalAnswer) throws {
        try respond(to: request.id, result: JSONValue(encoding: approval))
    }

    public func answer(_ request: ServerRequest, clarify: ClarifyAnswer) throws {
        try respond(to: request.id, result: JSONValue(encoding: clarify))
    }

    /// sudo / secret / vault prompts. An empty value means "skipped".
    public func answer(_ request: ServerRequest, value: ValueAnswer) throws {
        try respond(to: request.id, result: JSONValue(encoding: value))
    }

    /// Locks one answer of a batch clarify request; the last lock resolves it.
    /// `answer == nil` marks the question skipped.
    public func lockClarifyAnswer(requestID: String, questionID: String, answer: String?) async throws -> RequestLockResult {
        try await call(GatewayMethod.clarifyLock,
                       params: ClarifyLockParams(requestID: requestID, questionID: questionID, answer: answer))
    }
}
