import Foundation
import HermesProtocol

/// One thing the chat draws: a message, or a run of tool calls under one summary line.
public enum TranscriptBlock: Sendable, Hashable, Identifiable {
    case item(TranscriptItem)
    case run(ToolRun)

    public var id: String {
        switch self {
        case .item(let item): item.id
        case .run(let run): run.id
        }
    }
}

/// Tool calls shown as one line, as Desktop's `ToolRun` does
/// (`apps/desktop/src/components/assistant-ui/tool/fallback.tsx:950-1048`): "Explored
/// 3 files, ran 5 commands", opened on demand.
///
/// A settled turn with a final reply folds all its working rows into one run: every
/// tool call and every commentary segment before the reply. A live turn groups only
/// consecutive tool calls, so its commentary reads in place while it streams.
public struct ToolRun: Sendable, Hashable, Identifiable {
    public let id: String
    /// In transcript order: tool rows, and for a folded turn its commentary rows.
    public var items: [TranscriptItem]
    /// The turn is still working and nothing has come after the run.
    public var isLive: Bool

    public init(id: String, items: [TranscriptItem], isLive: Bool) {
        self.id = id
        self.items = items
        self.isLive = isLive
    }

    public var tools: [TranscriptItem] { items.filter { $0.role == .tool } }

    /// The rows the run shows when opened: blank reply segments draw nothing.
    public var visibleItems: [TranscriptItem] { items.filter { !$0.isBlankReply } }

    public var summary: String { ToolCallSummary.run(tools, live: isLive) }
}

extension TranscriptItem {
    /// An assistant row with nothing to show yet: no text (whitespace counts as none),
    /// no reasoning and no outcome. The waiting row stands in for it.
    public var isBlankReply: Bool {
        role == .assistant && !hasReplyText && reasoning.isEmpty && outcome != "interrupted"
    }

    public var hasReplyText: Bool { !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}

extension Transcript {
    /// The transcript as the chat draws it (`TranscriptGrouping.blocks`).
    public var blocks: [TranscriptBlock] { TranscriptGrouping.blocks(items, isRunning: isRunning) }
}

public enum TranscriptGrouping {
    /// Splits the items into turns (a user row starts one; a steer joins the running
    /// turn) and groups each: the running turn's tool calls into runs, a settled
    /// turn's working rows into one run before its reply.
    public static func blocks(_ items: [TranscriptItem], isRunning: Bool) -> [TranscriptBlock] {
        var turns: [[TranscriptItem]] = []
        for item in items {
            if turns.isEmpty || (item.role == .user && !item.isSteer) {
                turns.append([item])
            } else {
                turns[turns.count - 1].append(item)
            }
        }
        return turns.enumerated().flatMap { index, turn in
            isRunning && index == turns.count - 1 ? runs(turn, live: true) : folded(turn)
        }
    }

    /// A settled turn whose last row with text is a reply after every tool call: the
    /// tool calls and the commentary before the reply become one run, where the first
    /// of them was. User, steer and system rows keep their places.
    static func folded(_ turn: [TranscriptItem]) -> [TranscriptBlock] {
        guard let lastTool = turn.lastIndex(where: { $0.role == .tool }),
              let reply = turn.lastIndex(where: { $0.role == .assistant && $0.hasReplyText && !$0.isInterim }),
              reply > lastTool
        else { return runs(turn, live: false) }
        let working = turn.indices.filter { $0 < reply && (turn[$0].role == .tool || turn[$0].role == .assistant) }
        guard let first = working.first else { return runs(turn, live: false) }
        let run = ToolRun(id: "turn-" + turn[first].id, items: working.map { turn[$0] }, isLive: false)
        let folded = Set(working)
        var blocks: [TranscriptBlock] = []
        for index in turn.indices {
            if index == first {
                blocks.append(.run(run))
            } else if !folded.contains(index) {
                blocks.append(.item(turn[index]))
            }
        }
        return blocks
    }

