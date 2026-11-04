import Foundation

/// Keeps `readMarks` in step with Hermes's shared watermark (`SessionReadSource`), so a
/// reply read on one device stops showing as unread on the others.
///
/// Rows are still unread by their newest reply against the marks, not by the server's
/// `unread`: any activity passes the watermark, the user's own prompt included
/// (`hermes_state_sessions.py:1069-1074`), and a row never marked is read there.
/// - Pulled before each list's row reads, a watermark counts as seen here.
/// - Pushed when a listed row's newest reply was seen here but is past the watermark:
///   when a chat comes on screen or leaves it, and after each list's row reads, which
///   covers an earlier failure and what was seen before marks were shared.
extension GatewayConnection {
    /// A reply this connection already tried to mark read on the server.
    struct ReadPush: Hashable {
        var generation: Int
        var reply: Date
    }

    func pullReadMarks(profile: String) async {
        guard let source = readSource, let watermarks = try? await source.readWatermarks(profile: profile) else { return }
        for (id, read) in watermarks {
            serverReadMarks[SessionReadMarks.key(profile: profile, id: id)] = read
        }
        updateReadMarks { marks in
            var changed = false
            for (id, read) in watermarks where read > 0 {
                if marks.markSeen(profile: profile, id: id, through: Date(timeIntervalSince1970: read)) { changed = true }
            }
            return changed
        }
    }

    /// One at a time, in the order of `entries`: on first use that can be every chat
    /// seen here.
    func pushReadMarks(_ entries: [HistoryEntry]) {
        guard let source = readSource, readPushTask == nil else { return }
        let gen = generation
        let pending = entries.compactMap { entry -> (HistoryEntry, ReadPush)? in
            guard let push = readPush(for: entry) else { return nil }
            return (entry, push)
        }
        guard !pending.isEmpty else { return }
        readPushTask = Task {
            for (entry, push) in pending {
                let key = SessionReadMarks.key(profile: entry.profile, id: entry.summary.id)
                readPushes[key] = push
                if (try? await source.markRead(sessionID: entry.summary.id, profile: entry.profile)) != nil {
                    serverReadMarks[key] = push.reply.timeIntervalSince1970
                }
            }
            readPushTask = nil
            // What was seen meanwhile. Each try is recorded, so this ends.
            if gen == generation { pushReadMarks(entries) }
        }
    }

    /// The push `entry` needs: its newest reply is seen here, past a watermark known to
    /// the server, and not tried yet on this connection.
    private func readPush(for entry: HistoryEntry) -> ReadPush? {
        let key = SessionReadMarks.key(profile: entry.profile, id: entry.summary.id)
        guard let reply = activity(for: entry)?.newestReply, let server = serverReadMarks[key],
              server < reply.timeIntervalSince1970 else { return nil }
        // Only what was seen of this chat: `since` says nothing about it.
        guard isOnScreen(entry) || readMarks.seenThrough(profile: entry.profile, id: entry.summary.id) ?? .distantPast >= reply
        else { return nil }
        let push = ReadPush(generation: generation, reply: reply)
        return readPushes[key] == push ? nil : push
    }
}
