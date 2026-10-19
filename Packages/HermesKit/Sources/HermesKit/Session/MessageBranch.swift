import Foundation
import HermesProtocol

/// Branch from a message: a new chat holding the conversation up to that message, as
/// Desktop's "Branch in new chat" on a reply (`branchLoadedSession`,
/// `apps/desktop/src/app/session/hooks/use-session-actions/index.ts:2928-3002`).
///
/// `session.branch` copies the parent's first `count` *visible* turns: its user and
/// assistant rows with text (`_visible_branch_history`, `tui_gateway/methods_session_branch.py:21-25`,
/// `history[:count]` at :108-109). Desktop counts them in the stored transcript, read
/// whole, up to the clicked message's row (`selectBranchMessages`,
/// `use-session-actions/utils.ts:1791-1848`); so does `count(through:shown:stored:)`.
public enum MessageBranch {
    /// Whether `session.branch` copies this stored row.
    static func isCopied(_ row: StoredMessage) -> Bool {
        guard row.role == "user" || row.role == "assistant" else { return false }
        let text = StoredMessageProjection.text(of: row.content) ?? ""
        return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The `count` that ends a branch at `item`: the copied rows up to and including its
    /// row in `stored` (the whole stored transcript, oldest first). `nil` when its row
    /// isn't there.
    ///
    /// The row is found by its id, else, for an item shown before its row was read back
    /// (a reply just finished), as Desktop does: the same role and text, counted from the
    /// end, among the rows as the transcript shows them. `shown` is the transcript's items.
    static func count(through item: TranscriptItem, shown: [TranscriptItem], stored rows: [StoredMessage]) -> Int? {
        guard let index = rowIndex(of: item, shown: shown, stored: rows) else { return nil }
        let count = rows[...index].count(where: isCopied)
        return isCopied(rows[index]) ? count : nil
    }

    private static func rowIndex(of item: TranscriptItem, shown: [TranscriptItem], stored rows: [StoredMessage]) -> Int? {
        if let rowID = item.rowID {
            return rows.firstIndex { $0.id == rowID }
        }
        guard let position = shown.firstIndex(where: { $0.id == item.id }) else { return nil }
        let matches = { (other: TranscriptItem) in other.role == item.role && other.text == item.text }
        // The how-many-th from the end such a message is on screen, and the row that is as
        // far from the end among the stored rows, projected as the transcript shows them.
        let fromEnd = shown[position...].count(where: matches)
        var toolCalls: StoredMessageProjection.ToolCalls = [:]
        let projected = StoredMessageProjection.items(from: rows, toolCalls: &toolCalls, startsSession: true)
        let candidates = projected.filter(matches)
        guard fromEnd <= candidates.count, let rowID = candidates[candidates.count - fromEnd].rowID else { return nil }
        return rows.firstIndex { $0.id == rowID }
    }
}

public enum MessageBranchError: Error, Sendable, Equatable {
    /// A turn is running: branch once it has finished (Desktop: `branchStopCurrent`).
    case busy
    /// The message isn't in the stored transcript (yet).
    case messageNotFound
}
