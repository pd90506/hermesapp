import Foundation
import HermesProtocol

/// A process the chat's agent started with `terminal(background=true)`, as the gateway's
/// process registry lists it (`process.list`, `tui_gateway/server.py:2055-2070`, entries from
/// `tools/process_registry.py:2393-2420`) and Desktop's status stack shows it
/// (`toBackgroundItem`, `apps/desktop/src/store/composer-status.ts:299-311`).
public struct BackgroundProcess: Sendable, Hashable, Identifiable {
    public enum State: Sendable, Hashable { case running, done, failed }

    /// The registry's process id (`session_id` in its rows: not a chat's id).
    public var id: String
    /// The command's first line, else "background process".
    public var title: String
    public var state: State
    public var exitCode: Int?
    /// The newest output, at most 4000 characters.
    public var output: String?

    public var isRunning: Bool { state == .running }

    public init(id: String, title: String, state: State, exitCode: Int? = nil, output: String? = nil) {
        self.id = id
        self.title = title
        self.state = state
        self.exitCode = exitCode
        self.output = output
    }

    /// A `process.list` row; nil without an id.
    init?(row: JSONValue) {
        guard let id = row["session_id"]?.stringValue, !id.isEmpty else { return nil }
        let exitCode = row["exit_code"]?.intValue
        let exited = row["status"]?.stringValue == "exited"
        let firstLine = (row["command"]?.stringValue ?? "").split(separator: "\n", omittingEmptySubsequences: false)
            .first.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? ""
        self.init(id: id, title: firstLine.isEmpty ? "background process" : firstLine,
                  state: exited ? (exitCode.map { $0 != 0 } == true ? .failed : .done) : .running,
                  exitCode: exitCode, output: row["output_tail"]?.stringValue?.nonEmpty)
    }

    /// Desktop's notification body: the title, its exit code, then the output's last
    /// three lines (`composer-status.ts:339-350`).
    public var alertBody: String {
        var body = title
        if let exitCode { body += " (exit \(exitCode))" }
        let tail = (output ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: "\n", omittingEmptySubsequences: false).suffix(3)
        if !tail.isEmpty, !tail.allSatisfy(\.isEmpty) { body += "\n" + tail.joined(separator: "\n") }
        return body
    }
}

/// The chat's background processes, kept as Desktop keeps them
/// (`reconcileBackgroundProcesses`, `composer-status.ts:318-395`):
/// - rows keep their place; new ones go last;
/// - a finished row goes after a while (4 s, or 12 s when it failed), or at once when
///   the user stops or dismisses it, and a dismissed one never comes back.
public struct BackgroundProcessList: Sendable, Hashable {
    public private(set) var processes: [BackgroundProcess] = []
    private var dismissed: Set<String> = []

    static let successLinger: Duration = .seconds(4)
    static let failureLinger: Duration = .seconds(12)

    public init() {}

    public var running: [BackgroundProcess] { processes.filter(\.isRunning) }

    /// Takes a `process.list` answer. Returns the rows that were running and have now
    /// finished, for a notification.
    @discardableResult
    mutating func reconcile(_ rows: [JSONValue]) -> [BackgroundProcess] {
        var fresh: [String: BackgroundProcess] = [:]
        var order: [String] = []
        for row in rows {
            guard let process = BackgroundProcess(row: row), !dismissed.contains(process.id) else { continue }
            if fresh[process.id] == nil { order.append(process.id) }
            fresh[process.id] = process
        }
        let finished = processes.filter(\.isRunning).compactMap { old in
            fresh[old.id].flatMap { $0.isRunning ? nil : $0 }
        }
        var next = processes.compactMap { fresh.removeValue(forKey: $0.id) }
        next += order.compactMap { fresh[$0] }
        processes = next
        // The registry stops listing ids eventually: forget them then.
        dismissed.formIntersection(rows.compactMap { $0["session_id"]?.stringValue })
        return finished
    }

    /// Drops `id` now, and from every later answer.
    mutating func dismiss(_ id: String) {
        dismissed.insert(id)
        processes.removeAll { $0.id == id }
    }

    /// How long a finished row stays.
    static func linger(_ process: BackgroundProcess) -> Duration {
        process.state == .failed ? failureLinger : successLinger
    }
}
