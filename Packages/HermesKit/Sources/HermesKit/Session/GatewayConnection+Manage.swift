import Foundation
import HermesProtocol

/// Why a rename/archive/delete was refused before anything was sent.
public enum SessionActionError: Error, Sendable, Equatable {
    /// The session is a bot's Bot Chat, which stays put.
    case botChatProtected
    /// "Bot Chat" is the registry title (`Bot.chatTitle`); giving it to another
    /// session would make that session the bot's chat.
    case reservedTitle
    case emptyTitle
    /// `session.title` only renames a live session; open the chat first.
    case notOpen
}

/// Side-chat management: rename, archive, unarchive, delete, fork (`docs/protocol.md` §10.9).
///
/// Everything goes through the gateway's JSON-RPC, never the dashboard REST API
/// Desktop uses for rows it does not have open (`apps/desktop/src/api/sessions.ts:374-389,708-743`):
/// - rename: `session.title` on the live runtime id (`methods_session.py:1220-1249`);
/// - archive / unarchive: `session.archive` (`methods_session.py:1252-1279`),
///   the RPC twin of Desktop's `PATCH {archived}`;
/// - delete: like Desktop (`use-session-actions/index.ts:3240-3403`), a session
///   this connection has live is interrupted and closed first, then
///   `session.delete` removes the stored row (`methods_session.py:1175-1198`).
///
/// **Bot Chats are protected.** The gateway only refuses renaming a hidden
/// "Bot Chat" (`hermes_state_titles.py:100-109`); archive and delete would go
/// through and retire the bot's chat. The package refuses all three, plus
/// giving any session the reserved title, with `SessionActionError`.
extension GatewayConnection {
    // MARK: Protection

    /// Is this chat a bot's Bot Chat (so it can't be renamed, archived or deleted)?
    public func isProtected(_ session: ChatSession) -> Bool {
        if session.kind == .botChat { return true }
        if session.title?.trimmed == Bot.chatTitle { return true }
        guard let key = session.storedSessionID else { return false }
        return bots(of: session.profile).contains { $0.chatStoredIDs.contains(key) }
    }

    /// Is this History row a bot's Bot Chat? History normally leaves them out.
    public func isProtected(_ entry: HistoryEntry) -> Bool {
        if Bot.isChatRow(entry.summary) { return true }
        let ids = [entry.summary.id, entry.summary.resolvedID].compactMap { $0 }
        return bots(of: entry.profile).contains { bot in ids.contains(where: bot.chatStoredIDs.contains) }
    }

    /// The bots a session of `profile` may belong to: that bot, or every bot
    /// for a session of the gateway's launch profile (whose name we don't know).
    private func bots(of profile: String?) -> [Bot] {
        guard let profile else { return bots }
        return bots.filter { $0.name == profile }
    }

    // MARK: Rename

    /// Renames a chat this app has open (`session.title`).
    public func rename(_ session: ChatSession, to newTitle: String) async throws {
        let title = newTitle.trimmed
        guard !title.isEmpty else { throw SessionActionError.emptyTitle }
        guard !isProtected(session) else { throw SessionActionError.botChatProtected }
        guard title.caseInsensitiveCompare(Bot.chatTitle) != .orderedSame else { throw SessionActionError.reservedTitle }
        let client = try await session.liveClient()  // `session.title` needs a live runtime
        let result = try await client.setTitle(sessionID: session.sessionID, title: title)
        session.setTitle(result.title)
        if let key = session.storedSessionID { renameLocalRows(storedID: key, profile: session.profile, to: result.title) }
    }

    /// Renames a History row. Only a chat open here (on screen or warm) can be renamed:
    /// `session.title` needs a live session, and attaching to a row just to
    /// rename it would take its events away from another client showing it.
    public func rename(_ entry: HistoryEntry, to newTitle: String) async throws {
        guard !isProtected(entry) else { throw SessionActionError.botChatProtected }
        guard let session = openSession(for: entry) else { throw SessionActionError.notOpen }
        try await rename(session, to: newTitle)
    }

    // MARK: Archive

    /// Archives a chat: it leaves every list but keeps its messages. The chat
    /// stays on screen if it is open.
    public func archive(_ session: ChatSession) async throws {
        guard !isProtected(session) else { throw SessionActionError.botChatProtected }
        guard let client else { throw GatewayClientError.notConnected }
        // The runtime id also covers a chat that has no stored row yet (`pending_archived`);
        // a reclaimed runtime is gone, so its stored row is archived instead.
        let target = session.isRuntimeGone ? (session.storedSessionID ?? session.sessionID) : session.sessionID
        try await client.setArchived(sessionID: target, archived: true, profile: session.profile)
        if let key = session.storedSessionID { dropLocalRows(storedID: key, profile: session.profile) }
        refreshListsInBackground(includingSessions: true)
    }

