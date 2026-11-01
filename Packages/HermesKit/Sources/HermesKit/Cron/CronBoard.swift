import Foundation
import HermesProtocol
import Observation

/// The list profile's scheduled jobs, as the session list's Cron tab shows them: read and
/// changed through the dashboard's REST routes (`CronSource`), by `GatewayConnection`.
@MainActor
@Observable
public final class CronBoard {
    /// The jobs of `profile`, soonest next run first (`CronJob.listOrder`).
    public internal(set) var jobs: [CronJob] = []
    /// The profile whose jobs `jobs` holds: `nil` until its first read comes back.
    public internal(set) var profile: String?
    public internal(set) var isLoading = false
    public internal(set) var error: String?
    /// `false` when the connection has no REST access, so jobs can't be read.
    public internal(set) var isAvailable = true
    /// Recent runs by job id, newest first, for the jobs whose runs were read.
    public internal(set) var runs: [String: [CronRun]] = [:]
    public internal(set) var runErrors: [String: String] = [:]
    /// The server's delivery targets for `profile` (`local` and configured platforms).
    public internal(set) var targets: [CronDeliveryTarget] = []
    /// Jobs being run now from the app: the trigger answers when the run ends.
    public internal(set) var triggering: Set<String> = []
    /// The ready-made jobs `profile` can start from, once read.
    public internal(set) var blueprints: [CronBlueprint] = []
    @ObservationIgnored var token = 0

    public init() {}

    func reset(to profile: String?) {
        token += 1
        jobs = []
        self.profile = nil
        isLoading = false
        error = nil
        runs = [:]
        runErrors = [:]
        targets = []
        blueprints = []
    }

    func replace(_ job: CronJob) {
        if let index = jobs.firstIndex(where: { $0.id == job.id }) { jobs[index] = job }
        jobs = CronJob.listOrder(jobs)
    }
}

extension GatewayConnection {
    /// Re-reads the list profile's jobs. Another profile's jobs are dropped first, so
    /// the tab never shows one profile's jobs under another's name.
    public func refreshCronJobs() async {
        guard let profile = listProfile else { return }
        if cron.profile != nil && cron.profile != profile { cron.reset(to: profile) }
        guard let source = cronSource else {
            cron.isAvailable = false
            return
        }
        cron.isAvailable = true
        cron.token += 1
        let token = cron.token
        cron.isLoading = true
        defer { if token == cron.token { cron.isLoading = false } }
        do {
            let jobs = try await source.cronJobs(profile: profile)
            guard token == cron.token, listProfile == profile else { return }
            cron.jobs = CronJob.listOrder(jobs)
            cron.profile = profile
            cron.error = nil
            let ids = Set(jobs.map(\.id))
            cron.runs = cron.runs.filter { ids.contains($0.key) }
        } catch {
            guard token == cron.token, listProfile == profile else { return }
            cron.profile = profile
            cron.error = Self.describe(error)
        }
    }

    /// Re-reads a job's most recent runs (Desktop's sidebar peek shows 5).
    public func refreshCronRuns(_ job: CronJob, limit: Int = 5) async {
        guard let profile = cron.profile, let source = cronSource else { return }
        do {
            let runs = try await source.cronRuns(jobID: job.id, profile: profile, limit: limit)
            guard cron.profile == profile else { return }
            cron.runs[job.id] = runs
            cron.runErrors[job.id] = nil
        } catch {
            guard cron.profile == profile else { return }
            cron.runErrors[job.id] = Self.describe(error)
        }
    }

    /// Reads where the list profile's jobs can deliver, once per profile.
    public func loadCronDeliveryTargets() async {
        guard let profile = cron.profile, cron.targets.isEmpty, let source = cronSource else { return }
        guard let targets = try? await source.cronDeliveryTargets(profile: profile), cron.profile == profile else { return }
        cron.targets = targets
    }

