import Foundation
import HermesProtocol

/// The New and Edit Cron Job form: Desktop's `CronEditorDialog` fields
/// (`apps/desktop/src/app/cron/index.tsx:1209-1600`) and what it sends.
public struct CronJobDraft: Sendable, Hashable {
    public var name: String
    public var prompt: String
    public var schedule: CronSchedule
    /// Comma-separated delivery targets, `local` when none is picked.
    public var deliver: String
    /// The job's own model; `nil` follows the profile's default when it fires.
    public var model: ModelChoice?
    /// The job runs a script without an agent: the prompt is optional and no model applies.
    public let isScriptOnly: Bool

    /// A new job: every day at 9:00, saved locally (Desktop's defaults).
    public init() {
        name = ""
        prompt = ""
        schedule = CronSchedule()
        deliver = "local"
        model = nil
        isScriptOnly = false
    }

    /// The job's current settings.
    public init(_ job: CronJob) {
        name = job.name ?? ""
        prompt = job.prompt ?? ""
        schedule = CronSchedule(expression: job.scheduleExpression ?? "")
        deliver = job.deliveryTargets.joined(separator: ",")
        model = job.model.map { ModelChoice(provider: job.provider ?? "", model: $0) }
        isScriptOnly = job.isScriptOnly
    }

    public enum Problem: Sendable, Hashable {
        case promptAndSchedule, prompt, schedule

        public var message: String {
            switch self {
            case .promptAndSchedule: "Enter a prompt and a schedule."
            case .prompt: "Enter a prompt."
            case .schedule: "Enter a schedule."
            }
        }
    }

    /// What keeps it from being saved (`validateCronEditor`, `cron-job-model.ts:25-42`).
    public var problem: Problem? {
        let hasPrompt = !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasSchedule = !schedule.expression.isEmpty
        if !hasSchedule && !hasPrompt && !isScriptOnly { return .promptAndSchedule }
        if !hasSchedule { return .schedule }
        if !isScriptOnly && !hasPrompt { return .prompt }
        return nil
    }

    public var deliveryTargets: [String] { CronJob.parseTargets(deliver) }

    /// `deliver` with `target` on or off; the last target stays.
    public mutating func setDelivery(_ target: String, on: Bool) {
        deliver = CronJob(id: "", deliver: deliver).deliver(toggling: target, on: on)
    }

    /// `POST /api/cron/jobs` (`CronJobCreate`, `hermes_cli/web_models.py:316-336`; Desktop's
    /// `handleEditorSave`, `index.tsx:605-628`): a model only when one is picked.
    public var createBody: JSONValue {
        var body: [String: JSONValue] = [
            "prompt": .string(prompt.trimmingCharacters(in: .whitespacesAndNewlines)),
            "schedule": .string(schedule.expression),
            "deliver": .string(deliver.isEmpty ? "local" : deliver),
        ]
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty { body["name"] = .string(name) }
        if let model {
            body["model"] = .string(model.model)
            if !model.provider.isEmpty { body["provider"] = .string(model.provider) }
        }
        return .object(body)
    }

    /// `PUT /api/cron/jobs/{id}`'s `updates` (`cronEditorUpdates`, `cron-job-model.ts:137-158`):
    /// a script-only job keeps an empty prompt and its stored model; an agent job always
    /// sends both model fields, so picking the default clears a pinned one.
    public var updates: [String: JSONValue] {
        var updates: [String: JSONValue] = [
            "deliver": .string(deliver),
            "name": .string(name.trimmingCharacters(in: .whitespacesAndNewlines)),
            "schedule": .string(schedule.expression),
        ]
        let prompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if !isScriptOnly || !prompt.isEmpty { updates["prompt"] = .string(prompt) }
        if !isScriptOnly {
            updates["model"] = model.map { .string($0.model) } ?? .null
            updates["provider"] = model.flatMap { $0.provider.isEmpty ? nil : JSONValue.string($0.provider) } ?? .null
        }
        return updates
    }
}
