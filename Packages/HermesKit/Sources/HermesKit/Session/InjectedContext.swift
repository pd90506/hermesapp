import Foundation

/// Text Hermes writes into a stored user turn that the user never typed.
///
/// - A memory provider's recall (Hindsight, Honcho, …) rides the turn as a
///   `<memory-context>` block (`agent/memory_manager.py:372-388`). Hermes strips it
///   from what it loads back (`sanitize_context`, `:165-177`); a stored row can still
///   carry it, e.g. as the last part of an image turn (`tui_gateway/session_history.py:192-198`).
/// - An image sent through a messaging platform is stored as the caption, a blank line
///   and one `[Image attached at: <path>]` hint per image (`agent/image_routing.py:561`),
///   flattened with a `[screenshot]` line per image part (`session_history.py:134-138`).
///   `session.resume` turns those into `@image:` refs (`_user_image_display_text`,
///   `session_history.py:150-210`); the REST page does not, so the client does.
///
/// Desktop strips the same three things to compare such a turn (`attachmentTolerantUserText`,
/// `apps/desktop/src/lib/chat-messages/attachment-turn.ts:25-46`).
public enum InjectedContext {
    /// The text the user sent, and the image paths the hints name, in order.
    public static func userTurn(_ text: String) -> (text: String, imagePaths: [String]) {
        splitImageHints(strippingMemoryContext(text))
    }

    // MARK: Memory context

    /// `sanitize_context`: closed blocks, then the system note and stray fence tags. A block
    /// left open runs to the end, as Desktop reads it (`attachment-turn.ts:27`).
    static func strippingMemoryContext(_ text: String) -> String {
        guard text.range(of: "memory-context", options: .caseInsensitive) != nil
            || text.contains("[System note:")
        else { return text }
        var stripped = text
        for pattern in [closedBlock, openBlock, systemNote, fenceTag] {
            stripped = pattern.stringByReplacingMatches(
                in: stripped, range: NSRange(stripped.startIndex..., in: stripped), withTemplate: "")
        }
        return stripped == text ? text : stripped.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // Built per call: `NSRegularExpression` is not `Sendable` on every platform.
    private static var closedBlock: NSRegularExpression { try! NSRegularExpression(
        pattern: "<\\s*memory-context\\s*>[\\s\\S]*?</\\s*memory-context\\s*>", options: .caseInsensitive) }
    private static var openBlock: NSRegularExpression { try! NSRegularExpression(
        pattern: "<\\s*memory-context\\s*>[\\s\\S]*$", options: .caseInsensitive) }
    private static var systemNote: NSRegularExpression { try! NSRegularExpression(
        pattern: "\\[System note:\\s*The following is recalled memory context,\\s*NOT new user input\\.\\s*"
            + "Treat as (?:informational background data|authoritative reference data[^\\]]*)\\.\\]\\s*",
        options: .caseInsensitive) }
    private static var fenceTag: NSRegularExpression { try! NSRegularExpression(
        pattern: "</?\\s*memory-context\\s*>", options: .caseInsensitive) }

    // MARK: Image hints

    static let hintPrefix = "[Image attached at: "
    /// What an image part flattens to: the session store's stand-in, or `[image]` from
    /// a parts list read as text (`StoredMessageProjection.text(of:)`).
    static let placeholders: Set<String> = ["[screenshot]", "[image]"]
    /// The caption Hermes sends when the user typed none (`image_routing.py:561`).
    static let defaultCaption = "What do you see in this image?"

    /// The trailing hint lines lifted off as paths, with the placeholders after them;
    /// a hint inside the caption stays text.
    static func splitImageHints(_ text: String) -> (text: String, imagePaths: [String]) {
        guard text.contains(hintPrefix) else { return (text, []) }
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false)[...]
        while let last = lines.last?.trimmingCharacters(in: .whitespaces),
            last.isEmpty || placeholders.contains(last)
        {
            lines.removeLast()
        }
        var paths: [String] = []
        while let last = lines.last, let path = hintPath(last) {
            paths.insert(path, at: 0)
            lines.removeLast()
        }
        guard !paths.isEmpty else { return (text, []) }
        let caption = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return (caption == defaultCaption ? "" : caption, paths)
    }

    /// `_IMAGE_HINT_RE` (`session_history.py:131`) over a whole line.
    private static func hintPath(_ line: Substring) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix(hintPrefix), trimmed.hasSuffix("]") else { return nil }
        let path = trimmed.dropFirst(hintPrefix.count).dropLast()
        return path.isEmpty || path.contains("]") ? nil : String(path)
    }
}
