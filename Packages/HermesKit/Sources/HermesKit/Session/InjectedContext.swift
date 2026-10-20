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
/// - A prompt with `@file:` / `@folder:` references is stored as the gateway expanded it for
///   the model: the prompt, then `--- Context Warnings ---` and `--- Attached Context ---`
///   sections holding each file's whole text (`agent/context_references.py:240-246`,
///   stored as is: `tui_gateway/prompt_turn.py:705-722,782-783`).
///
/// Desktop strips the same three things to compare such a turn (`attachmentTolerantUserText`,
/// `apps/desktop/src/lib/chat-messages/attachment-turn.ts:25-46`), and the expansion to show it
/// (`displayContentForMessage`, `apps/desktop/src/lib/chat-messages/hydration.ts:129-145`).
public enum InjectedContext {
    /// The text the user sent, and the image paths the hints name, in order.
    public static func userTurn(_ text: String) -> (text: String, imagePaths: [String]) {
        splitImageHints(strippingAttachedContext(strippingMemoryContext(text)))
    }

    // MARK: Attached context

    static let attachedContextMarker = "--- Attached Context ---"
    static let contextWarningsMarker = "--- Context Warnings ---"

    /// The prompt without the expansion of its references, as Desktop shows it:
    /// - everything from `--- Attached Context ---` on is the files' text, and goes;
    /// - so does `--- Context Warnings ---` and what follows it, up to that section;
    /// - a file the prompt no longer names (an older gateway took the `@file:` token out)
    ///   comes back as a leading `@file:` line, so it still shows as an attachment.
    ///
    /// Lines Hermes appends after the expansion stay: a persisted image turn's `@image:`
    /// lines (`session_history.py:51-60`) and image hints with their placeholders.
    static func strippingAttachedContext(_ text: String) -> String {
        guard text.contains(attachedContextMarker) || text.contains(contextWarningsMarker) else { return text }
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false)[...]
        var trailer: [Substring] = []
        while let last = lines.last, isAppendedAfterExpansion(last) {
            trailer.insert(last, at: 0)
            lines.removeLast()
        }
        let attached = lines.firstIndex { $0.trimmingCharacters(in: .whitespaces) == attachedContextMarker }
        let shown = attached.map { lines[..<$0] } ?? lines
        let warnings = shown.firstIndex { $0.trimmingCharacters(in: .whitespaces) == contextWarningsMarker }
        guard attached != nil || warnings != nil else { return text }
        let prompt = (warnings.map { shown[..<$0] } ?? shown).joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        var missing: [String] = []
        for reference in attached.map({ lines[$0...].compactMap(blockReference) }) ?? []
        where !prompt.contains(reference) && !missing.contains(reference) {
            missing.append(reference)
        }
        let refs = missing.joined(separator: "\n")
        let shownText = [refs, prompt].filter { !$0.isEmpty }.joined(separator: "\n\n")
        let trailing = trailer.drop { $0.trimmingCharacters(in: .whitespaces).isEmpty }
        return ([Substring(shownText)] + trailing).joined(separator: "\n")
    }

    /// A line Hermes adds after the expanded prompt, or a blank line among them.
    private static func isAppendedAfterExpansion(_ line: Substring) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty || placeholders.contains(trimmed) || hintPath(line) != nil
            || ImageDirectives.path(in: line) != nil
    }

    /// The `@file:` / `@folder:` reference a block of the attached context opens with:
    /// `📄 @file:notes.md (120 tokens)` (`context_references.py:386`) or
    /// `📁 @folder:src (40 tokens)` (:299).
    private static func blockReference(_ line: Substring) -> String? {
        for icon in ["📄 ", "📁 "] where line.hasPrefix(icon) {
            let header = line.dropFirst(icon.count)
            guard AttachmentRefs.prefixes.contains(where: { header.hasPrefix($0) }), header.hasSuffix(" tokens)"),
                let count = header.range(of: " (", options: .backwards)
            else { return nil }
            return String(header[..<count.lowerBound])
        }
        return nil
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
