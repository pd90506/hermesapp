import Foundation
import HermesProtocol

/// A scheduled job, as `GET /api/cron/jobs?profile=` lists it (`cron/jobs.py::create_job`,
/// `hermes_cli/web_routers/cron.py:110-152`). Read field by field, so a field of an
/// unexpected type drops that field, not the whole list.
public struct CronJob: Sendable, Hashable, Identifiable, Decodable {
    public var id: String
    public var name: String?
    public var prompt: String?
    public var script: String?
    /// The script is the whole job: no agent, so no run sessions, only output documents.
    public var noAgent: Bool
    /// Comma-separated delivery targets (`local`, `origin`, `bot-chat`, `telegram:123`, …).
    public var deliver: String?
    public var enabled: Bool
    /// `scheduled`, `running`, `paused`, `completed`, `error`, … (open set).
    public var state: String?
    /// The schedule as written for people (`"every 2h"`, `"0 9 * * *"`).
    public var scheduleDisplay: String?
    public var nextRunAt: Date?
    public var lastRunAt: Date?
    /// `ok`, `error`, `delivery_failed`, `blocked_config`, … (open set).
    public var lastStatus: String?
    public var lastError: String?
    public var lastDeliveryError: String?
    public var pausedReason: String?
    /// The schedule as the editor takes it back: the cron expression, else the display
    /// form (`"every 2h"`), which the scheduler parses too (`apps/desktop/src/app/cron/index.tsx::jobScheduleExpr`).
    public var scheduleExpression: String?
    /// The job's own model and provider, when it pins one; `nil` follows the default.
    public var model: String?
    public var provider: String?

    public init(id: String, name: String? = nil, prompt: String? = nil, script: String? = nil,
                noAgent: Bool = false, deliver: String? = nil, enabled: Bool = true, state: String? = nil,
                scheduleDisplay: String? = nil, nextRunAt: Date? = nil, lastRunAt: Date? = nil,
                lastStatus: String? = nil, lastError: String? = nil, lastDeliveryError: String? = nil,
                pausedReason: String? = nil, scheduleExpression: String? = nil, model: String? = nil,
                provider: String? = nil) {
        self.id = id
        self.name = name
        self.prompt = prompt
        self.script = script
        self.noAgent = noAgent
        self.deliver = deliver
        self.enabled = enabled
        self.state = state
        self.scheduleDisplay = scheduleDisplay
        self.nextRunAt = nextRunAt
        self.lastRunAt = lastRunAt
        self.lastStatus = lastStatus
        self.lastError = lastError
        self.lastDeliveryError = lastDeliveryError
        self.pausedReason = pausedReason
        self.scheduleExpression = scheduleExpression ?? scheduleDisplay
        self.model = model
        self.provider = provider
    }

