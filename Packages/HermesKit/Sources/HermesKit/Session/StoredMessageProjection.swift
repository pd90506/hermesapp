import Foundation
import HermesProtocol

/// Turns stored rows from `GET /api/sessions/{id}/messages` into display rows.
///
/// The REST page carries raw state.db rows; `session.resume` used to send them
/// already projected by `_history_to_messages` (`tui_gateway/session_history.py:285-362`).
/// This mirrors the parts of that projection a text transcript needs:
/// - only `user`, `assistant`, `tool` and `system` rows, never `display_kind == "hidden"`
///   (:299-301), never a `[System: …]` user notice (:228-236, :305-306);
/// - `display_content` replaces `content` (compaction summaries and steers,
///   `hermes_cli/web_routers/sessions.py:663-680`);
/// - an assistant row with neither text nor reasoning is skipped (:336-339); the
///   tool calls it carries name the tool rows that follow it (:309-317, :322-324);
/// - user text loses Discord trigger notes (:307-308) and a slash-skill turn shows
///   the invocation as typed, `/work fix the leak` (:349-352, see `userDisplayText`).
///
/// Like Desktop (`apps/desktop/src/app/chat/transcript-backfill.ts:29-71`, #96875),
/// the session's opening user row stays visible when compaction stamped it hidden.
///
/// `[unverified]` The tool row's `detail` is a client-side preview of the call's
/// arguments; the gateway's `build_tool_preview` (`server.py:2433-2439`) is not
/// reproduced exactly.
enum StoredMessageProjection {
    /// Tool name and arguments by tool-call id, carried from an assistant row to
    /// its tool rows (possibly on a newer page).
    typealias ToolCalls = [String: (name: String, args: [String: JSONValue])]

    /// - Parameter startsSession: `rows` begins at the session's first row.
    static func items(from rows: [StoredMessage], toolCalls: inout ToolCalls,
                      startsSession: Bool = false) -> [TranscriptItem] {
        var items: [TranscriptItem] = []
        let opening = startsSession ? rows.firstIndex { $0.role == "user" } : nil
        for (index, row) in rows.enumerated() {
            guard row.displayKind != "hidden" || index == opening else { continue }
            let text = displayText(row)
            switch row.role {
            case "user":
                if text.trimmingCharacters(in: .whitespaces).hasPrefix("[System:") { continue }
                // Recalled memory is not the user's text; `@image:` lines and image hints
                // are the images sent with it (`session_history.py:51-60`, `InjectedContext`),
                // leading `@file:` lines the files (`AttachmentRefs`).
                let (typed, hinted) = InjectedContext.userTurn(text)
                let (caption, directives) = ImageDirectives.split(userDisplayText(typed))
                let paths = directives + hinted
                let (body, refs) = AttachmentRefs.splitLeading(caption)
                guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !paths.isEmpty || !refs.isEmpty
                else { continue }
                var user = item(row, role: .user, text: body)
                user.images = TranscriptImage.stored(paths)
                user.attachments = refs.map(AttachmentRefs.displayName)
                user.attachmentPaths = refs
                // `steer` rows show the steer text (`display_content`, `web_routers/sessions.py:663-667`).
                user.displayKind = row.displayKind
                items.append(user)
            case "assistant":
                for call in row.toolCalls?.arrayValue ?? [] {
                    guard let id = call["id"]?.stringValue, !id.isEmpty,
                        let name = call["function"]?["name"]?.stringValue, !name.isEmpty
                    else { continue }
                    toolCalls[id] = (name, arguments(call["function"]?["arguments"]))
                }
                let reasoning = row.reasoning ?? row.reasoningContent ?? ""
                if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && reasoning.isEmpty { continue }
                var assistant = item(row, role: .assistant, text: text)
                assistant.reasoning = reasoning
                items.append(assistant)
            case "tool":
                let call = row.toolCallID.flatMap { toolCalls[$0] }
                // Keyed by its row like every stored item: a stable identity for `ForEach`,
                // whatever live rows share its call id.
                var tool = TranscriptItem(id: rowItemID(row), role: .tool, text: "")
                tool.rowID = row.id
                tool.timestamp = row.timestamp.map(Date.init(timeIntervalSince1970:))
                tool.toolCallID = row.toolCallID
                let name = call?.name ?? row.toolName ?? "tool"
                tool.toolName = name
                tool.detail = call.flatMap { preview($0.args) }
                // A stored tool row is a finished call, with its result: Desktop shows
                // it (`applyStoredToolResult`, `lib/chat-messages/tool-parts.ts:832-892`),
                // unlike `_history_to_messages`, which keeps only edit tools' (`session_history.py:331`).
                var activity = ToolActivity(toolID: row.toolCallID ?? tool.id, name: name, phase: .complete)
                activity.context = tool.detail
                if let args = call?.args, !args.isEmpty { activity.args = .object(args) }
                activity.output = Self.text(of: row.content)
                activity.result = Self.result(of: row.content)
                tool.tool = activity
                items.append(tool)
            case "system":
                guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                items.append(item(row, role: .system, text: text))
            default:
                continue
            }
        }
        return items
    }

