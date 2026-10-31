import Foundation
import HermesProtocol

/// The task list Hermes's Todo tool keeps for a session (`tools/todo_tool.py`), as the
/// chat shows it above the composer.
///
/// Every Todo tool call answers the whole list and its revision
/// (`{"todos": [{id, content, status, parent?}], "revision": n, "summary": {…}}`,
/// `todo_tool.py:218`), and that result is the tool row's: live from `tool.complete`
/// (always sent for the Todo tool, `tui_gateway/tool_progress.py:365-369`), stored as the
/// tool row's content. So the list is read from the transcript's newest Todo row, and a
/// resumed chat finds it the same way once its newest page is read.
public struct TodoPlan: Sendable, Hashable {
    public enum Status: String, Sendable, Hashable {
        case pending
        case inProgress = "in_progress"
        case completed
        case cancelled
    }

    public struct Item: Sendable, Hashable, Identifiable {
        public var id: String
        public var content: String
        public var status: Status
        /// Another item's id: this one is its subtask.
        public var parent: String?

        public init(id: String, content: String, status: Status, parent: String? = nil) {
            self.id = id
            self.content = content
            self.status = status
            self.parent = parent
        }
    }

    /// One line of the list as shown: subtasks under their parent, one level in per depth.
    public struct Row: Sendable, Hashable, Identifiable {
        public var item: Item
        public var depth: Int
        public var id: String { item.id }
    }

    public var items: [Item]
    public var revision: Int

    public init(items: [Item], revision: Int) {
        self.items = items
        self.revision = revision
    }

    /// The Todo tool's names: `todo_list`, its legacy alias `todo`, and the `tool_call`
    /// bridge stored transcripts keep for deferred tools (`todo_tool.py:288-310`).
    static let toolNames: Set<String> = ["todo_list", "todo", "tool_call"]

    /// Items that count toward the progress: cancelled ones count on neither side, as in
    /// Desktop's `$todoProgressBySession` (`apps/desktop/src/store/todos.ts`).
    public var total: Int { items.count { $0.status != .cancelled } }
    public var completed: Int { items.count { $0.status == .completed } }
    /// No item is pending or in progress.
    public var isFinished: Bool { !items.contains { $0.status == .pending || $0.status == .inProgress } }
    /// The item being worked on, if any.
    public var current: Item? { items.first { $0.status == .inProgress } }

    /// Parents before their subtasks, in list order. A missing or circular parent
    /// leaves the item at the top level (Desktop's `todoTree`).
    public var rows: [Row] {
        let ids = Set(items.map(\.id))
        var children: [String: [Item]] = [:]
        var roots: [Item] = []
        for item in items {
            if let parent = item.parent, parent != item.id, ids.contains(parent) {
                children[parent, default: []].append(item)
            } else {
                roots.append(item)
            }
        }
        var rows: [Row] = []
        var seen: Set<String> = []
        func walk(_ item: Item, _ depth: Int) {
            guard seen.insert(item.id).inserted else { return }
            rows.append(Row(item: item, depth: depth))
            for child in children[item.id] ?? [] { walk(child, depth + 1) }
        }
        for root in roots { walk(root, 0) }
        for item in items where !seen.contains(item.id) {
            seen.insert(item.id)
            rows.append(Row(item: item, depth: 0))
        }
        return rows
    }

    /// A Todo result: the object, or JSON text holding it. Nil for anything else, such as
    /// a tool error. Items without an id, content or known status are left out, as Desktop
    /// does (`parseTodos`).
    public static func parse(_ value: JSONValue?) -> TodoPlan? {
        var value = value
        if let text = value?.stringValue { value = ToolCallView.parseJSON(text) }
        guard let todos = value?["todos"]?.arrayValue,
              let revision = value?["revision"]?.intValue, revision >= 0 else { return nil }
        let items: [Item] = todos.compactMap { todo in
            guard let status = todo["status"]?.stringValue.flatMap(Status.init(rawValue:)),
                  let id = text(todo["id"]), let content = text(todo["content"]) else { return nil }
            return Item(id: id, content: content, status: status, parent: text(todo["parent"]))
        }
        return TodoPlan(items: items, revision: revision)
    }

    private static func text(_ value: JSONValue?) -> String? {
        let text: String? = switch value {
        case .string(let string)?: string
        case .number(let number)?: number.rounded() == number ? String(Int(number)) : String(number)
        default: nil
        }
        return text?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
    }

    /// The list to show above the composer, or nil.
    ///
    /// The newest Todo row's list, while it is the current plan:
    /// - Finished, it stays until the next prompt, then goes.
    /// - Unfinished, it also stays while a turn runs after a later prompt (the agent may
    ///   take it up again). A turn that ended without touching it left it behind, as
    ///   Desktop drops a list still open at turn end (`clearActiveSessionTodos`).
    ///
    /// An empty list (the agent cleared it) shows nothing. Rows not read yet show
    /// nothing either: a resumed chat shows its list once its newest page is in.
    static func current(in items: [TranscriptItem], isRunning: Bool) -> TodoPlan? {
        var promptedSince = false
        for item in items.reversed() {
            switch item.role {
            case .user where !item.isSteer:
                promptedSince = true
            case .tool:
                guard let name = item.tool?.name ?? item.toolName, toolNames.contains(name),
                      item.tool?.phase != .failed,
                      let plan = parse(item.tool?.result) else { continue }
                guard !plan.items.isEmpty, !promptedSince || (isRunning && !plan.isFinished) else { return nil }
                return plan
            default:
                continue
            }
        }
        return nil
    }
}

extension Transcript {
    /// The task list to show above the composer (`TodoPlan.current`).
    public var todoPlan: TodoPlan? { derived.derived.todoPlan(items, isRunning: isRunning) }
}
