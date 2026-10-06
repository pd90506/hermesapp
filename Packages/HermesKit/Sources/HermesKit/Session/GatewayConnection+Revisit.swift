import Foundation
import HermesProtocol

/// A chat that is being opened and is not on screen yet.
public struct PendingChat: Sendable, Equatable {
    /// The bot it belongs to (`nil`: the launch profile).
    public var profile: String?
    public var kind: ChatKind
    /// The stored title, when the open knows one (a History row).
    public var title: String?

    public init(profile: String?, kind: ChatKind, title: String?) {
        self.profile = profile
        self.kind = kind
        self.title = title
    }
}

/// Going back to a chat shown earlier in this connection (docs/protocol.md §4.2).
///
/// Like Desktop's warm cache (`apps/desktop/src/app/session/hooks/use-session-actions/index.ts:1378-1760`):
/// - The last `warmChatLimit` chats keep their `ChatSession`, and while this socket
///   still serves their runtime session they keep receiving its events
///   (`eventTargets`), so their transcripts stay current.
/// - Going back to one shows it at once, then reconciles in the background:
///   `session.activate {omit_messages:true}` binds the runtime session to this
///   socket again (another client may have taken it, or a reconnect dropped the
///   binding), and a re-read of the newest rows (`Transcript.installRereadPage`)
///   brings in whatever was stored meanwhile. Stored rows stay the source of truth;
///   nothing is matched by text.
/// - A runtime session that is gone (4001/4007), or a recycled runtime id now
///   answering for another stored session, falls back to a resume of the stored key
///   into the same `ChatSession`, as a reconnect does (§7). A Bot Chat is looked up
///   by its name again first (§8.2) and reopened when its tip changed.
/// - Any other failure keeps the cached transcript (Desktop's "degraded warm cache").
extension GatewayConnection {
    /// Chats kept warm, the active one included. Each holds at most the pages the
    /// user loaded; at 120 rows a page this bounds the cache to a few hundred rows
    /// per chat for a typical session.
    static let warmChatLimit = 6

    func warmChat(where match: (ChatSession) -> Bool) -> ChatSession? {
        warmChats.first(where: match)
    }

    /// The chats an event for runtime session `sid` updates: the active one, and a
    /// warm one with that runtime id. A global event (no `sid`) goes to the active chat.
    func eventTargets(_ sid: String) -> [ChatSession] {
        guard !sid.isEmpty else { return activeSession.map { [$0] } ?? [] }
        var targets = warmChats.filter { $0.sessionID == sid }
        if let active = activeSession, active.sessionID == sid, !targets.contains(where: { $0 === active }) {
            targets.append(active)
        }
        return targets
    }

    /// Shows `session` now and reconciles it in the background.
    ///
    /// One reconcile per chat at a time: going back to a chat whose reconcile still
    /// runs on this socket joins it; one started on an older socket is cancelled and
    /// replaced. Until it ends, the chat's sends wait (`ChatSession.settleIdentity`),
    /// so none goes to a runtime session the chat is about to leave.
    func revisit(_ session: ChatSession, token: Int, client: GatewayClient) -> ChatSession {
        activate(session)
        if session.isReconciling, session.reconcileClient === client { return session }
        session.revisitTask?.cancel()
        session.revisitToken += 1
        let mine = session.revisitToken
        session.isReconciling = true
        session.reconcileClient = client
        let gen = generation
        session.revisitTask = Task {
            await self.reconcile(session, client: client, gen: gen)
            if session.revisitToken == mine {
                session.isReconciling = false
                session.reconcileClient = nil
            }
        }
        return session
    }

    /// Results are applied only while `client` is still this connection's socket and
    /// no connect/disconnect happened: a late answer from a replaced socket is dropped
    /// (a reconnect keeps `generation`, so both are checked, as `show` does).
    private func isCurrent(_ client: GatewayClient, _ gen: Int) -> Bool {
        gen == generation && client === self.client && !Task.isCancelled
    }

    private func reconcile(_ session: ChatSession, client: GatewayClient, gen: Int) async {
        do {
            if session.kind == .botChat, let profile = session.profile {
                let target = try await botChatRestoreTarget(profile: profile, client: client)
                guard isCurrent(client, gen) else { return }
                if target != session.storedSessionID {
                    // Desktop retired or replaced the chat meanwhile: open the current one.
                    try await reopen(session, target: target, client: client, gen: gen)
                    return
                }
            }
            let snapshot = try await client.activateSession(sessionID: session.sessionID, omitMessages: true)
            guard isCurrent(client, gen) else { return }
            if let key = snapshot.storedKey, let stored = session.storedSessionID, key != stored {
                // The runtime id answers for another stored session (a backend that
                // restarted and re-minted ids), or compression rotated the key: resume
                // the key this chat was showing, which follows its lineage.
                try await reopen(session, target: stored, client: client, gen: gen)
                return
            }
            if let profile = session.profile { sessionProfiles[session.sessionID] = profile }
            session.update(from: snapshot)
            session.retainRequests(ids: Set((snapshot.openRequests ?? []).map(\.id)))
            session.reconcileAfterRevisit(running: snapshot.running == true)
            await client.redeliver(snapshot.openRequests ?? [])
        } catch where Self.isSessionGone(error) {
            guard isCurrent(client, gen) else { return }
            if error is RestoreError {
                drop(session)  // the bot has no Bot Chat any more
                return
            }
            let target = session.storedSessionID ?? session.sessionID
            do {
                try await reopen(session, target: target, client: client, gen: gen)
            } catch {
                if isCurrent(client, gen), Self.isSessionGone(error) { drop(session) }
            }
        } catch {
            // Offline or a transient error: the cached transcript stays as it is.
        }
    }

    /// Resumes `target` into `session`, as a reconnect's cold restore does (§7).
    private func reopen(_ session: ChatSession, target: String, client: GatewayClient, gen: Int) async throws {
        let resumed = try await resume(target, profile: session.profile, client: client)
        guard isCurrent(client, gen) else {
            resumed.prefetch?.cancel()
            return
        }
        session.reset(to: resumed.snapshot, storedSessionID: target)
        session.loadHistory(prefetch: resumed.prefetch)
        if let profile = session.profile { sessionProfiles[session.sessionID] = profile }
        await client.redeliver(resumed.snapshot.openRequests ?? [])
    }

    /// Forgets a chat that can no longer be shown.
    private func drop(_ session: ChatSession) {
        warmChats.removeAll { $0 === session }
        forgetComposer(of: session)
        if activeSession === session { clearActiveSession() }
    }
}