    public func pauseCronJob(_ job: CronJob) async throws {
        try await changeCronJob(job) { try await $0.pauseCronJob(job.id, profile: $1) }
    }

    public func resumeCronJob(_ job: CronJob) async throws {
        try await changeCronJob(job) { try await $0.resumeCronJob(job.id, profile: $1) }
    }

    /// Sets where the job delivers: a comma list of targets (`CronJob.deliver(toggling:on:)`).
    public func setCronDelivery(_ job: CronJob, to deliver: String) async throws {
        try await changeCronJob(job) {
            try await $0.updateCronJob(job.id, profile: $1, updates: ["deliver": .string(deliver)])
        }
    }

    /// Runs the job now. Answers when the run is recorded, then re-reads its runs.
    public func triggerCronJob(_ job: CronJob) async throws {
        guard !cron.triggering.contains(job.id) else { return }
        cron.triggering.insert(job.id)
        defer { cron.triggering.remove(job.id) }
        do {
            try await changeCronJob(job) { try await $0.triggerCronJob(job.id, profile: $1) }
        } catch let error as CronRequestError where error.status == 404 {
            // A one-shot can remove itself once it ran (`cron.py:640-650`).
            await refreshCronJobs()
            return
        }
        await refreshCronRuns(job)
    }

    public func deleteCronJob(_ job: CronJob) async throws {
        guard let profile = cron.profile, let source = cronSource else { throw GatewayClientError.notConnected }
        try await source.deleteCronJob(job.id, profile: profile)
        guard cron.profile == profile else { return }
        cron.jobs.removeAll { $0.id == job.id }
        cron.runs[job.id] = nil
    }

    /// Creates a job in the list profile, then re-reads the list (Desktop's
    /// `mutateAndRefreshCronJobs`, `apps/desktop/src/app/cron/cron-actions.ts`).
    @discardableResult
    public func createCronJob(_ draft: CronJobDraft) async throws -> CronJob {
        guard let profile = cron.profile, let source = cronSource else { throw GatewayClientError.notConnected }
        let job = try await source.createCronJob(profile: profile, body: draft.createBody)
        await refreshCronJobs()
        return job
    }

    /// Saves the editor's changes to a job.
    public func saveCronJob(_ job: CronJob, _ draft: CronJobDraft) async throws {
        try await changeCronJob(job) { try await $0.updateCronJob(job.id, profile: $1, updates: draft.updates) }
    }

    /// Reads the list profile's blueprints, once per profile. A server without them has none.
    public func loadCronBlueprints() async {
        guard let profile = cron.profile, cron.blueprints.isEmpty, let source = cronSource else { return }
        guard let blueprints = try? await source.cronBlueprints(profile: profile), cron.profile == profile else { return }
        cron.blueprints = blueprints
    }

    /// Fills in a blueprint and creates its job in the list profile.
    @discardableResult
    public func createCronJob(from blueprint: CronBlueprint, values: [String: String]) async throws -> CronJob {
        guard let profile = cron.profile, let source = cronSource else { throw GatewayClientError.notConnected }
        let job = try await source.instantiateCronBlueprint(blueprint.key, values: values, profile: profile)
        await refreshCronJobs()
        return job
    }

    /// The models a job can pin: the list profile's `model.options`, as the chat's model
    /// picker offers them (`CronEditorDialog`'s `requestModelOptions`, `index.tsx:1258-1266`).
    public func cronModelCatalog() async throws -> ModelCatalog {
        guard let client else { throw GatewayClientError.notConnected }
        return ModelCatalog(try await client.modelOptions(sessionID: nil, profile: cron.profile ?? listProfile))
    }

    private func changeCronJob(_ job: CronJob,
                               _ call: (any CronSource, String) async throws -> CronJob) async throws {
        guard let profile = cron.profile, let source = cronSource else { throw GatewayClientError.notConnected }
        let updated = try await call(source, profile)
        guard cron.profile == profile else { return }
        cron.replace(updated)
    }
}