    /// A stored tool row's content as its result: JSON text as that JSON, other text
    /// as itself, no content as an empty result (`parseStoredToolResult`,
    /// `apps/desktop/src/lib/chat-messages/tool-parts.ts:774-793`).
    static func result(of content: JSONValue?) -> JSONValue {
        switch content {
        case nil, .null?: return .object([:])
        case .string(let text)?:
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .string("") }
            return ToolCallView.parseJSON(text) ?? .string(text)
        case let value?: return value
        }
    }

    static func rowItemID(_ row: StoredMessage) -> String {
        row.id.map { "row-\($0)" } ?? "row-\(UUID().uuidString)"
    }

    private static func item(_ row: StoredMessage, role: TranscriptItem.Role, text: String) -> TranscriptItem {
        var item = TranscriptItem(id: rowItemID(row), role: role, text: text)
        item.rowID = row.id
        item.timestamp = row.timestamp.map(Date.init(timeIntervalSince1970:))
        return item
    }

    // MARK: User text

    /// User text as `_history_to_messages` shows it: Discord trigger notes removed
    /// (`session_history.py:13-15,307-308`), then a skill scaffold replaced by the
    /// invocation as typed (`:239-241,349-352`, `agent/skill_commands.py:144-171`).
    static func userDisplayText(_ text: String) -> String {
        // The regex is built per call; most rows carry no note at all.
        let stripped = text.contains("[Triggering message id: `")
            ? discordNote.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text),
                                                   withTemplate: "$1")
            : text
        return skillInvocation(stripped) ?? stripped
    }

    /// `_DISCORD_TRIGGERING_NOTE_RE`. Python's `^` without MULTILINE is the start of the text.
    /// Built per call: `NSRegularExpression` is not `Sendable` on every platform.
    private static var discordNote: NSRegularExpression { try! NSRegularExpression(
        pattern: "(^|\\n)\\[Triggering message id: `[^`\\n]*` \u{2014} use as `message_id` for reply/react/pin via the discord tools\\.\\]\\n*") }

    // Markers of `agent/skill_commands.py:42-74`; they must stay byte-identical to Hermes's builders.
    private static let invocationPrefix = "[IMPORTANT: The user has invoked the "
    private static let singleSkillMarker = "The full skill content is loaded below.]"
    private static let singleSkillInstruction = "The user has provided the following instruction alongside the skill invocation: "
    private static let runtimeNote = "\n\n[Runtime note:"
    private static let bundleMarker = " skill bundle,"
    private static let bundleInstruction = "\nUser instruction: "
    private static let bundleFirstSkillBlock = "\n\n[Loaded as part of the "
    private static let autoLoadPrefix = "[IMPORTANT: The \""
    private static let skillDirNoteEnd = "then run them with the terminal tool using the absolute path."
    private static let excerptJoint = "\u{1E}"

    /// `describe_skill_invocation(content, separator=" ")` (`skill_commands.py:144-171`):
    /// `/work fix the leak`, `/work` for a bare invocation, `nil` when not scaffolding.
    static func skillInvocation(_ content: String) -> String? {
        if content.hasPrefix(autoLoadPrefix) { return autoLoadedSkillTurn(content) }
        guard content.hasPrefix(invocationPrefix) else { return nil }
        // `_SKILL_NAME_RE`: the first quoted span after the prefix.
        let afterPrefix = content.dropFirst(invocationPrefix.count)
        var name = ""
        if afterPrefix.hasPrefix("\""), let close = afterPrefix.dropFirst().firstIndex(of: "\"") {
            name = String(afterPrefix[afterPrefix.index(after: afterPrefix.startIndex)..<close])
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let label = name.hasPrefix("/") ? name : "/\(name)"
        // `extract_user_instruction_from_skill_message` (:101-115).
        var instruction: String?
        if content.contains(bundleMarker) {
            instruction = cut(content, after: bundleInstruction, until: bundleFirstSkillBlock, last: false)
        } else if content.contains(singleSkillMarker) {
            instruction = cut(content, after: singleSkillInstruction, until: runtimeNote, last: true)
        }
        if let instruction {
            let words = (instruction.components(separatedBy: excerptJoint).first ?? "")
                .split(whereSeparator: \.isWhitespace).joined(separator: " ")
            if !words.isEmpty { return name.isEmpty ? words : "\(label) \(words)" }
        }
        return name.isEmpty ? nil : label
    }

    /// `_describe_auto_loaded_skill_turn` (`skill_commands.py:118-141`): the text after the last payload footer.
    private static func autoLoadedSkillTurn(_ content: String) -> String? {
        let afterPrefix = content.dropFirst(autoLoadPrefix.count)
        let name = afterPrefix.firstIndex(of: "\"").map { String(afterPrefix[..<$0]) } ?? ""
        let bare = name.isEmpty ? nil : "/\(name)"
        guard let footer = content.range(of: skillDirNoteEnd, options: .backwards) else { return bare }
        let words = content[footer.upperBound...].split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return words.isEmpty ? bare : words
    }

    /// `_cut_after` (`skill_commands.py:174-179`): the text between `marker` and `stop`, stripped; `nil` if empty.
    private static func cut(_ content: String, after marker: String, until stop: String, last: Bool) -> String? {
        guard let range = content.range(of: marker, options: last ? .backwards : []) else { return nil }
        let tail = content[range.upperBound...]
        let body = tail.range(of: stop).map { tail[..<$0.lowerBound] } ?? tail
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// `display_content`, else `content`: a string, or the text of its parts.
    static func displayText(_ row: StoredMessage) -> String {
        text(of: row.displayContent) ?? text(of: row.content) ?? ""
    }

    private static func text(of value: JSONValue?) -> String? {
        switch value {
        case .string(let text)?: return text
        case .array(let parts)?:
            return parts.compactMap { part -> String? in
                if let text = part.stringValue { return text }
                if let text = part["text"]?.stringValue { return text }
                // Image parts; `inline_images=false` usually turned them into text already.
                if let type = part["type"]?.stringValue, type.contains("image") { return "[image]" }
                return nil
            }.joined(separator: "\n")
        default: return nil
        }
    }

    private static func arguments(_ value: JSONValue?) -> [String: JSONValue] {
        switch value {
        case .object(let object)?: return object
        case .string(let json)?:
            guard let decoded = try? JSONDecoder().decode(JSONValue.self, from: Data(json.utf8)),
                case .object(let object) = decoded
            else { return [:] }
            return object
        default: return [:]
        }
    }

    /// A short argument preview, at most 80 characters like the gateway's.
    private static func preview(_ args: [String: JSONValue]) -> String? {
        let preferred = ["command", "path", "file_path", "url", "query", "pattern", "name", "code"]
        let value = preferred.lazy.compactMap { args[$0]?.stringValue }.first
            ?? args.keys.sorted().lazy.compactMap { args[$0]?.stringValue }.first
        guard let value else { return nil }
        let line = value.split(whereSeparator: \.isNewline).first.map(String.init) ?? value
        return line.count > 80 ? String(line.prefix(77)) + "..." : line
    }
}
