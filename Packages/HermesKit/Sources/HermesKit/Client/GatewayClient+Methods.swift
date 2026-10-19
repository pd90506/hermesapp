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

    /// The profile's avatar image, or `nil` when it has none.
    public func profileAvatar(profile: String) async throws -> Data? {
        let result = try await call(GatewayMethod.profilesGetAsset, params: ProfileAssetParams(name: profile),
                                    as: ProfileGetAssetResult.self)
        guard result.found, let data = result.data else { return nil }
        return ProfileAvatar.decode(dataURL: data)
    }

    /// Stores `image` (PNG, JPEG or WebP, at most 2 MB) as the profile's avatar.
    public func setProfileAvatar(profile: String, image: Data) async throws {
        _ = try await call(GatewayMethod.profilesSetAsset,
                           params: ProfileAssetParams(name: profile, data: ProfileAvatar.dataURL(image)),
                           as: ProfileSetAssetResult.self)
    }

    /// Removes the profile's avatar image.
    public func clearProfileAvatar(profile: String) async throws {
        _ = try await call(GatewayMethod.profilesSetAsset, params: ProfileAssetParams(name: profile, clear: true),
                           as: ProfileSetAssetResult.self)
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
    /// `queued: true` holds the prompt behind a running turn instead of letting
    /// the gateway's busy mode steer or redirect with it.
    @discardableResult
    public func submitPrompt(sessionID: String, text: String, queued: Bool? = nil) async throws -> PromptSubmitResult {
        // The ack can lag behind a busy session; Desktop allows the full agent-turn
        // ceiling (`apps/desktop/src/api/client.ts:27`, 1 800 s) so the ack timeout
        // never reports a failure for a turn the server is still running.
        try await call(GatewayMethod.promptSubmit,
                       params: PromptSubmitParams(sessionID: sessionID, text: text, queued: queued),
                       timeout: Self.promptSubmitTimeout)
    }

    // MARK: Slash commands

    public func commandsCatalog(sessionID: String?, profile: String? = nil) async throws -> CommandsCatalogResult {
        try await call(GatewayMethod.commandsCatalog, params: SlashScopeParams(sessionID: sessionID, profile: profile))
    }

    public func completeSlash(text: String, sessionID: String?, profile: String? = nil) async throws -> CompleteSlashResult {
        try await call(GatewayMethod.completeSlash,
                       params: SlashScopeParams(sessionID: sessionID, profile: profile, text: text))
    }

    /// `command` is the command line without its leading `/`.
    public func slashExec(sessionID: String, command: String) async throws -> SlashCommandResult {
        try await call(GatewayMethod.slashExec, params: SlashExecParams(sessionID: sessionID, command: command))
    }

    public func commandDispatch(name: String, arg: String?, sessionID: String?) async throws -> SlashCommandResult {
        try await call(GatewayMethod.commandDispatch,
                       params: CommandDispatchParams(name: name, arg: arg, sessionID: sessionID))
    }

    // MARK: Steering

    /// Injects `text` into the running turn's next tool result.
    public func steer(sessionID: String, text: String) async throws -> SessionCorrectionResult {
        try await call(GatewayMethod.sessionSteer, params: SessionTextParams(sessionID: sessionID, text: text))
    }

    /// Stops the active model request and resumes the turn with `text`.
    public func redirect(sessionID: String, text: String) async throws -> SessionCorrectionResult {
        try await call(GatewayMethod.sessionRedirect, params: SessionTextParams(sessionID: sessionID, text: text))
    }

    /// Side question over a snapshot of the conversation; answered by `btw.complete`.
    public func askBTW(sessionID: String, text: String) async throws -> String {
        try await call(GatewayMethod.promptBtw, params: SessionTextParams(sessionID: sessionID, text: text),
                       as: TaskIDResult.self).taskID
    }

    /// Runs `text` on a fresh agent in the background; answered by `background.complete`.
    public func startBackgroundTask(sessionID: String, text: String) async throws -> String {
        try await call(GatewayMethod.promptBackground, params: SessionTextParams(sessionID: sessionID, text: text),
                       as: TaskIDResult.self).taskID
    }

    /// Manual compression of an idle session. LLM-slow: Desktop allows 660 s
    /// (`SESSION_COMPRESS_TIMEOUT_MS`, `use-prompt-actions/slash.ts:89`).
    public func compress(sessionID: String, focusTopic: String? = nil) async throws -> SessionCompressResult {
        try await call(GatewayMethod.sessionCompress,
                       params: SessionCompressParams(sessionID: sessionID, focusTopic: focusTopic),
                       timeout: .seconds(660))
    }

    public func save(sessionID: String) async throws -> SessionSaveResult {
        try await call(GatewayMethod.sessionSave, params: SessionIDParams(sessionID: sessionID))
    }

    public func status(sessionID: String) async throws -> SessionStatusResult {
        try await call(GatewayMethod.sessionStatus, params: SessionIDParams(sessionID: sessionID))
    }

    /// Kills every background process of the gateway (`/stop`); answers how many.
    @discardableResult
    public func stopProcesses() async throws -> ProcessStopResult {
        let value = try await call(GatewayMethod.processStop, params: .object([:]))
        do {
            return try value.decode(ProcessStopResult.self)
        } catch {
            throw GatewayClientError.decoding(method: GatewayMethod.processStop, String(describing: error))
        }
    }

    // MARK: Session management

    /// `sessionID`: a runtime id, or a stored id in `profile`'s db.
    @discardableResult
    public func setArchived(sessionID: String, archived: Bool, profile: String?) async throws -> SessionArchiveResult {
        try await call(GatewayMethod.sessionArchive,
                       params: SessionArchiveParams(sessionID: sessionID, archived: archived, profile: profile))
    }

    /// Deletes a stored session. Fails with 4023 while it is live in the gateway.
    @discardableResult
    public func deleteSession(storedSessionID: String, profile: String?) async throws -> SessionDeleteResult {
        try await call(GatewayMethod.sessionDelete,
                       params: SessionDeleteParams(sessionID: storedSessionID, profile: profile))
    }

    /// Copies a stored session into a new one (Fork). 4008 when the parent has no
    /// visible turns yet ("send a message first").
    public func branchStoredSession(parentID: String, profile: String?) async throws -> SessionBranchResult {
        try await call(GatewayMethod.sessionBranchStored,
                       params: SessionBranchStoredParams(parentSessionID: parentID, profile: profile))
    }

    /// Copies a live session's first `count` visible turns into a new session (Branch).
    /// 4008 when it has no visible turns yet.
    public func branch(sessionID: String, count: Int?, idempotencyKey: String? = nil) async throws -> SessionBranchResult {
        try await call(GatewayMethod.sessionBranch,
                       params: SessionBranchParams(sessionID: sessionID, count: count, idempotencyKey: idempotencyKey))
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
