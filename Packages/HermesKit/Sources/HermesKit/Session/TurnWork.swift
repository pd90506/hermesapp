import Foundation
import HermesProtocol

/// One thing the chat draws: a message, or the work a turn did before its answer.
public enum TranscriptBlock: Sendable, Hashable, Identifiable {
    case item(TranscriptItem)
    case work(TurnWork)

    public var id: String {
        switch self {
        case .item(let item): item.id
        case .work(let work): work.id
        }
    }

    /// The rows the block holds: its message, or the work's rows.
    public var items: [TranscriptItem] {
        switch self {
        case .item(let item): [item]
        case .work(let work): work.items
        }
    }
}

/// Everything a turn did before its answer, in three layers, as the user asked
/// (2026-10-18):
/// 1. one line, "Completed in 45s" once the turn is done, with the answer under it;
/// 2. opened, the turn's commentary and its groups of steps ("Ran commands");
/// 3. a group opened, its steps one line each ("Bash · git status", "Think · …"), each
///    opening in place to the command and its output, or the whole reasoning.
///
/// Calls Desktop draws as cards (a question for the user, delegated tasks) keep a row of
/// their own in the second layer.
public struct TurnWork: Sendable, Hashable, Identifiable {
    public enum Entry: Sendable, Hashable, Identifiable {
        /// Text the model wrote between its steps (its reasoning is a step).
        case commentary(TranscriptItem)
        case group(StepGroup)
        /// A call drawn as its own card.
        case card(TranscriptItem)

        public var id: String {
            switch self {
            case .commentary(let item), .card(let item): item.id
            case .group(let group): group.id
            }
        }
    }

    public let id: String
    /// The rows the work holds, in order. The answer is not one of them, though its
    /// reasoning is a step here.
    public var items: [TranscriptItem]
    public var entries: [Entry]
    /// The turn is still working and nothing has come after the work.
    public var isLive: Bool
    /// When the turn (or the part of it after a steer) began: the row before the work.
    public var startedAt: Date?
    /// When it ended: the answer's row, else the work's last row. Stored rows carry
    /// their time; live ones don't, so a turn that just ended here has none until the
    /// newest rows are read again.
    public var endedAt: Date?
    /// The turn was stopped before it answered.
    public var wasInterrupted: Bool

    public init(id: String, items: [TranscriptItem], entries: [Entry], isLive: Bool,
                startedAt: Date? = nil, endedAt: Date? = nil, wasInterrupted: Bool = false) {
        self.id = id
        self.items = items
        self.entries = entries
        self.isLive = isLive
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.wasInterrupted = wasInterrupted
    }

    /// How long the work took, when both ends are known.
    public var duration: TimeInterval? {
        guard let startedAt, let endedAt, endedAt >= startedAt else { return nil }
        return endedAt.timeIntervalSince(startedAt)
    }

    /// The settled line: "Completed in 45s", "Stopped after 1m 05s", or without a time
    /// when it is not known.
    public static func settledTitle(duration: TimeInterval?, interrupted: Bool) -> String {
        let verb = interrupted ? "Stopped after" : "Completed in"
        guard let duration else { return interrupted ? "Stopped" : "Completed" }
        let start = Date(timeIntervalSinceReferenceDate: 0)
        return "\(verb) \(Transcript.Waiting.elapsedText(from: start, to: start.addingTimeInterval(duration)))"
    }
}

/// Consecutive steps of a turn's work under one row, named after what its calls did.
public struct StepGroup: Sendable, Hashable, Identifiable {
    public let id: String
    public var steps: [WorkStep]
    /// The work is live and this is its last group.
    public var isLive: Bool

    public init(id: String, steps: [WorkStep], isLive: Bool) {
        self.id = id
        self.steps = steps
        self.isLive = isLive
    }

    public var tools: [TranscriptItem] {
        steps.compactMap { if case .tool(let item) = $0 { item } else { nil } }
    }

    /// "Ran commands, read files", "Analysis completed" (`ToolCallSummary.groupTitle`).
    public var title: String { ToolCallSummary.groupTitle(tools, live: isLive) }
    /// The calls counted, as Desktop's run line reads: "Ran 5 commands, explored 3 files".
    public var summary: String { ToolCallSummary.run(tools, live: isLive) }
    /// The tool whose icon the row shows: its first call's, or none for reasoning alone.
    public var iconTool: String? { tools.first.map(ToolCallSummary.name(of:)) }
}

/// One step of a turn's work: a row's reasoning, or a tool call.
public enum WorkStep: Sendable, Hashable, Identifiable {
    /// The row's reasoning (`reasoning`); the row's text is not part of the step.
    case think(TranscriptItem)
    case tool(TranscriptItem)