    public func archive(_ entry: HistoryEntry) async throws {
        guard !isProtected(entry) else { throw SessionActionError.botChatProtected }
        if let session = openSession(for: entry) { return try await archive(session) }
        guard let client else { throw GatewayClientError.notConnected }
        try await client.setArchived(sessionID: entry.summary.id, archived: true, profile: entry.profile)
        dropLocalRows(storedID: entry.summary.id, profile: entry.profile)
        refreshListsInBackground(includingSessions: true)
    }

    /// Undoes `archive` (e.g. from an "Undo" toast). Archived rows are not
    /// listed (`session.list` has no archived filter), so keep the entry.
    public func unarchive(_ entry: HistoryEntry) async throws {
        guard !isProtected(entry) else { throw SessionActionError.botChatProtected }
        guard let client else { throw GatewayClientError.notConnected }
        try await client.setArchived(sessionID: entry.summary.id, archived: false, profile: entry.profile)
        refreshListsInBackground(includingSessions: true)
    }

    // MARK: Fork

    /// Copies a History row into a new session (`session.branch_stored`) and opens
    /// the copy. The gateway names it after the parent's lineage ("Title #2").
    @discardableResult
    public func fork(_ entry: HistoryEntry) async throws -> ChatSession {
        guard !isProtected(entry) else { throw SessionActionError.botChatProtected }
        guard let client else { throw GatewayClientError.notConnected }
        let branched = try await client.branchStoredSession(parentID: entry.summary.id, profile: entry.profile)
        // The row exists now: list it, so the copy opens with its title and selected.
        if listProfile == entry.profile { await refreshSessionList() }
        let row = history.first { $0.profile == entry.profile && $0.summary.id == branched.storedSessionID }
            ?? HistoryEntry(profile: entry.profile, summary: SessionSummary(id: branched.storedSessionID))
        // `session.resume` reuses the runtime the branch started on this socket.
        return try await open(row)
    }

    // MARK: Delete

    /// Deletes a chat and its messages for good. If it is on screen it is closed;
    /// it leaves the warm chats, with its composer.
    public func delete(_ session: ChatSession) async throws {
        guard !isProtected(session) else { throw SessionActionError.botChatProtected }
        guard let client else { throw GatewayClientError.notConnected }
        try await deleteStored(storedID: session.storedSessionID, profile: session.profile,
                               runtimeID: session.isRuntimeGone ? nil : session.sessionID,
                               running: session.transcript.isRunning, client: client)
        forget(session)
    }

    public func delete(_ entry: HistoryEntry) async throws {
        guard !isProtected(entry) else { throw SessionActionError.botChatProtected }
        if let session = openSession(for: entry) { return try await delete(session) }
        guard let client else { throw GatewayClientError.notConnected }
        let runtimeID = liveRuntimeIDs[Self.liveKey(profile: entry.profile, stored: entry.summary.id)]
        try await deleteStored(storedID: entry.summary.id, profile: entry.profile, runtimeID: runtimeID,
                               running: true, client: client)
    }

    /// Interrupt + close the runtime this connection has live (a live session
    /// refuses deletion with 4023), then delete the row. 4007 "session not
    /// found" counts as done: the row never existed (no first turn) or is gone.
    private func deleteStored(storedID: String?, profile: String?, runtimeID: String?, running: Bool,
                              client: GatewayClient) async throws {
        if let runtimeID {
            if running { _ = try? await client.interrupt(sessionID: runtimeID) }
            _ = try? await client.closeSession(sessionID: runtimeID)
            liveRuntimeIDs = liveRuntimeIDs.filter { $0.value != runtimeID }
            sessionProfiles[runtimeID] = nil
        }
        if let storedID, !storedID.isEmpty {
            do {
                try await client.deleteSession(storedSessionID: storedID, profile: profile)
            } catch let error as RPCError where error.code == 4007 {
                // Already absent.
            }
            dropLocalRows(storedID: storedID, profile: profile)
        }
        refreshListsInBackground(includingSessions: true)
    }

    // MARK: Helpers

    /// The chat showing this History row, if any: the one on screen, or a warm one.
    private func openSession(for entry: HistoryEntry) -> ChatSession? {
        func shows(_ session: ChatSession) -> Bool {
            session.profile == entry.profile
                && (session.storedSessionID == entry.summary.id || session.storedSessionID == entry.summary.resolvedID)
        }
        if let active = activeSession, shows(active) { return active }
        return warmChats.first(where: shows)
    }

    private func renameLocalRows(storedID: String, profile: String?, to title: String) {
        if profile == nil, let index = sessions.firstIndex(where: { $0.id == storedID }) { sessions[index].title = title }
        for index in history.indices where history[index].profile == profile && history[index].summary.id == storedID {
            history[index].summary.title = title
        }
    }

    private func dropLocalRows(storedID: String, profile: String?) {
        if profile == nil { sessions.removeAll { $0.id == storedID } }
        history.removeAll { $0.profile == profile && ($0.summary.id == storedID || $0.summary.resolvedID == storedID) }
    }
}
