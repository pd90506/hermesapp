import Foundation
import HermesProtocol

/// A gateway notice (`notification.show`) as the app lists it.
public struct GatewayNotification: Sendable, Hashable, Identifiable {
    /// The notice's `key` (a newer notice with the same key replaces it), else its `id`.
    public var id: String
    public var notice: GatewayNotice
    /// Runtime session the notice was routed through, if any.
    public var sessionID: String?
    /// The bot (profile) of that session, when this app opened it.
    public var profile: String?
}

/// Server pushes that keep the sidebar live (`docs/protocol.md` §11):
/// - `sessions.changed` (broadcast whenever a served state.db moved) refreshes
///   the session list, the bot roster and History, throttled;
/// - `session.title` / `session.info` rename rows in place;
/// - `session.reclaimed` marks the chats on that runtime (active or warm) as gone;
///   they resume on their next action;
/// - `notification.show` / `notification.clear` maintain `notifications`.
extension GatewayConnection {
    func handleConnectionEvent(_ event: GatewayEvent) {
        let profile = sessionProfiles[event.sessionID ?? ""]
        switch event.kind {
        case .sessionTitle(let change):
            // `session_id` in the payload is the stored key (`prompt_turn.py:795-797`).
            renameRows(storedID: change.sessionID, profile: profile, to: change.title)
        case .sessionInfo(let info):
            if let key = info.storedSessionID, !key.isEmpty, let title = info.title, !title.isEmpty {
                renameRows(storedID: key, profile: profile, to: title)
            }
        case .requestCancel(let cancel):
            otherSessionRequests.removeAll { $0.id == cancel.id }
        case .sessionsChanged:
            schedulePushedRefresh()
        case .sessionReclaimed(let reclaimed):
            sessionReclaimed(reclaimed)
        case .notificationShow(let notice):
            show(notice, sessionID: event.sessionID, profile: profile)
        case .notificationClear(let clear):
            notifications.removeAll { $0.id == clear.key }
        default:
            break
        }
    }

    /// Stored ids are per profile db; the event's runtime sid says which profile.
    private func renameRows(storedID: String, profile: String?, to title: String) {
        if profile == nil, let index = sessions.firstIndex(where: { $0.id == storedID }) {
            sessions[index].title = title
        }
        for index in history.indices where history[index].summary.id == storedID
            && (profile == nil || history[index].profile == profile)
        {
            history[index].summary.title = title
        }
    }

    // MARK: Throttled list refresh

    /// Refreshes the lists now, or once `pushedRefreshInterval` has passed since
    /// the last pushed refresh. Bursts collapse into one trailing refresh.
    /// `immediately` (a finished turn): now, replacing a pending trailing refresh;
    /// the window restarts, so the turn's late `sessions.changed` still collapse.
    func schedulePushedRefresh(immediately: Bool = false) {
        guard client != nil else { return }
        if immediately {
            pushedRefreshTask?.cancel()
            pushedRefreshTask = nil
            runPushedRefresh()
            return
        }
        guard pushedRefreshTask == nil else { return }
        let wait = lastPushedRefresh.map { pushedRefreshInterval - (ContinuousClock.now - $0) } ?? .zero
        guard wait > .zero else {
            runPushedRefresh()
            return
        }
        let gen = generation
        pushedRefreshTask = Task { [weak self] in
            do { try await Task.sleep(for: wait) } catch { return }
            guard let self, gen == self.generation else { return }
            self.pushedRefreshTask = nil
            self.runPushedRefresh()
        }
    }

    private func runPushedRefresh() {
        lastPushedRefresh = .now
        refreshListsInBackground(includingSessions: true)
    }

    // MARK: Reclaimed sessions

    /// Like Desktop (`gateway-event/lifecycle.ts:123-165`): forget the dead
    /// runtime and its requests, keep the chat, and resume it from its stored
    /// key on its next action (`ChatSession.liveClient`), or when it is shown
    /// again (`revisit`). Resuming right away would undo an idle reclaim every
    /// TTL. Only a Bot Chat on screen is re-resolved at once, by name, as
    /// Desktop's bots plugin does (`plugins/hermes-bots/plugin.tsx:653-701`);
    /// `[client choice]` not after an `lru_evict`, where resuming would evict
    /// another session in turn.
    private func sessionReclaimed(_ reclaimed: SessionReclaimed) {
        let runtime = reclaimed.sessionID
        liveRuntimeIDs = liveRuntimeIDs.filter { $0.value != runtime }
        otherSessionRequests.removeAll { $0.sessionID == runtime }
        schedulePushedRefresh()
        for session in warmChats + [activeSession].compactMap({ $0 }) where session.sessionID == runtime
            && !session.isRuntimeGone
        {
            session.markRuntimeGone()
        }
        guard let session = activeSession, session.sessionID == runtime, session.kind == .botChat,
            reclaimed.reason != "lru_evict"
        else { return }
        Task { [weak self] in try? await self?.revive(session) }
    }

    /// Resumes a chat whose runtime was reclaimed, like a reconnect's cold restore
    /// (a Bot Chat by its name). One revival at a time per chat, and none while a
    /// reconnect restores it or a revisit reconciles it (`ChatSession.settleIdentity`),
    /// so two resumes never leave two live runtimes. A chat the gateway no longer
    /// has is forgotten, as `revisit` does.
    func revive(_ session: ChatSession) async throws {
        try await session.settleIdentity()
        guard session.isRuntimeGone else { return }
        if let running = session.revival { return try await running.value }
        guard let client else { throw GatewayClientError.notConnected }
        let gen = generation
        let task = Task { try await self.coldRestore(session, client: client, gen: gen) }
        session.revival = task
        session.identityGate = Task { _ = try? await task.value }
        defer { if session.revival == task { session.revival = nil } }
        do {
            try await task.value
        } catch where Self.isSessionGone(error) {
            if gen == generation { forget(session) }
            throw error
        }
    }

    // MARK: Notifications

    private func show(_ notice: GatewayNotice, sessionID: String?, profile: String?) {
        let id = notice.key ?? notice.id ?? UUID().uuidString
        let entry = GatewayNotification(id: id, notice: notice, sessionID: (sessionID ?? "").isEmpty ? nil : sessionID,
                                        profile: profile)
        if let index = notifications.firstIndex(where: { $0.id == id }) {
            notifications[index] = entry
        } else {
            notifications.append(entry)
        }
        // `ttl_ms` counts only for `kind: "ttl"` (`agent/credits_tracker.py:111-112`,
        // `apps/desktop/src/store/agent-notices.ts:118-134`); anything else stays until cleared.
        guard notice.kind == "ttl", let ttl = notice.ttlMS, ttl > 0 else { return }
        let gen = generation
        Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(ttl)) } catch { return }
            guard let self, gen == self.generation else { return }
            // Only this notice: a replacement with the same key restarts its own timer.
            self.notifications.removeAll { $0 == entry }
        }
    }

    public func dismissNotification(_ notification: GatewayNotification) {
        notifications.removeAll { $0.id == notification.id }
    }

    // MARK: Live runtime ids

    static func liveKey(profile: String?, stored: String) -> String { "\(profile ?? "")/\(stored)" }

    /// Remembers which runtime id serves a stored session on this connection.
    func track(_ session: ChatSession) {
        guard let stored = session.storedSessionID, !stored.isEmpty else { return }
        liveRuntimeIDs[Self.liveKey(profile: session.profile, stored: stored)] = session.sessionID
    }
}
