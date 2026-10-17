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
}