    /// Consecutive tool calls (with blank reply segments between them) as runs; every
    /// other row as itself. With `live`, the run nothing visible follows is live.
    static func runs(_ turn: [TranscriptItem], live: Bool) -> [TranscriptBlock] {
        var blocks: [TranscriptBlock] = []
        var index = 0
        while index < turn.count {
            guard turn[index].role == .tool else {
                blocks.append(.item(turn[index]))
                index += 1
                continue
            }
            var end = index
            var scan = index + 1
            while scan < turn.count, turn[scan].role == .tool || turn[scan].isBlankReply {
                if turn[scan].role == .tool { end = scan }
                scan += 1
            }
            let isLast = !turn[(end + 1)...].contains { !$0.isBlankReply }
            blocks.append(.run(ToolRun(id: "run-" + turn[index].id, items: Array(turn[index...end]),
                                       isLive: live && isLast)))
            index = end + 1
        }
        return blocks
    }
}

/// The words a tool call or a run of them is shown with, ported from Desktop's
/// `run-summary.ts` (`apps/desktop/src/components/assistant-ui/tool/run-summary.ts`) and
/// `summarize-command.ts` (`apps/desktop/src/lib/summarize-command.ts`).
public enum ToolCallSummary {
    /// Clause order is fixed, so the same run always reads the same way.
    enum Category: CaseIterable {
        case edit, explore, search, read, browse, interact, analyze, run, delegate, other

        var copy: (singular: String, plural: String, past: String, present: String) {
            switch self {
            case .analyze: ("image", "images", "Analyzed", "Analyzing")
            case .browse: ("page", "pages", "Opened", "Opening")
            case .delegate: ("task", "tasks", "Delegated", "Delegating")
            case .edit: ("file", "files", "Edited", "Editing")
            case .explore: ("file", "files", "Explored", "Exploring")
            case .interact: ("browser action", "browser actions", "Performed", "Performing")
            case .other: ("tool", "tools", "Used", "Using")
            case .read: ("page", "pages", "Read", "Reading")
            case .run: ("command", "commands", "Ran", "Running")
            case .search: ("query", "queries", "Searched", "Searching")
            }
        }
    }

    static let fileEditTools: Set<String> = ["edit_file", "patch", "write_file"]

    static let toolCategories: [String: Category] = [
        "browser_navigate": .browse,
        "delegate_task": .delegate,
        "execute_code": .run,
        "list_files": .explore,
        "read_file": .explore,
        "search_files": .explore,
        "session_search_recall": .search,
        "terminal": .run,
        "vision_analyze": .analyze,
        "web_extract": .read,
        "web_search": .search,
    ]

    static func category(_ name: String) -> Category {
        if fileEditTools.contains(name) { return .edit }
        return toolCategories[name] ?? (name.hasPrefix("browser_") ? .interact : .other)
    }

    /// The run as one line: one clause per category, skills first, then failures.
    /// While `live`, the category of the call in progress (else the newest) speaks in
    /// the present tense.
    public static func run(_ tools: [TranscriptItem], live: Bool) -> String {
        let narrating = live ? (tools.first { $0.isActive } ?? tools.last) : nil
        let liveCategory = narrating.map { category(name(of: $0)) }
        var skills: [String] = []
        var groups: [Category: [TranscriptItem]] = [:]
        for tool in tools {
            if let skill = skillTitle(tool, live: live) {
                skills.append(skill)
            } else {
                groups[category(name(of: tool)), default: []].append(tool)
            }
        }
        var clauses = skills + Category.allCases.compactMap { category in
            groups[category].map { clause(category, $0, live: category == liveCategory) }
        }
        let failed = tools.filter { $0.tool?.phase == .failed }.count
        if failed > 0 { clauses.append("\(failed) tool call\(failed == 1 ? "" : "s") failed") }
        return clauses.enumerated().map { $0 == 0 ? $1 : lowerFirst($1) }.joined(separator: ", ")
    }

    /// One call's own line: what it did and to what ("Ran swift build",
    /// "Edited Transcript.swift"); other tools by name.
    public static func title(for tool: TranscriptItem) -> String {
        let live = tool.isActive
        if let skill = skillTitle(tool, live: live) { return skill }
        let name = name(of: tool)
        let category = category(name)
        let copy = category.copy
        let verb = live ? copy.present : copy.past
        if category == .other || category == .interact { return name }
        let target = target(of: tool, category: category)
        return target.isEmpty ? "\(verb) \(copy.singular)" : "\(verb) \(target)"
    }

    static func clause(_ category: Category, _ tools: [TranscriptItem], live: Bool) -> String {
        let copy = category.copy
        let verb = live ? copy.present : copy.past
        let count = tools.reduce(0) { $0 + unitCount($1) }
        let target = count == 1 && category != .interact ? target(of: tools[0], category: category) : ""
        // A settled command reads better as a count: its line only earns the space
        // while it is the thing being waited on.
        if !target.isEmpty, live || category != .run { return "\(verb) \(target)" }
        return "\(verb) \(count) \(count == 1 ? copy.singular : copy.plural)"
    }