    public init(from decoder: any Decoder) throws {
        let json = try JSONValue(from: decoder)
        guard let id = json["id"]?.stringValue ?? json["job_id"]?.stringValue else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "cron job without an id"))
        }
        func text(_ key: String) -> String? {
            guard let value = json[key]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
                !value.isEmpty else { return nil }
            return value
        }
        self.id = id
        name = text("name")
        prompt = text("prompt")
        script = text("script")
        if case .bool(let value) = json["no_agent"] { noAgent = value } else { noAgent = false }
        // Stored as a string; a list is joined the way the scheduler splits it.
        if case .array(let items) = json["deliver"] {
            deliver = items.compactMap(\.stringValue).joined(separator: ",")
        } else {
            deliver = text("deliver")
        }
        if case .bool(let value) = json["enabled"] { enabled = value } else { enabled = true }
        state = text("state")
        scheduleDisplay = text("schedule_display") ?? json["schedule"]?["display"]?.stringValue
            ?? json["schedule"]?["expr"]?.stringValue ?? json["schedule"]?.stringValue
        nextRunAt = text("next_run_at").flatMap(CronDate.parse)
        lastRunAt = text("last_run_at").flatMap(CronDate.parse)
        lastStatus = text("last_status")
        lastError = text("last_error")
        lastDeliveryError = text("last_delivery_error")
        pausedReason = text("paused_reason")
        scheduleExpression = json["schedule"]?["expr"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 } ?? scheduleDisplay
        model = text("model")
        provider = text("provider")
    }

    /// A script that runs without an agent: no prompt needed, and no model to pick
    /// (`jobIsScriptOnly`, `apps/desktop/src/app/cron/cron-job-model.ts:8-10`).
    public var isScriptOnly: Bool { noAgent && script != nil }

    /// Desktop's `jobTitle`: the name, else the start of the prompt, else of the
    /// script, else the id (`apps/desktop/src/app/cron/job-state.ts:38-46`).
    public var title: String {
        name ?? prompt.map { Self.truncated($0, 60) } ?? script.map { Self.truncated($0, 60) } ?? id
    }

    /// The stated state, else one from `enabled` (`job-state.ts:16-20`).
    public var effectiveState: String {
        state ?? (enabled ? "scheduled" : "disabled")
    }

    public var isPaused: Bool { effectiveState == "paused" }
    public var isRunning: Bool { effectiveState == "running" }

    /// States in which the job is not waiting to fire.
    public var isInactive: Bool {
        ["completed", "disabled", "error", "paused"].contains(effectiveState)
    }

    /// When `next_run_at` passed more than 15 minutes ago, the sign of a scheduler that
    /// stopped ticking: never shown as an upcoming run (`job-state.ts:48-69`,
    /// `hermes_cli/cron.py::_OVERDUE_GRACE_SECONDS`).
    public func overdueSince(now: Date = Date()) -> Date? {
        guard !["paused", "completed", "disabled"].contains(effectiveState), let next = nextRunAt,
            now.timeIntervalSince(next) > 15 * 60
        else { return nil }
        return next
    }

    /// The job's delivery targets, `local` when it names none (`cron-job-model.ts:84-91`).
    public var deliveryTargets: [String] { Self.parseTargets(deliver) }

    /// Whether the job's output lands in a Bot Chat (`bot-chat` or `bot-chat:<profile>`).
    public var deliversToBotChat: Bool {
        deliveryTargets.contains { $0 == CronDeliveryTarget.botChat || $0.hasPrefix(CronDeliveryTarget.botChat + ":") }
    }

    /// The comma list of targets, unique, in order; `["local"]` when empty.
    public static func parseTargets(_ value: String?) -> [String] {
        var seen = Set<String>()
        let targets = (value ?? "").split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
        return targets.isEmpty ? ["local"] : targets
    }

    /// `deliver` with `target` turned on or off. The last target stays: a job always
    /// delivers somewhere (`toggleCronDeliveryTarget`, `cron-job-model.ts:93-105`).
    public func deliver(toggling target: String, on: Bool) -> String {
        let targets = deliveryTargets
        if on { return (targets.contains(target) ? targets : targets + [target]).joined(separator: ",") }
        guard targets.contains(target), targets.count > 1 else { return targets.joined(separator: ",") }
        return targets.filter { $0 != target }.joined(separator: ",")
    }

    /// Soonest next run first, jobs with none last, then by title (Desktop's sidebar
    /// order, `cron-jobs-section.tsx:154-175`).
    public static func listOrder(_ jobs: [CronJob]) -> [CronJob] {
        jobs.sorted { a, b in
            switch (a.nextRunAt, b.nextRunAt) {
            case let (x?, y?) where x != y: return x < y
            case (nil, _?): return false
            case (_?, nil): return true
            default: return a.title.localizedStandardCompare(b.title) == .orderedAscending
            }
        }
    }

    static func truncated(_ value: String, _ max: Int) -> String {
        value.count > max ? String(value.prefix(max)) + "…" : value
    }
}

/// A run of a job, from `GET /api/cron/jobs/{id}/runs`: the run's session row (the shape
/// of `/api/sessions`), or for a script-only job a row for its output document
/// (`source: "cron_output"`, `hermes_cli/web_routers/cron.py:262-280,346-445`).
public struct CronRun: Sendable, Hashable, Identifiable, Decodable {
    public var id: String
    public var title: String?
    public var preview: String?
    /// Unix seconds.
    public var startedAt: Double?
    public var lastActive: Double?
    public var endedAt: Double?
    public var source: String?
    /// The job's owning profile, stamped by the dashboard.
    public var profile: String?
    public var messageCount: Int?

    public init(id: String, title: String? = nil, preview: String? = nil, startedAt: Double? = nil,
                lastActive: Double? = nil, endedAt: Double? = nil, source: String? = "cron",
                profile: String? = nil, messageCount: Int? = nil) {
        self.id = id
        self.title = title
        self.preview = preview
        self.startedAt = startedAt
        self.lastActive = lastActive
        self.endedAt = endedAt
        self.source = source
        self.profile = profile
        self.messageCount = messageCount
    }