    public var id: String {
        switch self {
        case .think(let item): "think-" + item.id
        case .tool(let item): item.id
        }
    }

    public var item: TranscriptItem {
        switch self {
        case .think(let item), .tool(let item): item
        }
    }

    /// Still being written or run.
    public var isLive: Bool {
        switch self {
        case .think(let item): item.isActive && !item.hasReplyText
        case .tool(let item): item.isActive
        }
    }

    public var toolName: String? {
        if case .tool(let item) = self { return ToolCallSummary.name(of: item) }
        return nil
    }

    /// The step's kind as its line starts: "Think", "Bash", "Read".
    public var kind: String {
        guard let name = toolName else { return "Think" }
        if let kind = Self.kinds[name] { return kind }
        if name.hasPrefix("browser_") { return "Browser" }
        return name
    }

    static let kinds: [String: String] = [
        "terminal": "Bash", "execute_code": "Python", "process_manage": "Process",
        "read_file": "Read", "list_files": "List", "search_files": "Search",
        "write_file": "Write", "edit_file": "Edit", "patch": "Patch",
        "web_search": "Web search", "web_extract": "Fetch", "vision_analyze": "Vision",
        "image_generate": "Image", "skill_view": "Skill", "skills_list": "Skills",
        "memory": "Memory", "todo": "Todo", "clarify": "Ask", "delegate_task": "Delegate",
        "cronjob": "Cron", "session_search_recall": "Recall",
    ]

    /// What the step was about, on one line: the reasoning's first line, the command,
    /// the path, query or address the call acted on, else the call's title.
    public var summary: String {
        switch self {
        case .think(let item):
            return Self.firstLine(item.reasoning, plain: true)
        case .tool(let item):
            let args = ToolCallSummary.arguments(of: item)
            let name = ToolCallSummary.name(of: item)
            let context = item.tool?.context ?? item.detail
            let value: String?
            switch name {
            case "terminal": value = ToolCallSummary.firstString(args, ["command"]) ?? context
            case "execute_code": value = ToolCallSummary.firstString(args, ["code"]) ?? context
            default:
                value = ToolCallSummary.firstString(args, ["path", "file_path", "file", "filepath", "query",
                                                           "search_term", "pattern", "url", "name"])
                    ?? ToolCallSummary.firstURL(in: .object(args))
            }
            return value.map { Self.firstLine($0) } ?? ToolCallView(item).title
        }
    }

    /// `terminal`'s working folder for this call (`workdir`, `tools/terminal_tool.py`),
    /// when it named one.
    public var workdir: String? {
        guard case .tool(let item) = self, toolName == "terminal" else { return nil }
        return ToolCallSummary.firstString(ToolCallSummary.arguments(of: item), ["workdir"])
    }

    /// What the step's Copy button takes: the whole command or code, the whole
    /// reasoning, else the call's output.
    public var copyText: String {
        switch self {
        case .think(let item):
            return item.reasoning
        case .tool(let item):
            let view = ToolCallView(item)
            if let command = view.terminalCommand, !command.isEmpty { return command }
            if let code = ToolCallSummary.firstString(ToolCallSummary.arguments(of: item), ["code"]) { return code }
            return view.detail.isEmpty ? view.title : view.detail
        }
    }

    /// The first line with text; with `plain`, without its Markdown marks (a heading's
    /// `#`, a list bullet, a quote's `>`, bold stars).
    static func firstLine(_ text: String, plain: Bool = false) -> String {
        guard let line = text.split(whereSeparator: \.isNewline)
            .map({ $0.trimmingCharacters(in: .whitespaces) }).first(where: { !$0.isEmpty })
        else { return "" }
        guard plain else { return line }
        return line.replacingOccurrences(of: #"^(#{1,6}\s+|[-*+]\s+|>\s*)"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "__", with: "")
    }
}

extension TranscriptItem {
    /// The row without its reasoning, for where its reasoning is drawn as a step.
    public var withoutReasoning: TranscriptItem {
        var item = self
        item.reasoning = ""
        return item
    }
}

extension Transcript {
    /// The transcript as the chat draws it (`TranscriptGrouping.blocks`).
    public var blocks: [TranscriptBlock] { derived.derived.blocks(items, isRunning: isRunning) }

    /// The id of the block that draws `itemID` now, or nil when no block holds it.
    /// A block's id can change when an older page lands (a turn's work is named after
    /// its first row, and the page can hold earlier rows of the same turn), so the chat
    /// keeps its place by a row's id and finds that row's block after the page.
    public func blockID(containing itemID: String) -> String? {
        TranscriptGrouping.blockID(containing: itemID, in: blocks)
    }
}

public enum TranscriptGrouping {
    /// The id of the block in `blocks` that holds the row `itemID`.
    public static func blockID(containing itemID: String, in blocks: [TranscriptBlock]) -> String? {
        blocks.first { $0.items.contains { $0.id == itemID } }?.id
    }