    static func skillTitle(_ tool: TranscriptItem, live: Bool) -> String? {
        let name = name(of: tool)
        guard name == "skill_view" || name == "skills_list" else { return nil }
        let args = arguments(of: tool)
        let failed = tool.tool?.phase == .failed
        let pending = live && tool.isActive
        let file = firstString(args, ["file_path"])
        let label: String
        if name == "skills_list" {
            label = failed ? "Failed to list skills" : pending ? "Listing skills" : "Listed skills"
        } else if file != nil {
            label = failed ? "Failed to read skill resource" : pending ? "Reading skill resource" : "Read skill resource"
        } else {
            label = failed ? "Failed to load skill" : pending ? "Loading skill" : "Loaded skill"
        }
        let target = [firstString(args, ["name"]), file].compactMap { $0 }.joined(separator: " → ")
        return target.isEmpty ? label : "\(label): \(target)"
    }

    /// The thing a call acted on, as a line names it.
    static func target(of tool: TranscriptItem, category: Category) -> String {
        let args = arguments(of: tool)
        let context = tool.tool?.context ?? tool.detail
        switch category {
        case .run:
            return compact(summarizeShellCommand(firstString(args, ["command", "code"]) ?? context ?? ""), 60)
        case .search:
            return (firstString(args, ["query", "search_term"]) ?? context).map { "“\(compact($0, 48))”" } ?? ""
        case .read, .browse:
            return firstURL(in: .object(args)).map(hostname) ?? context.map { compact($0, 48) } ?? ""
        case .other:
            return name(of: tool)
        default:
            if let path = firstString(args, ["path", "file", "filepath"]) { return basename(path) }
            return (firstString(args, ["query", "url"]) ?? context).map { compact($0, 48) } ?? ""
        }
    }

    /// `web_extract` takes several URLs: each is a page read.
    static func unitCount(_ tool: TranscriptItem) -> Int {
        guard name(of: tool) == "web_extract",
              case .array(let urls)? = arguments(of: tool)["urls"], !urls.isEmpty
        else { return 1 }
        return urls.count
    }

    static func name(of tool: TranscriptItem) -> String { tool.toolName ?? tool.tool?.name ?? "tool" }

    /// The call's arguments as an object; a JSON-encoded string is decoded.
    static func arguments(of tool: TranscriptItem) -> [String: JSONValue] {
        switch tool.tool?.args {
        case .object(let object)?:
            return object
        case .string(let text)?:
            guard let data = text.data(using: .utf8),
                  case .object(let object)? = try? JSONDecoder().decode(JSONValue.self, from: data)
            else { return [:] }
            return object
        default:
            return [:]
        }
    }

    static func firstString(_ args: [String: JSONValue], _ keys: [String]) -> String? {
        for key in keys {
            if let value = args[key]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
                return value
            }
        }
        return nil
    }

    static func firstURL(in value: JSONValue) -> String? {
        switch value {
        case .string(let text):
            return text.hasPrefix("http://") || text.hasPrefix("https://") ? text : nil
        case .array(let values):
            return values.lazy.compactMap(firstURL).first
        case .object(let object):
            return object.keys.sorted().lazy.compactMap { object[$0].flatMap(firstURL) }.first
        default:
            return nil
        }
    }

    static func hostname(_ url: String) -> String {
        guard let components = URLComponents(string: url), let host = components.host else { return url }
        let path = components.path
        return path.isEmpty || path == "/" ? host : host + path
    }

    static func basename(_ path: String) -> String {
        let normalized = path.replacingOccurrences(of: "\\", with: "/").trimmingCharacters(in: .whitespaces)
        return normalized.split(separator: "/").last.map(String.init) ?? normalized
    }

    static func compact(_ text: String, _ limit: Int) -> String {
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.count > limit ? String(trimmed.prefix(limit - 1)) + "…" : trimmed
    }

    static func lowerFirst(_ text: String) -> String {
        guard let first = text.first else { return text }
        return first.lowercased() + text.dropFirst()
    }

    // MARK: Shell commands

    static let silentHeads: Set<String> = ["cd", "pushd", "popd", "export", "set", "unset", "source", ".",
                                           "true", "false", ":"]
    static let pipeTailHeads: Set<String> = ["head", "tail", "wc", "sort", "uniq"]

