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
    public var promptMarks: [PromptMark] { derived.derived.marks(items) }

    /// The prompt the chat is at with the blocks `visibleBlockIDs` on screen
    /// (`PromptMark.current`). Nil when the transcript has no prompts or no block is
    /// on screen.
    public func currentPromptID(visibleBlockIDs: Set<String>, atEnd: Bool = false, picked: String? = nil) -> String? {
        PromptMark.current(in: blocks, marks: promptMarks, visible: visibleBlockIDs, atEnd: atEnd, picked: picked)
    }
}

extension PromptMark {
    /// The prompt the chat is at with the blocks `visible` on screen: the last prompt in
    /// or above the first block on screen, or the first prompt when that block is above
    /// them all.
    /// - A chat scrolled to its end (`atEnd`, its bottom on screen) is at its last
    ///   prompt, even when the reply before it still fills the top of the screen.
    /// - A prompt `picked` on the rail is the one the chat is at while the pick holds
    ///   (`PromptPick`), whatever else is on screen. The one before last scrolls to the
    ///   top of the screen with the last prompt under it, or only as far as the chat's
    ///   end, and either rule would mark the last prompt instead.
    public static func current(in blocks: [TranscriptBlock], marks: [PromptMark], visible: Set<String>,
                               atEnd: Bool = false, picked: String? = nil) -> String? {
        guard let first = marks.first else { return nil }
        if let picked, marks.contains(where: { $0.id == picked }) { return picked }
        guard let top = blocks.first(where: { visible.contains($0.id) })?.id else { return nil }
        if atEnd { return marks.last?.id }
        let ids = Set(marks.map(\.id))
        var current: String?
        for block in blocks {
            if let prompt = block.items.last(where: { ids.contains($0.id) }) { current = prompt.id }
            if block.id == top { return current ?? first.id }
        }
        return nil
    }
}

/// A prompt picked on the chat's prompt rail (a tick or a row of its panel). The chat is
/// at that prompt until the user scrolls it away: the pick holds until the prompt's
/// block, once on screen, leaves it. The jump to the prompt lands after the pick, so a
/// block not on screen yet does not end it. The app also ends it when the user scrolls
/// or sends.
public struct PromptPick: Sendable, Hashable {
    public let promptID: String
    /// Whether the prompt's block has been on screen since the pick.
    public private(set) var wasShown = false

    public init(promptID: String) {
        self.promptID = promptID
    }

    /// The pick with the blocks `visible` on screen; nil once the prompt's block, having
    /// been on screen, has left it, or when the prompt is no longer in `transcript`.
    public func holding(visible: Set<String>, in transcript: Transcript) -> PromptPick? {
        guard let block = transcript.blockID(containing: promptID) else { return nil }
        var pick = self
        if visible.contains(block) {
            pick.wasShown = true
        } else if wasShown {
            return nil
        }
        return pick
    }
}
