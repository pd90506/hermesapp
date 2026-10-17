import Foundation

/// A prompt the user sent, as the chat's prompt rail marks it: a tick at the chat's
/// edge whose label is the prompt, and which scrolls the chat to it.
public struct PromptMark: Sendable, Hashable, Identifiable {
    /// The user row's id (`TranscriptItem.id`).
    public var id: String
    /// The prompt's first line, cut to `labelLimit` characters.
    public var label: String

    public init(id: String, label: String) {
        self.id = id
        self.label = label
    }

    /// The longest label, ellipsis included.
    public static let labelLimit = 60

    /// The user rows of `items`, oldest first. Background work Hermes reported as a
    /// user turn (`backgroundNotice`) is not a prompt and gets no mark.
    public static func marks(in items: [TranscriptItem]) -> [PromptMark] {
        items.compactMap { item in
            guard item.role == .user, item.backgroundNotice == nil else { return nil }
            return PromptMark(id: item.id, label: label(for: item))
        }
    }

    /// The first line of the prompt with text, its spaces collapsed, cut to `limit`.
    /// A prompt with only files or images is labelled with what it carried.
    public static func label(for item: TranscriptItem, limit: Int = labelLimit) -> String {
        let line = item.text.split(whereSeparator: \.isNewline)
            .lazy
            .map { $0.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
            .first { !$0.isEmpty }
        guard let line else {
            if !item.attachments.isEmpty { return cut(item.attachments.joined(separator: ", "), to: limit) }
            return item.images.count > 1 ? "\(item.images.count) images" : "Image"
        }
        return cut(line, to: limit)
    }

    private static func cut(_ text: String, to limit: Int) -> String {
        guard text.count > limit else { return text }
        let kept = text.prefix(max(limit - 1, 0)).trimmingCharacters(in: .whitespaces)
        return kept + "…"
    }
}

extension Transcript {
    /// The prompts of this transcript, oldest first (`PromptMark.marks`).
    public var promptMarks: [PromptMark] { PromptMark.marks(in: items) }

    /// The prompt the chat is at with the blocks `visibleBlockIDs` on screen
    /// (`PromptMark.current`). Nil when the transcript has no prompts or no block is
    /// on screen.
    public func currentPromptID(visibleBlockIDs: Set<String>) -> String? {
        PromptMark.current(in: blocks, marks: promptMarks, visible: visibleBlockIDs)
    }
}

extension PromptMark {
    /// The prompt the chat is at with the blocks `visible` on screen: the last prompt in
    /// or above the first block on screen, or the first prompt when that block is above
    /// them all. A chat scrolled to its end (its last block on screen) is at its last
    /// prompt, even when the reply before it still fills the top of the screen.
    public static func current(in blocks: [TranscriptBlock], marks: [PromptMark], visible: Set<String>) -> String? {
        guard let first = marks.first else { return nil }
        let top: String?
        if let last = blocks.last, visible.contains(last.id) {
            top = last.id
        } else {
            top = blocks.first { visible.contains($0.id) }?.id
        }
        guard let top else { return nil }
        let ids = Set(marks.map(\.id))
        var current: String?
        for block in blocks {
            if let prompt = block.items.last(where: { ids.contains($0.id) }) { current = prompt.id }
            if block.id == top { return current ?? first.id }
        }
        return nil
    }
}
