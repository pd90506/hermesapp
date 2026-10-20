import Foundation

/// How many messages are below the screen, for the chat's scroll-to-bottom button, as
/// Desktop's counts them (`use-messages-below.ts`): a prompt, a reply, a system line.
/// A turn's work and its answer are one reply, as one assistant message in Desktop.
public enum MessagesBelow {
    /// The messages in `blocks` after the last block of `visible` (the blocks on
    /// screen). Zero when no block is on screen: the fold is unknown.
    public static func count(in blocks: [TranscriptBlock], visible: Set<String>) -> Int {
        guard let last = blocks.lastIndex(where: { visible.contains($0.id) }) else { return 0 }
        let below = blocks[(last + 1)...]
        var count = 0
        for (index, block) in zip(below.indices, below) {
            switch block {
            case .item(let item):
                if item.role != .tool, !item.isBlankReply { count += 1 }
            case .work:
                // The work before an answer is that answer's; work with no answer after
                // it (still running, or cut short) is a reply of its own.
                let next = index + 1 < blocks.endIndex ? blocks[index + 1] : nil
                if case .item(let item)? = next, item.role == .assistant, !item.isBlankReply { continue }
                count += 1
            }
        }
        return count
    }

    /// The button's text: "3 messages" with messages below, else "Scroll to bottom".
    public static func title(count: Int) -> String {
        count > 0 ? "\(count) \(count == 1 ? "message" : "messages")" : scrollToBottom
    }

    /// The button's accessibility label: "Scroll to bottom · 3 messages", as Desktop's.
    public static func accessibilityLabel(count: Int) -> String {
        count > 0 ? "\(scrollToBottom) · \(title(count: count))" : scrollToBottom
    }

    public static let scrollToBottom = "Scroll to bottom"
}

extension Transcript {
    /// The messages below the blocks `visibleBlockIDs` on screen (`MessagesBelow`).
    public func messagesBelow(visibleBlockIDs: Set<String>) -> Int {
        MessagesBelow.count(in: blocks, visible: visibleBlockIDs)
    }
}