    /// The command a wrapped shell line is about, for display only: `cd`, env
    /// prefixes, redirects, `| tail` and banner echoes peeled off. Several real
    /// commands read as "first + N commands".
    public static func summarizeShellCommand(_ raw: String) -> String {
        let original = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !original.isEmpty else { return "" }
        let segments = splitCompound(original)
        guard segments.count > 1 else {
            let cleaned = clean(original)
            return cleaned.isEmpty ? original : cleaned
        }
        let core = segments.map(clean).filter { segment in
            !segment.isEmpty && !silentHeads.contains(headWord(segment)) && !isBoundaryEcho(segment)
        }
        switch core.count {
        case 0: return original
        case 1: return core[0]
        default: return "\(core[0]) + \(core.count - 1) \(core.count == 2 ? "command" : "commands")"
        }
    }

    /// Splits on top-level `&&`, `||`, `;` and newlines, outside quotes; each segment
    /// loses its pipe tail.
    static func splitCompound(_ input: String) -> [String] {
        var segments: [String] = []
        var buffer = ""
        var quote: Character?
        var previous: Character?
        let characters = Array(input)
        var index = 0
        while index < characters.count {
            let character = characters[index]
            defer { previous = character }
            if let open = quote {
                buffer.append(character)
                if character == open, previous != "\\" { quote = nil }
                index += 1
                continue
            }
            if character == "\"" || character == "'" {
                quote = character
                buffer.append(character)
                index += 1
                continue
            }
            let next = index + 1 < characters.count ? characters[index + 1] : nil
            if (character == "&" && next == "&") || (character == "|" && next == "|") {
                segments.append(buffer)
                buffer = ""
                index += 2
                continue
            }
            if character == ";" || character == "\n" {
                segments.append(buffer)
                buffer = ""
                index += 1
                continue
            }
            buffer.append(character)
            index += 1
        }
        segments.append(buffer)
        return segments.map { stripPipeTail($0.trimmingCharacters(in: .whitespaces)) }.filter { !$0.isEmpty }
    }

    static func words(_ segment: String) -> [String] {
        var words: [String] = []
        var buffer = ""
        var quote: Character?
        var previous: Character?
        for character in segment {
            defer { previous = character }
            if let open = quote {
                buffer.append(character)
                if character == open, previous != "\\" { quote = nil }
                continue
            }
            if character == "\"" || character == "'" {
                quote = character
                buffer.append(character)
                continue
            }
            if character.isWhitespace {
                if !buffer.isEmpty { words.append(buffer); buffer = "" }
                continue
            }
            buffer.append(character)
        }
        if !buffer.isEmpty { words.append(buffer) }
        return words
    }

    static func commandBasename(_ head: String) -> String {
        head.split(separator: "/").last.map(String.init) ?? head
    }

    static func headWord(_ segment: String) -> String {
        let tokens = words(segment)
        let head = tokens.first { $0.range(of: #"^[A-Za-z_]\w*="#, options: .regularExpression) == nil }
        return commandBasename(head ?? "")
    }

    static func stripPipeTail(_ segment: String) -> String {
        let tokens = words(segment)
        var out: [String] = []
        for (index, word) in tokens.enumerated() {
            if word == "|", index + 1 < tokens.count, pipeTailHeads.contains(commandBasename(tokens[index + 1])) { break }
            out.append(word)
        }
        return out.joined(separator: " ").trimmingCharacters(in: .whitespaces)
    }

    static func clean(_ segment: String) -> String {
        let tokens = words(segment)
        var out: [String] = []
        var skipNext = false
        for word in tokens {
            if skipNext { skipNext = false; continue }
            if word.range(of: #"^\d*(>>?|<)$"#, options: .regularExpression) != nil {
                skipNext = true
                continue
            }
            if word.range(of: #"^\d*(>&|<&)\d+$"#, options: .regularExpression) != nil { continue }
            out.append(word)
        }
        return out.joined(separator: " ").trimmingCharacters(in: .whitespaces)
    }

    static func isBoundaryEcho(_ segment: String) -> Bool {
        let tokens = words(segment)
        guard commandBasename(tokens.first ?? "") == "echo" else { return false }
        let rest = tokens.dropFirst().joined(separator: " ")
        return rest.range(of: #"-{2,}|_exit=|(^|\s|=)\$[?{]|PIPESTATUS"#, options: .regularExpression) != nil
    }
}