    public init(from decoder: any Decoder) throws {
        let json = try JSONValue(from: decoder)
        guard let id = json["id"]?.stringValue else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "cron run without an id"))
        }
        self.id = id
        title = json["title"]?.stringValue
        preview = json["preview"]?.stringValue
        startedAt = json["started_at"]?.doubleValue
        lastActive = json["last_active"]?.doubleValue
        endedAt = json["ended_at"]?.doubleValue
        source = json["source"]?.stringValue
        profile = json["profile"]?.stringValue
        messageCount = json["message_count"]?.intValue
    }

    /// A script-only run's output document: there is no session to open.
    public var isOutputDocument: Bool {
        source == "cron_output" || id.hasPrefix("cron_output:")
    }

    /// When the run was last active, else when it started (`cron-jobs-section.tsx:504`).
    public var time: Date? {
        (lastActive ?? startedAt).flatMap { $0 > 0 ? Date(timeIntervalSince1970: $0) : nil }
    }

    /// The run's session, to open it as a chat of `profile`.
    public func historyEntry(profile fallback: String) -> HistoryEntry {
        HistoryEntry(profile: profile ?? fallback,
                     summary: SessionSummary(id: id, title: title, preview: preview, startedAt: startedAt,
                                             messageCount: messageCount, source: source ?? "cron"))
    }

    /// The scheduler names every agent run `cron_{job_id}_{YYYYmmdd_HHMMSS}`
    /// (`apps/desktop/src/app/cron/open-cron-run.ts:14-15`).
    public static func isRunSessionID(_ id: String?) -> Bool {
        guard let id, id.hasPrefix("cron_"), id.count > "cron_".count + 16 else { return false }
        let tail = Array(id.suffix(16))
        return tail[0] == "_" && tail[9] == "_"
            && tail[1...8].allSatisfy(\.isASCIIDigit) && tail[10...15].allSatisfy(\.isASCIIDigit)
    }
}

/// Where a job can deliver, from `GET /api/cron/delivery-targets`: `local` plus the
/// configured gateway platforms (`hermes_cli/web_routers/cron.py:688-711`).
public struct CronDeliveryTarget: Sendable, Hashable, Identifiable, Decodable {
    /// The profile's own Bot Chat. The targets endpoint doesn't list it; Desktop's
    /// routine dialog offers it itself (`apps/desktop/src/plugins/hermes-bots/cron.tsx:1033-1040`).
    public static let botChat = "bot-chat"

    public var id: String
    public var name: String
    /// A platform without a cron home channel is listed with `false`.
    public var homeTargetSet: Bool

    public init(id: String, name: String, homeTargetSet: Bool = true) {
        self.id = id
        self.name = name
        self.homeTargetSet = homeTargetSet
    }

    enum CodingKeys: String, CodingKey {
        case id, name
        case homeTargetSet = "home_target_set"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = (try? container.decodeIfPresent(String.self, forKey: .name)) ?? id
        homeTargetSet = (try? container.decodeIfPresent(Bool.self, forKey: .homeTargetSet)) ?? true
    }

    /// The choices for a job: its Bot Chat first, then the server's targets, then any
    /// target the job has that neither names (`origin`, `telegram:123`), as written.
    public static func options(server: [CronDeliveryTarget], job: CronJob) -> [CronDeliveryTarget] {
        var options = [CronDeliveryTarget(id: botChat, name: "Bot Chat")]
        options += server.filter { $0.id != botChat }
        let known = Set(options.map(\.id))
        options += job.deliveryTargets.filter { !known.contains($0) }.map { CronDeliveryTarget(id: $0, name: $0) }
        return options
    }

    /// A readable name for a target id: Bot Chat, else the server's name for it.
    public static func label(_ id: String, server: [CronDeliveryTarget]) -> String {
        if id == botChat { return "Bot Chat" }
        if id.hasPrefix(botChat + ":") { return "Bot Chat (\(id.dropFirst(botChat.count + 1)))" }
        if let name = server.first(where: { $0.id == id })?.name { return name }
        switch id {
        case "local": return "Local"
        case "origin": return "Origin"
        case "all": return "All channels"
        default: return id
        }
    }
}

/// `datetime.isoformat()` strings, as the job store writes them: with an offset, often
/// with microseconds, which `ISO8601DateFormatter` does not read.
enum CronDate {
    static func parse(_ value: String) -> Date? {
        var text = value.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: " ", with: "T")
        // Drop fractional seconds: "…:05.123456+00:00" → "…:05+00:00".
        if let dot = text.firstIndex(of: "."), text[..<dot].contains("T") {
            var end = text.index(after: dot)
            while end < text.endIndex, text[end].isASCIIDigit { end = text.index(after: end) }
            text.removeSubrange(dot..<end)
        }
        let withZone = ISO8601DateFormatter()
        if let date = withZone.date(from: text) { return date }
        // No offset: the server's local time is unknown, so the device's.
        let local = ISO8601DateFormatter()
        local.formatOptions = [.withFullDate, .withTime, .withDashSeparatorInDate, .withColonSeparatorInTime]
        local.timeZone = .current
        return local.date(from: text)
    }
}

private extension Character {
    var isASCIIDigit: Bool { isASCII && isNumber }
}