    /// Splits the items into turns (a user row starts one; a steer joins the running
    /// turn) and folds each turn's work before its answer into one block (`TurnWork`).
    public static func blocks(_ items: [TranscriptItem], isRunning: Bool) -> [TranscriptBlock] {
        Tracing.measure("Transcript grouping") { group(items, isRunning: isRunning) }
    }

    private static func group(_ items: [TranscriptItem], isRunning: Bool) -> [TranscriptBlock] {
        var turns: [[TranscriptItem]] = []
        for item in items {
            if turns.isEmpty || (item.role == .user && !item.isSteer) {
                turns.append([item])
            } else {
                turns[turns.count - 1].append(item)
            }
        }
        return turns.enumerated().flatMap { index, turn in
            turnBlocks(turn, live: isRunning && index == turns.count - 1)
        }
    }

    /// The turn's answer: its last assistant row with text (or that was interrupted)
    /// that no tool call follows. Commentary (`isInterim`) is never the answer.
    static func answerIndex(_ turn: [TranscriptItem]) -> Int? {
        let lastTool = turn.lastIndex { $0.role == .tool }
        guard let index = turn.lastIndex(where: { row in
            row.role == .assistant && !row.isInterim && (row.hasReplyText || row.outcome == "interrupted")
        }) else { return nil }
        if let lastTool, lastTool > index { return nil }
        return index
    }

    /// The turn's rows as blocks: its prompt, its work before the answer as one block,
    /// then the answer (without its reasoning, which is the work's last step). A steer
    /// or a local row in the middle keeps its place and splits the work around it.
    static func turnBlocks(_ turn: [TranscriptItem], live: Bool) -> [TranscriptBlock] {
        let answer = answerIndex(turn)
        var blocks: [TranscriptBlock] = []
        var span: [TranscriptItem] = []
        var spanStart: Date?
        var previousStamp: Date?

        func flush(endingAt end: Int, answer: TranscriptItem?) {
            defer { span = [] }
            let laterOutput = turn[end...].contains { !$0.isBlankReply }
            let isLive = live && answer == nil && !laterOutput
            var entries = entries(span, answerReasoning: answer)
            if isLive, case .group(var group)? = entries.last {
                group.isLive = true
                entries[entries.count - 1] = .group(group)
            }
            guard !entries.isEmpty, let first = span.first ?? answer else {
                blocks += span.map { .item($0) }
                return
            }
            let ended = answer?.timestamp ?? span.last { $0.timestamp != nil }?.timestamp
            blocks.append(.work(TurnWork(id: "work-" + first.id, items: span, entries: entries, isLive: isLive,
                                         startedAt: spanStart, endedAt: isLive ? nil : ended,
                                         wasInterrupted: answer?.outcome == "interrupted")))
        }

        for (index, row) in turn.enumerated() {
            if index == answer {
                flush(endingAt: index + 1, answer: row)
                blocks.append(.item(row.withoutReasoning))
            } else if (row.role == .assistant || row.role == .tool) && answer.map({ index < $0 }) ?? true {
                if span.isEmpty { spanStart = previousStamp }
                span.append(row)
            } else {
                flush(endingAt: index, answer: nil)
                blocks.append(.item(row))
            }
            previousStamp = row.timestamp ?? previousStamp
        }
        flush(endingAt: turn.count, answer: nil)
        return blocks
    }

    /// The work's second layer: commentary, cards, and the steps between them in groups.
    /// A row's text comes before its reasoning and calls, which start the next group.
    static func entries(_ span: [TranscriptItem], answerReasoning answer: TranscriptItem?) -> [TurnWork.Entry] {
        var entries: [TurnWork.Entry] = []
        var steps: [WorkStep] = []
        func close() {
            guard let first = steps.first else { return }
            entries.append(.group(StepGroup(id: "group-" + first.id, steps: steps, isLive: false)))
            steps = []
        }
        for row in span {
            switch row.role {
            case .assistant:
                if row.hasReplyText {
                    close()
                    entries.append(.commentary(row.withoutReasoning))
                }
                if !row.reasoning.isEmpty { steps.append(.think(row)) }
            case .tool:
                if row.isCardTool {
                    close()
                    entries.append(.card(row))
                } else {
                    steps.append(.tool(row))
                }
            default:
                break
            }
        }
        if let answer, !answer.reasoning.isEmpty { steps.append(.think(answer)) }
        close()
        return entries
    }
}
