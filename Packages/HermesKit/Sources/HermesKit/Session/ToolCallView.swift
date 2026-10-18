import Foundation
import HermesProtocol

/// How one tool call is drawn: its title, status, counts and what it opens to. Ported
/// from Desktop's `buildToolView` (`apps/desktop/src/components/assistant-ui/tool/fallback-model/index.ts`)
/// and the choices its `ToolEntry` makes from it (`tool/fallback.tsx:309-520`).
///
/// Each tool reads its own fields: `read_file` is "Read notes.md L237-259" and opens to
/// the lines it read, `terminal` is "Ran git status" and opens to `$ git status` and its
/// output, `web_search` opens to its hits. Unknown tools fall back to a readable
/// summary of the result.
public struct ToolCallView: Sendable, Hashable {
    public enum Status: Sendable, Hashable {
        case running, success, error
        /// Routine and expected: a guessed path that wasn't there, `grep` finding nothing.
        case notice
        /// A call with no result to show, or a refused memory write.
        case warning
    }

    public struct SearchHit: Sendable, Hashable {
        public var title: String
        public var url: String
        public var snippet: String
    }

    public let toolName: String
    public let title: String
    public let status: Status
    public let isPending: Bool
    public let isFileEdit: Bool
    /// A line under the title: a path, a query, a first line of output. Desktop shows it
    /// only as an edit's tooltip; it decides whether `detail` says anything new.
    public let subtitle: String
    /// What the call opens to: the file's lines, the command's output, a summary.
    public let detail: String
    /// A heading over `detail` ("Error details"), or "".
    public let detailLabel: String
    /// "3 results", "12 files"; nil while pending or for an error.
    public let countLabel: String?
    public let durationLabel: String?
    /// An edit's diff, without its "┊ review diff" heading.
    public let inlineDiff: String
    public let searchQuery: String?
    public let searchHits: [SearchHit]
    /// A command's streams, when the backend reported them apart.
    public let stdout: String?
    public let stderr: String?
    /// `terminal`: the command, shown as `$ command` above its output.
    public let terminalCommand: String?
    public let terminalExitCode: Int?

    public init(_ item: TranscriptItem) {
        let tool = item.tool
        let name = item.toolName ?? tool?.name ?? "tool"
        // Before its arguments arrive, a call is known by the gateway's preview of them.
        var args = tool?.args
        if Self.record(args).isEmpty, let context = tool?.context ?? item.detail, !context.isEmpty {
            args = .object(["context": .string(context)])
        }
        self.init(name: name, args: args, result: tool.flatMap(Self.result), isPending: item.isActive,
                  isError: tool?.phase == .failed, metadata: Self.metadata(tool))
    }

    /// - Parameters:
    ///   - result: the call's result (`tool.complete`'s `result`, a stored row's content); nil
    ///     while it runs, or when it ended without one.
    ///   - metadata: the gateway's display hints (`duration_s`, `summary`, `inline_diff`,
    ///     `error`): never the result, but read beside it as Desktop's `toolResultRecord` does.
    init(name: String, args: JSONValue?, result: JSONValue?, isPending: Bool, isError: Bool,
         metadata: [String: JSONValue] = [:]) {
        let argsRecord = Self.record(args)
        let resultRecord = metadata.merging(Self.record(result)) { $1 }
        let part = Part(name: name, args: args, result: result, isPending: isPending, isError: isError,
                        metadata: metadata)
        let status = Self.status(part, resultRecord)
        let error = status == .success ? "" : Self.errorText(part, resultRecord)
        let meta = Self.meta(name)
        let memoryMissed = name == "memory" && result != nil && status != .success
        let baseTitle = result == nil ? meta.pending : memoryMissed ? "Memory write noted" : meta.done
        let unavailable = result == nil && !isPending
        let title = unavailable ? "Result unavailable" : Self.dynamicTitle(part, argsRecord, resultRecord) ?? baseTitle
        let baseSubtitle = error.isEmpty ? Self.subtitle(part, argsRecord, resultRecord) : error
        let keepsSubtitle = name == "terminal" || name == "execute_code"
            || (Self.fileEditTools.contains(name) && !baseSubtitle.trimmed.isEmpty)
        let detailBody = Self.stripDividerLines(Self.detailText(part, argsRecord, resultRecord))
        var unique: [String] = []
        for value in [error, detailBody] where !value.isEmpty && !unique.contains(where: { $0.trimmed == value.trimmed }) {
            unique.append(value)
        }
        let rendersAnsi = name == "terminal" || name == "execute_code"
        let stdout = rendersAnsi ? Self.firstString(resultRecord, ["stdout"]) : ""
        let stderr = rendersAnsi ? Self.firstString(resultRecord, ["stderr"]) : ""
        let splitStreams = rendersAnsi && (!stdout.isEmpty || !stderr.isEmpty)
        let query = name == "web_search"
            ? Self.firstString(argsRecord, ["search_term", "query"]).nonEmpty ?? Self.contextValue(args)
            : ""

        toolName = name
        self.title = title
        self.status = status
        self.isPending = isPending
        isFileEdit = Self.fileEditTools.contains(name)
        subtitle = title != baseTitle && error.isEmpty && !keepsSubtitle ? "" : baseSubtitle
        detail = error.isEmpty ? detailBody : unique.joined(separator: "\n\n")
        detailLabel = error.isEmpty ? (name == "web_search" ? "Details" : name == "browser_snapshot" ? "Snapshot summary" : "")
            : "Error details"
        countLabel = status == .error ? nil : Self.resultCount(part, argsRecord, resultRecord).map(Self.countText)
        durationLabel = Self.number(resultRecord["duration_s"]).flatMap { $0 < 0 ? nil : Self.duration($0) }
        inlineDiff = Self.inlineDiff(resultRecord)
        searchQuery = query.isEmpty ? nil : query
        searchHits = name == "web_search" && status != .error ? Self.searchResults(result) : []
        self.stdout = splitStreams && !stdout.isEmpty ? stdout : nil
        self.stderr = splitStreams && !stderr.isEmpty ? stderr : nil
        terminalCommand = name == "terminal" ? Self.shellCommand(argsRecord) : nil
        terminalExitCode = name == "terminal" ? resultRecord["exit_code"]?.doubleValue.flatMap { Int(exactly: $0) } : nil
    }

