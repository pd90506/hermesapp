import Foundation
import HermesProtocol

/// A child agent the chat's turn delegated work to (`delegate_task`), as Desktop's status
/// stack shows it above the composer (`apps/desktop/src/store/subagents.ts`).
public struct SubagentRun: Sendable, Hashable, Identifiable {
    public enum Status: String, Sendable, Hashable {
        case queued, running, completed, failed, interrupted

        public var isLive: Bool { self == .queued || self == .running }

        /// Desktop's `asStatus`: timeouts and errors failed, cancellations interrupted.
        /// A `subagent.complete` is terminal, so an unknown or live status there failed;
        /// a live event's unknown status is running.
        init(_ value: String?, terminal: Bool) {
            switch value {
            case "completed": self = .completed
            case "failed", "timeout", "error": self = .failed
            case "interrupted", "cancelled", "canceled": self = .interrupted
            case "queued" where !terminal: self = .queued
            default: self = terminal ? .failed : .running
            }
        }
    }

    /// A line of what the child did: a tool call, a progress note, its thinking, or its
    /// final summary.
    public struct Activity: Sendable, Hashable {
        public enum Kind: Sendable, Hashable { case tool, progress, thinking, summary }
        public var kind: Kind
        public var text: String
        public var isError: Bool
    }

    /// `subagent_id`, else Desktop's fallback key from the parent, index and goal.
    public var id: String
    public var parentID: String?
    public var goal: String
    public var model: String?
    public var status: Status
    /// Its place in a batch of children spawned together (`delegation_id`).
    public var delegationID: String?
    public var taskIndex: Int
    public var taskCount: Int
    public var startedAt: Date
    public var updatedAt: Date
    public var durationSeconds: Double?
    public var toolCount: Int?
    /// The tool it is running, while it runs.
    public var currentTool: String?
    /// The newest lines, oldest first, at most `SubagentRoster.activityLimit`.
    public var activity: [Activity]
    public var summary: String?
    /// The child's own stored session id.
    public var childSessionID: String?

    public var isLive: Bool { status.isLive }
}

/// The chat's subagents: fed by the `subagent.*` events of its runtime session
/// (`tui_gateway/tool_progress.py:457-499`) and reconciled with `subagent.list`
/// (`tui_gateway/methods_subagents.py:53-63`), as Desktop's store does.
///
/// - Only `subagent.spawn_requested` and `subagent.start` add a row; other events update
///   one already there.
/// - A finished row keeps its status: later events and snapshots never revive it.
/// - The next prompt (`message.start`) drops the finished rows; running children
///   outlive the turn that spawned them.
public struct SubagentRoster: Sendable, Hashable {
    public private(set) var runs: [SubagentRun] = []
    /// Finished rows already dropped, which a late event or snapshot must not bring back.
    private var retired: Set<String> = []

    static let activityLimit = 24
    static let previewLimit = 220
    static let toolPreviewLimit = 96

    public init() {}

    /// The children still queued or running, the oldest first.
    public var live: [SubagentRun] {
        runs.filter(\.isLive).sorted { ($0.startedAt, $0.taskIndex) < ($1.startedAt, $1.taskIndex) }
    }

    /// Applies a `subagent.*` event. Answers whether it was one.
    @discardableResult
    public mutating func apply(_ event: GatewayEvent, now: Date = Date()) -> Bool {
        guard event.type.hasPrefix("subagent.") else { return false }
        let payload = event.payload ?? .object([:])
        let id = Self.id(of: payload)
        guard !retired.contains(id) else { return true }
        let index = runs.firstIndex { $0.id == id }
        if let index {
            guard runs[index].isLive else { return true }
            runs[index] = Self.project(payload, previous: runs[index], eventType: event.type, now: now)
        } else if event.type == "subagent.spawn_requested" || event.type == "subagent.start" {
            runs.append(Self.project(payload, previous: nil, eventType: event.type, now: now))
        }
        return true
    }

    /// Drops the finished rows (Desktop's `pruneFinishedSessionSubagents`).
    public mutating func pruneFinished() {
        for run in runs where !run.isLive { retired.insert(run.id) }
        runs.removeAll { !$0.isLive }
    }

    /// Drops every row: the turn was stopped, which stops its children.
    public mutating func clear() {
        for run in runs { retired.insert(run.id) }
        runs = []
    }

    /// Reconciles a `subagent.list` answer: live rows it no longer lists are gone, rows it
    /// lists are added or updated, finished rows stay. The activity already shown stays;
    /// a row with none yet shows the last tool the roster names.
    public mutating func reconcile(_ snapshot: [JSONValue], now: Date = Date()) {
        let ids = Set(snapshot.compactMap { $0["subagent_id"]?.stringValue })
        runs.removeAll { $0.isLive && !ids.contains($0.id) }
        for payload in snapshot {
            guard let id = payload["subagent_id"]?.stringValue, !id.isEmpty, !retired.contains(id) else { continue }
            let index = runs.firstIndex { $0.id == id }
            if let index, !runs[index].isLive { continue }
            let previous = index.map { runs[$0] }
            var run = Self.project(payload, previous: previous, eventType: "", now: now)
            if let started = payload["started_at"]?.doubleValue, started > 0 {
                run.startedAt = Date(timeIntervalSince1970: started)
            }
            run.updatedAt = previous?.updatedAt ?? run.startedAt
            if run.activity.isEmpty, let tool = payload["last_tool"]?.stringValue, !tool.isEmpty {
                run.activity = [.init(kind: .tool, text: Self.toolText(tool, preview: ""), isError: false)]
            }
            if let index { runs[index] = run } else { runs.append(run) }
        }
    }