    // MARK: What the row shows

    /// An edit with a diff opens by default; everything else starts closed.
    public var opensByDefault: Bool { !inlineDiff.isEmpty }

    /// A settled edit with no diff to review (a `write_file` create after a reload)
    /// draws nothing, as Desktop hides it; failures and running edits still show.
    public var isHidden: Bool { isFileEdit && !isPending && status != .error && inlineDiff.isEmpty }

    /// For an error: its first paragraph, shown as a heading over the rest.
    public var errorSummary: String { status == .error ? errorParagraphs.first ?? "" : "" }

    /// The detail as shown: for an error, everything after `errorSummary`.
    public var detailBody: String {
        status == .error ? errorParagraphs.dropFirst().joined(separator: "\n\n") : detail
    }

    private var errorParagraphs: [String] {
        detail.replacingOccurrences(of: #"\n\s*\n+"#, with: "\u{1E}", options: .regularExpression)
            .split(separator: "\u{1E}").map { String($0).trimmed }.filter { !$0.isEmpty }
    }

    public var showsDetail: Bool {
        guard inlineDiff.isEmpty else { return false }
        if stdout != nil || stderr != nil { return true }
        switch status {
        case .error: return !errorSummary.isEmpty || !detailBody.isEmpty
        case .notice where !detail.isEmpty: return true
        default:
            return !detail.isEmpty && !Self.looksRedundant(title, detail) && !Self.looksRedundant(subtitle, detail)
        }
    }

    /// Output, file lines and code read as code; other details as text.
    public var rendersDetailAsCode: Bool {
        status != .error && (toolName == "terminal" || toolName == "execute_code" || toolName == "read_file")
    }

    public var isExpandable: Bool {
        !inlineDiff.isEmpty || showsDetail || !searchHits.isEmpty || stdout != nil || stderr != nil
            || terminalCommand?.isEmpty == false || terminalExitCode != nil
    }

    /// Painted text stops here; Desktop's Copy still takes all of it.
    public static let maxDisplayCharacters = 20_000

    public static func clampForDisplay(_ value: String, max: Int = maxDisplayCharacters) -> String {
        guard value.count > max else { return value }
        let omitted = value.count - max
        return String(value.prefix(max)) + "\n\n… \(omitted) more characters truncated"
    }

    /// Terminal output without its color codes: the app draws it in one color.
    public static func stripANSI(_ text: String) -> String {
        guard text.contains("\u{1B}") else { return text }
        return text.replacingOccurrences(of: #"\x{1B}\[[0-9;?]*[ -/]*[@-~]"#, with: "", options: .regularExpression)
    }

    // MARK: Inputs

    struct Part {
        var name: String
        var args: JSONValue?
        var result: JSONValue?
        var isPending: Bool
        var isError: Bool
        var metadata: [String: JSONValue]
    }

    static let fileEditTools = ToolCallSummary.fileEditTools

    /// The call's result: the structured one when known, else the output text read as
    /// JSON when it is JSON (`parseStoredToolResult`, `lib/chat-messages/tool-parts.ts:774-793`).
    static func result(_ tool: ToolActivity) -> JSONValue? {
        if let result = tool.result { return result }
        guard let output = tool.output else { return nil }
        if output.trimmed.isEmpty { return .string("") }
        return parseJSON(output) ?? .string(output)
    }

    static func metadata(_ tool: ToolActivity?) -> [String: JSONValue] {
        guard let tool else { return [:] }
        var metadata: [String: JSONValue] = [:]
        if let seconds = tool.durationSeconds { metadata["duration_s"] = .number(seconds) }
        if let summary = tool.summary { metadata["summary"] = .string(summary) }
        if let diff = tool.inlineDiff { metadata["inline_diff"] = .string(diff) }
        if let error = tool.error { metadata["error"] = .string(error) }
        return metadata
    }

    static func parseJSON(_ text: String) -> JSONValue? {
        guard let data = text.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(JSONValue.self, from: data)
    }

    /// An object, or a string holding one; anything else is empty (`parseMaybeObject`).
    static func record(_ value: JSONValue?) -> [String: JSONValue] {
        switch value {
        case .object(let object)?: return object
        case .string(let text)?:
            guard !text.trimmed.isEmpty, case .object(let object)? = parseJSON(text) else { return [:] }
            return object
        default: return [:]
        }
    }

    static func firstString(_ record: [String: JSONValue], _ keys: [String]) -> String {
        for key in keys {
            if let value = record[key]?.stringValue?.trimmed, !value.isEmpty { return value }
        }
        return ""
    }

    /// `Number(value)`, as Desktop's `numberValue` reads it.
    static func number(_ value: JSONValue?) -> Double? {
        switch value {
        case .number(let number)?: return number
        case .string(let text)?: return text.trimmed.isEmpty ? 0 : Double(text.trimmed)
        case .bool(let flag)?: return flag ? 1 : 0
        case .null?: return 0
        default: return nil
        }
    }

    static func numberText(_ value: JSONValue) -> String {
        guard let number = value.doubleValue else { return "" }
        return number.rounded() == number && abs(number) < 1e15 ? String(Int(number)) : String(number)
    }

    /// The `context`/`preview` of an object, or the string itself (`contextValue`).
    static func contextValue(_ value: JSONValue?) -> String {
        let row = record(value)
        if let context = row["context"]?.stringValue { return context }
        if let preview = row["preview"]?.stringValue { return preview }
        return value?.stringValue ?? ""
    }

    static func compactPreview(_ value: String, _ max: Int = 72) -> String {
        let line = value.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).trimmed
        return line.count > max ? String(line.prefix(max - 1)) + "…" : line
    }

    /// `compactPreview` of an object: its `context`, as text.
    static func compactPreview(_ record: [String: JSONValue], _ max: Int) -> String {
        switch record["context"] {
        case nil, .null?: return ""
        case .string(let text)?: return compactPreview(text, max)
        case let value?:
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            return compactPreview((try? encoder.encode(value)).map { String(decoding: $0, as: UTF8.self) } ?? "", max)
        }
    }

    static func capitalize(_ text: String) -> String {
        guard let first = text.first else { return text }
        return first.uppercased() + text.dropFirst()
    }

    static func basename(_ path: String) -> String { ToolCallSummary.basename(path) }

    static let urlPattern = #"https?://[^\s'"<>)\]]+"#

    /// The first URL anywhere in the values, depth first.
    static func firstURL(_ sources: JSONValue?...) -> String {
        for source in sources {
            if let source, let url = firstURL(in: source) { return url }
        }
        return ""
    }

    static func firstURL(in value: JSONValue) -> String? {
        switch value {
        case .string(let text):
            return text.range(of: urlPattern, options: [.regularExpression, .caseInsensitive]).map { String(text[$0]) }
        case .array(let values):
            return values.lazy.compactMap(firstURL(in:)).first
        case .object(let object):
            return object.keys.sorted().lazy.compactMap { object[$0].flatMap(firstURL(in:)) }.first
        default:
            return nil
        }
    }

    static func hostname(_ url: String) -> String { ToolCallSummary.hostname(url) }

    // MARK: Status

    static func status(_ part: Part, _ result: [String: JSONValue]) -> Status {
        if part.result == nil, part.isPending { return .running }
        if part.result == nil, !part.isError { return .warning }
        if result["success"] == .bool(true) || result["ok"] == .bool(true) { return .success }
        let error = errorText(part, result)
        if error.isEmpty { return .success }
        // A guessed read path missing is routine exploration, not a broken tool.
        if part.name == "read_file", error.range(of: "^File not found:", options: [.regularExpression, .caseInsensitive]) != nil {
            return .notice
        }
        if part.name == "terminal", error == "Command failed with exit code 1." { return .notice }
        // A refused memory write is a budget negotiation, not a failure.
        return part.name == "memory" ? .warning : .error
    }

    static func errorText(_ part: Part, _ result: [String: JSONValue]) -> String {
        let extracted = ToolResultText.errorMessage(part.result)
        if part.isError {
            if !extracted.isEmpty { return extracted }
            let envelope = (part.metadata["error"]?.stringValue ?? part.metadata["message"]?.stringValue)?.trimmed ?? ""
            if !envelope.isEmpty { return envelope }
            if let text = part.result?.stringValue?.trimmed, !text.isEmpty { return text }
            return "Tool returned an error."
        }
        if !extracted.isEmpty { return extracted }
        if result["success"] == .bool(false) || result["ok"] == .bool(false) {
            return firstString(result, ["message", "reason", "detail"]).nonEmpty ?? "Tool returned success=false."
        }
        if let status = result["status"]?.stringValue, ToolResultText.isFailureStatus(status) {
            return firstString(result, ["message", "reason", "detail"]).nonEmpty ?? "Tool returned status \"\(status)\"."
        }
        // A non-zero exit code alone is a weak failure signal (grep's no-match, diff's
        // differences): only an error when the command printed nothing.
        if let exit = number(result["exit_code"]), exit != 0 {
            let hasOutput = !firstString(result, ["output", "stdout", "stderr", "output_preview"]).isEmpty
            return hasOutput ? "" : "Command failed with exit code \(numberText(.number(exit)))."
        }
        return ""
    }

    /// The call reported failure, from its flag or its result (`toolCallFailed`).
    static func failed(_ part: Part) -> Bool {
        let result = record(part.result)
        return result["success"] != .bool(true) && result["ok"] != .bool(true)
            && (part.isError || result["success"] == .bool(false) || result["ok"] == .bool(false)
                || !ToolResultText.errorMessage(part.result).isEmpty)
    }

    // MARK: Titles

    struct Meta {
        var done: String
        var pending: String
    }

    static let titles: [String: Meta] = [
        "browser_click": Meta(done: "Clicked page element", pending: "Clicking page element"),
        "browser_fill": Meta(done: "Filled form field", pending: "Filling form field"),
        "browser_navigate": Meta(done: "Opened page", pending: "Opening page"),
        "browser_snapshot": Meta(done: "Captured page snapshot", pending: "Capturing page snapshot"),
        "browser_take_screenshot": Meta(done: "Captured screenshot", pending: "Capturing screenshot"),
        "browser_type": Meta(done: "Typed on page", pending: "Typing on page"),
        "clarify": Meta(done: "Asked a question", pending: "Asking a question"),
        "cronjob": Meta(done: "Cron job", pending: "Scheduling cron job"),
        "edit_file": Meta(done: "Edited file", pending: "Editing file"),
        "execute_code": Meta(done: "Ran code", pending: "Scripting"),
        "image_generate": Meta(done: "Generated image", pending: "Generating image"),
        "list_files": Meta(done: "Listed files", pending: "Listing files"),
        "memory": Meta(done: "Saved to memory", pending: "Saving to memory"),
        "patch": Meta(done: "Patched file", pending: "Patching file"),
        "read_file": Meta(done: "Read file", pending: "Reading file"),
        "search_files": Meta(done: "Searched files", pending: "Searching files"),
        "session_search_recall": Meta(done: "Searched session history", pending: "Searching session history"),
        "terminal": Meta(done: "Ran command", pending: "Running command"),
        "todo": Meta(done: "Updated todos", pending: "Updating todos"),
        "vision_analyze": Meta(done: "Analyzed image", pending: "Analyzing image"),
        "web_extract": Meta(done: "Read webpage", pending: "Reading webpage"),
        "web_search": Meta(done: "Searched web", pending: "Searching web"),
        "write_file": Meta(done: "Edited file", pending: "Editing file"),
    ]

    /// A known tool's words; any other is named after itself ("Browser Scroll").
    static func meta(_ name: String) -> Meta {
        if let meta = titles[name] { return meta }
        var short = name
        for prefix in ["browser_", "web_"] where short.hasPrefix(prefix) { short.removeFirst(prefix.count) }
        let words = short.split(separator: "_").map { capitalize(String($0)) }
        let action = words.isEmpty ? name : words.joined(separator: " ")
        for (prefix, label) in [("browser_", "Browser"), ("web_", "Web")] where name.hasPrefix(prefix) {
            return Meta(done: "\(label) \(action)", pending: "Running \(label.lowercased()) \(action.lowercased())")
        }
        return Meta(done: action, pending: "Running \(action.lowercased())")
    }

    /// The title that names what the call acted on, or nil for the tool's own words.
    static func dynamicTitle(_ part: Part, _ args: [String: JSONValue], _ result: [String: JSONValue]) -> String? {
        if let skill = skillTitle(part) { return skill }
        let pending = part.result == nil
        func verb(_ gerund: String, _ past: String) -> String { pending ? gerund : past }

        switch part.name {
        case "web_extract":
            let url = firstURL(.object(args), .object(result))
            return url.isEmpty ? nil : "\(verb("Reading", "Read")) \(hostname(url))"
        case "browser_navigate":
            let url = firstURL(.object(args), .object(result))
            if url.isEmpty { return nil }
            let failed = part.isError || result["success"] == .bool(false) || result["ok"] == .bool(false)
                || !firstString(result, ["error"]).isEmpty
            return "\(failed ? "Failed to open" : verb("Opening", "Opened")) \(hostname(url))"
        case "web_search":
            let query = firstString(args, ["search_term", "query"]).nonEmpty ?? contextValue(.object(args))
            return query.isEmpty ? nil : "\(verb("Searching", "Searched")) “\(compactPreview(query, 48))”"
        case "read_file":
            let target = readFileTarget(args, result)
            return target.isEmpty ? nil : "\(verb("Reading", "Read")) \(target)"
        case "terminal", "execute_code":
            let command = shellCommand(args)
            if command.isEmpty { return nil }
            let action = part.name == "execute_code" ? verb("Scripting", "Ran code") : verb("Running", "Ran")
            let summary = compactPreview(ToolCallSummary.summarizeShellCommand(command), 160)
            return "\(action) \(withoutLeadingAction(summary, action))"
        case "browser_exec":
            return browserExecStepLabel(firstString(args, ["code"]))
        default:
            guard fileEditTools.contains(part.name) else { return nil }
            let path = fileEditPath(args, result)
            return path.isEmpty ? nil : basename(path)
        }
    }

    /// Loading a skill, reading one of its files or listing them (`skill-activity.ts`).
    static func skillTitle(_ part: Part) -> String? {
        guard part.name == "skill_view" || part.name == "skills_list" else { return nil }
        let args = record(part.args)
        let failed = Self.failed(part)
        let pending = part.isPending && part.result == nil
        let missing = !pending && part.result == nil
        let file = firstString(args, ["file_path"])
        let target = [firstString(args, ["name"]), file].filter { !$0.isEmpty }.joined(separator: " → ")
        let words: (pending: String, done: String, failed: String) = part.name == "skills_list"
            ? ("Listing skills", "Listed skills", "Failed to list skills")
            : !file.isEmpty
                ? ("Reading skill resource", "Read skill resource", "Failed to read skill resource")
                : ("Loading skill", "Loaded skill", "Failed to load skill")
        let label = failed ? words.failed : missing ? "Skill result unavailable" : pending ? words.pending : words.done
        return target.isEmpty ? label : "\(label): \(target)"
    }

    /// "notes.md L237-259": the file, and the lines read when the call chose them.
    static func readFileTarget(_ args: [String: JSONValue], _ result: [String: JSONValue]) -> String {
        let inherited = firstString(args, ["context", "preview"])
        if !inherited.isEmpty { return inherited }
        let path = firstString(args, ["path", "file", "filepath"])
        if path.isEmpty { return "" }
        return [basename(path), readFileLines(args, result)].filter { !$0.isEmpty }.joined(separator: " ")
    }

    static func readFileLines(_ args: [String: JSONValue], _ result: [String: JSONValue]) -> String {
        let offset = args["offset"]?.doubleValue
        let limit = args["limit"]?.doubleValue
        if offset == nil, limit == nil { return "" }
        func text(_ value: Double) -> String { numberText(.number(value)) }
        if let offset, offset > 0 {
            guard let limit, limit > 1 else { return "L\(text(offset))" }
            return "L\(text(offset))-\(text(offset + limit - 1))"
        }
        let lines = firstString(result, ["content"]).split(separator: "\n").compactMap { line -> Int? in
            guard let bar = line.firstIndex(of: "|"), bar > line.startIndex else { return nil }
            let digits = line[..<bar]
            return digits.allSatisfy(\.isASCII) && digits.allSatisfy(\.isNumber) ? Int(digits) : nil
        }
        guard let start = lines.first, let end = lines.last else { return "" }
        return start == end ? "L\(start)" : "L\(start)-\(end)"
    }

    /// The command that ran, preferring the argument over the gateway's preview.
    static func shellCommand(_ args: [String: JSONValue]) -> String {
        firstString(args, ["command", "code"]).nonEmpty ?? firstString(args, ["context", "preview"]).nonEmpty
            ?? contextValue(.object(args))
    }

    /// A preview that already opens with the title's verb loses it ("Running grep").
    static func withoutLeadingAction(_ value: String, _ action: String) -> String {
        let verb = action.trimmed
        let text = String(value.drop(while: \.isWhitespace))
        guard !verb.isEmpty, let boundary = text.firstIndex(where: \.isWhitespace) else { return value }
        return text[..<boundary].lowercased() == verb.lowercased()
            ? String(text[boundary...].drop(while: \.isWhitespace))
            : value
    }

    /// `browser_exec` code opens with a `# …` line saying what the step does.
    static func browserExecStepLabel(_ code: String, maxCharacters: Int = 80) -> String? {
        let first = code.trimmed.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first
            .map { String($0).trimmed } ?? ""
        guard first.hasPrefix("#") else { return nil }
        let label = String(first.drop(while: { $0 == "#" })).trimmed
        if label.isEmpty { return nil }
        return label.count > maxCharacters ? String(label.prefix(maxCharacters - 1)) + "…" : label
    }

    static func fileEditPath(_ args: [String: JSONValue], _ result: [String: JSONValue]) -> String {
        firstString(args, ["path", "file", "filepath"]).nonEmpty
            ?? firstString(result, ["path", "file", "filepath", "resolved_path"]).nonEmpty
            ?? htmlPath(inDiff: firstString(result, ["inline_diff", "diff"]))
    }

    static func htmlPath(inDiff diff: String) -> String {
        let cleaned = stripDiffChrome(diff)
        let pattern = #"(?:^|\s)(?:[ab]/)?([^\s]+\.html?)(?=\s|$)"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: cleaned, range: NSRange(cleaned.startIndex..., in: cleaned)),
              let range = Range(match.range(at: 1), in: cleaned)
        else { return "" }
        return String(cleaned[range]).trimmed
    }

    // MARK: Subtitle and detail

    static func subtitle(_ part: Part, _ args: [String: JSONValue], _ result: [String: JSONValue]) -> String {
        switch part.name {
        case "browser_navigate":
            let url = firstString(args, ["url", "target"]).nonEmpty ?? firstString(result, ["url"]).nonEmpty
                ?? firstURL(.object(args), .object(result))
            return url.isEmpty ? "Navigated in browser" : hostname(url)
        case "browser_snapshot":
            let snapshot = firstString(result, ["snapshot"])
            return snapshot.isEmpty ? "Captured a browser accessibility snapshot" : summarizeSnapshot(snapshot)
        case "browser_click":
            let clicked = firstString(result, ["clicked"]).nonEmpty ?? firstString(args, ["ref", "target"])
            if clicked.isEmpty { return "Clicked on page" }
            return clicked.hasPrefix("@") ? "Clicked page element (internal ref \(clicked))" : "Clicked \(clicked)"
        case "browser_fill", "browser_type":
            let field = firstString(args, ["label", "field", "ref", "target"])
            let value = firstString(args, ["value", "text"])
            let parts = [field.isEmpty ? "" : "Field: \(field)", value.isEmpty ? "" : "Value: \(compactPreview(value, 42))"]
            return parts.filter { !$0.isEmpty }.joined(separator: " · ").nonEmpty ?? "Filled page input"
        case "web_search":
            let query = firstString(args, ["search_term", "query"]).nonEmpty ?? contextValue(.object(args))
            return query.isEmpty ? "Queried web sources" : "Query: \(query)"
        case "terminal", "execute_code":
            let source = (firstString(result, ["output", "stdout", "stderr"]).nonEmpty ?? lines(result)).trimmed
            if let line = source.split(separator: "\n").map({ String($0).trimmed }).first(where: { !$0.isEmpty }) {
                return compactPreview(line, 160)
            }
            let command = firstString(args, ["context", "preview", "command", "code"]).nonEmpty ?? contextValue(.object(args))
            return command.isEmpty ? "Executed command" : ""
        case "read_file":
            let path = firstString(args, ["path", "file", "filepath"])
            return path.isEmpty ? fallbackDetail(args, result) : path
        case "web_extract":
            let url = firstString(args, ["url"]).nonEmpty ?? firstString(result, ["url"]).nonEmpty
                ?? firstURL(.object(args), .object(result))
            return url.isEmpty ? "Fetched webpage" : hostname(url)
        case "memory":
            return firstString(result, ["message", "error"])
        case "cronjob":
            return cronSubtitle(args, result)
        default:
            if fileEditTools.contains(part.name) {
                let path = fileEditPath(args, result)
                return path.isEmpty ? (inlineDiff(result).isEmpty ? "" : "Changed file") : path
            }
            return compactPreview(ToolResultText.summary(part.result), 120).nonEmpty
                ?? compactPreview(result, 120).nonEmpty
                ?? compactPreview(args, 120).nonEmpty
                ?? fallbackDetail(args, result)
        }
    }

    static func detailText(_ part: Part, _ args: [String: JSONValue], _ result: [String: JSONValue]) -> String {
        switch part.name {
        case "browser_snapshot":
            let snapshot = firstString(result, ["snapshot"])
            return snapshot.isEmpty ? fallbackDetail(args, result) : summarizeSnapshot(snapshot)
        case "terminal", "execute_code":
            // Split streams are their own sections; this is the merged fallback.
            let output = firstString(result, ["output", "stdout", "stderr"])
            let lines = Self.lines(result)
            if !output.isEmpty || !lines.isEmpty { return [output, lines].filter { !$0.isEmpty }.joined(separator: "\n") }
            // A terminal row shows its command as `$ command` already.
            if part.name == "terminal" { return "" }
        case "web_extract":
            let direct = firstString(result, ["content", "text", "markdown", "body", "summary", "message"])
            if !direct.isEmpty {
                return direct.replacingOccurrences(of: #"\s*in\s+\d+(?:\.\d+)?s\s*$"#, with: "",
                                                   options: [.regularExpression, .caseInsensitive]).trimmed
            }
            let aggregated = (result["results"]?.arrayValue ?? []).map {
                firstString(record($0), ["content", "text", "markdown", "body"])
            }.filter { !$0.isEmpty }.joined(separator: "\n\n---\n\n")
            if !aggregated.isEmpty { return aggregated }
        case "read_file":
            if part.result != nil {
                let content = firstString(result, ["content", "text", "data", "body"])
                if !content.isEmpty { return content }
            }
        case "memory":
            return firstString(result, ["message", "error"])
        case "web_search":
            let detail = fallbackDetail(args, result)
            guard let seconds = number(result["duration_s"]) else { return detail }
            let duration = self.duration(seconds)
            if duration.isEmpty { return detail }
            return detail
                .replacingOccurrences(of: #"(?im)^\s*-\s*Duration\s+S\s*:\s*[-+]?[\d.]+(?:e[-+]?\d+)?\s*$"#,
                                      with: "- Duration: \(duration)", options: .regularExpression)
                .replacingOccurrences(of: #"(?i)\bDuration\s+S\s*:"#, with: "Duration:", options: .regularExpression)
        case "cronjob":
            return cronDetail(args, result)
        default:
            if fileEditTools.contains(part.name) {
                if !inlineDiff(record(part.result)).isEmpty { return "" }
                let summary = firstString(result, ["message", "summary"])
                if !summary.isEmpty { return summary }
                if !fileEditPath(args, result).isEmpty { return "" }
            }
        }
        return fallbackDetail(args, result)
    }

    /// The call's own words for itself, else a summary of its result.
    static func fallbackDetail(_ args: [String: JSONValue], _ result: [String: JSONValue]) -> String {
        let argContext = contextValue(.object(args))
        let resultContext = contextValue(.object(result))
        if !resultContext.isEmpty, resultContext != argContext { return resultContext }
        if !argContext.isEmpty { return argContext }
        // The record always exists here (Desktop's `result !== undefined`).
        return ToolResultText.summary(.object(result))
    }

    static func lines(_ result: [String: JSONValue]) -> String {
        (result["lines"]?.arrayValue ?? []).compactMap(\.stringValue).joined(separator: "\n")
    }

    static func stripDividerLines(_ value: String) -> String {
        value.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { $0.trimmingCharacters(in: .whitespaces).range(of: #"^[-=]{3,}\s*$"#, options: .regularExpression) == nil }
            .joined(separator: "\n").trimmed
    }

    static func looksRedundant(_ title: String, _ detail: String) -> Bool {
        if detail.isEmpty { return true }
        func norm(_ text: String) -> String {
            text.lowercased().replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).trimmed
        }
        return norm(title) == norm(detail)
    }

    static func summarizeSnapshot(_ snapshot: String) -> String {
        func count(_ pattern: String) -> Int {
            (try? NSRegularExpression(pattern: pattern))?
                .numberOfMatches(in: snapshot, range: NSRange(snapshot.startIndex..., in: snapshot)) ?? 0
        }
        let stats = ["\(count(#"button\s+"[^"]+""#)) buttons", "\(count(#"link\s+"[^"]+""#)) links",
                     "\(count(#"(?:textbox|combobox|searchbox)\s+"[^"]+""#)) inputs"].joined(separator: " · ")
        var labels: [String] = []
        if let regex = try? NSRegularExpression(pattern: #"(?:button|link|combobox|textbox)\s+"([^"]+)""#) {
            for match in regex.matches(in: snapshot, range: NSRange(snapshot.startIndex..., in: snapshot)) {
                guard let range = Range(match.range(at: 1), in: snapshot) else { continue }
                let label = String(snapshot[range]).trimmed
                if !label.isEmpty { labels.append(label) }
                if labels.count == 4 { break }
            }
        }
        return labels.isEmpty ? stats : "\(stats)\nTop controls: \(labels.joined(separator: ", "))"
    }

    static func cronSubtitle(_ args: [String: JSONValue], _ result: [String: JSONValue]) -> String {
        if let jobs = result["jobs"]?.arrayValue {
            return jobs.isEmpty ? "No cron jobs" : "\(jobs.count) cron job\(jobs.count == 1 ? "" : "s")"
        }
        let message = firstString(result, ["message"])
        if !message.isEmpty { return message }
        let action = firstString(args, ["action"]).nonEmpty ?? "manage"
        let name = firstString(result, ["name"]).nonEmpty ?? firstString(args, ["name", "job_id"])
        return name.isEmpty ? "Cron \(action)" : "\(capitalize(action)) \(name)"
    }

    static func cronDetail(_ args: [String: JSONValue], _ result: [String: JSONValue]) -> String {
        if let jobs = result["jobs"]?.arrayValue {
            if jobs.isEmpty { return "No cron jobs scheduled" }
            return jobs.prefix(20).map { job in
                let row = record(job)
                let name = firstString(row, ["name", "id"]).nonEmpty ?? "job"
                let schedule = firstString(row, ["schedule_display", "schedule"])
                return schedule.isEmpty ? "- \(name)" : "- \(name) · \(schedule)"
            }.joined(separator: "\n")
        }
        func scalar(_ value: JSONValue?) -> String {
            switch value {
            case .string(let text)?: text.trimmed
            case .number?: numberText(value!)
            default: ""
            }
        }
        let nextRun = scalar(result["next_run_at"])
        let rows = [("Schedule", scalar(result["schedule"])), ("Repeat", scalar(result["repeat"])),
                    ("Delivery", scalar(result["deliver"])), ("Next run", nextRun.isEmpty ? "" : cronTime(nextRun))]
        let lines = rows.filter { !$0.1.isEmpty }.map { "\($0.0): \($0.1)" }
        return lines.isEmpty ? fallbackDetail(args, result) : lines.joined(separator: "\n")
    }

    static func cronTime(_ iso: String) -> String {
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = parser.date(from: iso) ?? ISO8601DateFormatter().date(from: iso) else { return iso }
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("MMMd jj:mm")
        return formatter.string(from: date)
    }

    // MARK: Diffs, counts, search

    static func stripDiffChrome(_ value: String) -> String {
        value.replacingOccurrences(of: #"\x{1B}\[[0-9;]*[A-Za-z]"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"^\s*┊\s*review diff\s*\n"#, with: "", options: [.regularExpression, .caseInsensitive])
            .trimmed
    }

    static func inlineDiff(_ result: [String: JSONValue]) -> String {
        for key in ["inline_diff", "diff"] {
            if let value = result[key]?.stringValue, !value.trimmed.isEmpty { return stripDiffChrome(value) }
        }
        return ""
    }

    static func duration(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "" }
        if seconds < 1 { return "\(max(1, Int((seconds * 1000).rounded())))ms" }
        if seconds < 60 { return String(format: seconds >= 10 ? "%.0fs" : "%.1fs", seconds) }
        let whole = Int(seconds.rounded())
        let minutes = whole / 60, rest = whole % 60
        if minutes < 60 { return rest > 0 ? "\(minutes)m \(rest)s" : "\(minutes)m" }
        let hours = minutes / 60, restMinutes = minutes % 60
        return restMinutes > 0 ? "\(hours)h \(restMinutes)m" : "\(hours)h"
    }

    struct Count: Equatable {
        var count: Int
        var noun: String
    }

    static let countFields: [(key: String, noun: String)] = [
        ("count", ""), ("total", ""), ("result_count", "result"), ("results_count", "result"),
        ("num_results", "result"), ("match_count", "match"), ("matches_count", "match"), ("file_count", "file"),
        ("files_count", "file"), ("item_count", "item"), ("items_count", "item"), ("search_count", "search"),
        ("searches_count", "search"), ("source_count", "source"), ("sources_count", "source"),
        ("document_count", "document"), ("documents_count", "document"), ("updated", "item"), ("added", "item"),
        ("removed", "item"), ("deleted", "item"), ("created", "item"), ("changed", "item"), ("processed", "item"),
        ("steps", "step"),
    ]
    static let countArrays: [(key: String, noun: String)] = [
        ("results", "result"), ("items", "item"), ("matches", "match"), ("files", "file"),
        ("documents", "document"), ("sources", "source"), ("rows", "row"),
    ]
    static let defaultCountNouns = ["browser_snapshot": "item", "list_files": "file", "search_files": "result",
                                    "session_search_recall": "result", "todo": "todo", "todo_list": "todo",
                                    "web_search": "result"]

    static func countValue(_ value: JSONValue?) -> Int? {
        if case .array(let values)? = value { return values.isEmpty ? nil : values.count }
        guard let amount = number(value), amount > 0, amount < 1e15 else { return nil }
        return Int(amount.rounded())
    }

    static func singular(_ noun: String) -> String {
        let word = noun.trimmed.lowercased()
        if word.isEmpty { return "" }
        if word.hasSuffix("ies"), word.count > 3 { return String(word.dropLast(3)) + "y" }
        if word.range(of: "(xes|zes|ches|shes|sses)$", options: .regularExpression) != nil, word.count > 3 {
            return String(word.dropLast(2))
        }
        if word.hasSuffix("s"), word.count > 2, !word.hasSuffix("ss") { return String(word.dropLast()) }
        return word
    }

    static func plural(_ noun: String, _ count: Int) -> String {
        if count == 1 { return noun }
        if noun == "search" { return "searches" }
        if noun.hasSuffix("y"), noun.count > 1, noun.range(of: "[aeiou]y$", options: [.regularExpression, .caseInsensitive]) == nil {
            return String(noun.dropLast()) + "ies"
        }
        if noun.range(of: "(s|x|z|ch|sh)$", options: [.regularExpression, .caseInsensitive]) != nil { return noun + "es" }
        return noun + "s"
    }

    static func count(_ count: Int, _ noun: String) -> Count { Count(count: count, noun: singular(noun).nonEmpty ?? "item") }

    static func countText(_ metric: Count) -> String { "\(metric.count) \(plural(metric.noun, metric.count))" }

    static func countFromRecord(_ record: [String: JSONValue], fallback: String) -> Count? {
        for field in countFields {
            if let value = countValue(record[field.key]) { return count(value, field.noun.nonEmpty ?? fallback) }
        }
        for field in countArrays {
            if let value = countValue(record[field.key]) { return count(value, field.noun) }
        }
        for key in record.keys.sorted() where !["duration_s", "exit_code", "status_code"].contains(key) {
            guard key.range(of: "_count$|_total$", options: [.regularExpression, .caseInsensitive]) != nil,
                  let value = countValue(record[key])
            else { continue }
            let lowered = key.lowercased()
            let stripped = lowered.replacingOccurrences(of: "_(count|total)$", with: "", options: .regularExpression)
                .replacingOccurrences(of: "^num_", with: "", options: .regularExpression)
            return count(value, singular(stripped).nonEmpty ?? fallback)
        }
        return nil
    }

    static func countFromText(_ value: String, fallback: String) -> Count? {
        let text = value.trimmed
        if text.isEmpty { return nil }
        let unit = #"\b(\d+)\s+(results?|items?|files?|matches?|documents?|sources?|searches?|steps?|rows?)\b"#
        let verb = #"\b(?:did|found|returned|listed|searched|matched|updated|created|deleted|processed)\s+(\d+)\b"#
        for (pattern, hasNoun) in [(unit, true), (verb, false)] {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
                  let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                  let digits = Range(match.range(at: 1), in: text), let number = Int(text[digits])
            else { continue }
            guard number > 0 else { return nil }
            let noun = hasNoun ? Range(match.range(at: 2), in: text).map { singular(String(text[$0])) } ?? fallback : fallback
            return count(number, noun)
        }
        return nil
    }

    static func resultCount(_ part: Part, _ args: [String: JSONValue], _ result: [String: JSONValue]) -> Count? {
        guard part.result != nil else { return nil }
        let fallback = defaultCountNouns[part.name] ?? "item"
        func normalized(_ metric: Count) -> Count { part.name == "web_search" ? count(metric.count, "result") : metric }
        if part.name == "web_search" {
            let hits = resultItems(part.result!)
            if !hits.isEmpty { return count(hits.count, "result") }
        }
        // Memory's live total is its `entry_count`.
        if part.name == "memory", let total = countValue(result["entry_count"]) { return count(total, "entry") }
        if let direct = countFromRecord(result, fallback: fallback) { return normalized(direct) }
        if case .object(let payload) = unwrapPayload(part.result!), let nested = countFromRecord(payload, fallback: fallback) {
            return normalized(nested)
        }
        let summary = firstString(result, ["summary", "message", "detail"]).nonEmpty ?? fallbackDetail(args, result)
        return countFromText(summary, fallback: fallback).map(normalized)
    }

    /// The payload under a wrapper key (`data`, `result`, …), or the value itself.
    static func unwrapPayload(_ value: JSONValue) -> JSONValue {
        let row = record(value)
        for key in ToolResultText.wrapperKeys {
            if let payload = row[key], !payload.isNull { return payload }
        }
        return value
    }

    static func resultItems(_ value: JSONValue) -> [JSONValue] {
        if case .array(let values) = value { return values }
        let row = record(value)
        for key in ["web", "results", "search_results", "sources", "web_sources", "items", "organic_results",
                    "organic", "matches", "documents"] {
            switch row[key] {
            case .array(let values)?: return values
            case .object(let nested)?:
                let items = resultItems(.object(nested))
                if !items.isEmpty { return items }
            default: continue
            }
        }
        let payload = unwrapPayload(.object(row))
        return payload == .object(row) ? [] : resultItems(payload)
    }

    static func searchResults(_ result: JSONValue?, limit: Int = 6) -> [SearchHit] {
        guard let result else { return [] }
        return resultItems(result).map { item in
            let row = record(item)
            return SearchHit(title: cleanVisibleText(firstString(row, ["title", "name"])),
                             url: firstString(row, ["url", "href", "link"]),
                             snippet: cleanVisibleText(firstString(row, ["snippet", "description", "body"])))
        }.filter { !$0.title.isEmpty || !$0.url.isEmpty }.prefix(limit).map { $0 }
    }

    /// Model text without fence noise, citation markers or Markdown link syntax
    /// (`cleanVisibleText`); inline code spans are left as they are.
    static func cleanVisibleText(_ text: String) -> String {
        var out = ""
        var rest = Substring(text)
        while let open = rest.firstIndex(of: "`"),
              let close = rest[rest.index(after: open)...].firstIndex(where: { $0 == "`" || $0 == "\n" }),
              rest[close] == "`", close > rest.index(after: open) {
            out += cleanPlain(String(rest[..<open])) + rest[open...close]
            rest = rest[rest.index(after: close)...]
        }
        return out + cleanPlain(String(rest))
    }

    static func cleanPlain(_ text: String) -> String {
        text.replacingOccurrences(of: "`{3,}", with: "", options: .regularExpression)
            .replacingOccurrences(of: #"(?<=[\p{L}\p{N})\].,!?:;"'”’])\[(?:\d+(?:\s*,\s*\d+)*)\](?!\()"#, with: "",
                                  options: .regularExpression)
            .replacingOccurrences(of: #"\[([^\]]+)\]\(([^)\s]+)\)"#, with: "$1 $2", options: .regularExpression)
    }
}