    // MARK: Projection (Desktop's `toProgress`)

    static func id(of payload: JSONValue) -> String {
        if let id = payload["subagent_id"]?.stringValue, !id.isEmpty { return id }
        let parent = payload["parent_id"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 } ?? "root"
        return "\(parent):\(payload["task_index"]?.intValue ?? 0):\(payload["goal"]?.stringValue ?? "")"
    }

    static func project(_ payload: JSONValue, previous: SubagentRun?, eventType: String, now: Date) -> SubagentRun {
        func text(_ key: String) -> String? {
            payload[key]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
        }
        let status = SubagentRun.Status(text("status"), terminal: eventType == "subagent.complete")
        let timeout = text("status") == "timeout"
            ? "Timed out after \(payload["duration_seconds"]?.doubleValue.map { String(format: "%.0f", $0) } ?? "?")s"
            : nil
        var activity = previous?.activity ?? []
        for line in lines(payload, status: status, eventType: eventType, timeout: timeout) {
            if let last = activity.last, last == line { continue }
            activity.append(line)
        }
        if activity.count > activityLimit { activity.removeFirst(activity.count - activityLimit) }
        return SubagentRun(
            id: previous?.id ?? id(of: payload),
            parentID: text("parent_id") ?? previous?.parentID,
            goal: text("goal") ?? previous?.goal ?? "Subagent",
            model: text("model") ?? previous?.model,
            status: status,
            delegationID: text("delegation_id") ?? previous?.delegationID,
            taskIndex: payload["task_index"]?.intValue ?? previous?.taskIndex ?? 0,
            taskCount: payload["task_count"]?.intValue ?? previous?.taskCount ?? 1,
            startedAt: previous?.startedAt ?? now,
            updatedAt: now,
            durationSeconds: payload["duration_seconds"]?.doubleValue ?? previous?.durationSeconds,
            toolCount: payload["tool_count"]?.intValue ?? previous?.toolCount,
            currentTool: status.isLive ? (text("tool_name") ?? previous?.currentTool) : nil,
            activity: activity,
            summary: text("summary") ?? timeout ?? previous?.summary,
            childSessionID: text("child_session_id") ?? previous?.childSessionID)
    }

    private static func lines(_ payload: JSONValue, status: SubagentRun.Status, eventType: String,
                              timeout: String?) -> [SubagentRun.Activity] {
        var out: [SubagentRun.Activity] = []
        let isError = payload["error"].map { $0 != .null && $0 != .bool(false) } ?? false
        let tool = payload["tool_name"]?.stringValue ?? ""
        let preview = payload["tool_preview"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
            ?? payload["text"]?.stringValue ?? ""
        let text = compact(payload["text"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 } ?? preview)
        for tail in payload["output_tail"]?.arrayValue ?? [] {
            let tailTool = tail["tool"]?.stringValue ?? ""
            let tailPreview = tail["preview"]?.stringValue ?? ""
            let line = tailTool.isEmpty ? compact(tailPreview) : toolText(tailTool, preview: tailPreview)
            if !line.isEmpty {
                out.append(.init(kind: tailTool.isEmpty ? .progress : .tool, text: line,
                                 isError: tail["is_error"]?.boolValue == true))
            }
        }
        if !tool.isEmpty { out.append(.init(kind: .tool, text: toolText(tool, preview: preview), isError: isError)) }
        if eventType == "subagent.progress", !text.isEmpty { out.append(.init(kind: .progress, text: text, isError: isError)) }
        if eventType == "subagent.thinking", !text.isEmpty { out.append(.init(kind: .thinking, text: text, isError: false)) }
        let summary = compact(payload["summary"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
                              ?? payload["text"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 } ?? timeout ?? "")
        if !status.isLive, !summary.isEmpty {
            out.append(.init(kind: .summary, text: summary, isError: status == .failed))
        }
        return out
    }

    /// One line, at most `limit` characters.
    static func compact(_ text: String, limit: Int = previewLimit) -> String {
        let line = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return line.count > limit ? String(line.prefix(limit - 1)) + "…" : line
    }

    /// `web_search` with its preview as `Web Search("…")`, as Desktop's `formatTool`.
    static func toolText(_ name: String, preview: String) -> String {
        let label = name.split(separator: "_").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
        let snippet = compact(preview, limit: toolPreviewLimit)
        let shown = label.isEmpty ? name : label
        return snippet.isEmpty ? shown : "\(shown)(\"\(snippet)\")"
    }
}
