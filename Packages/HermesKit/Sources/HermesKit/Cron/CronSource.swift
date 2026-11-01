import Foundation
import HermesProtocol

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// A profile's scheduled jobs on the gateway's dashboard (`hermes_cli/web_routers/cron.py`).
/// `profile` names the profile whose `cron/jobs.json` is read; per-job calls send it as
/// the owner hint, which the dashboard checks (`_job_owner_profile`, `cron.py:79-97`).
public protocol CronSource: Sendable {
    func cronJobs(profile: String) async throws -> [CronJob]
    func cronRuns(jobID: String, profile: String, limit: Int) async throws -> [CronRun]
    func cronDeliveryTargets(profile: String) async throws -> [CronDeliveryTarget]
    func pauseCronJob(_ jobID: String, profile: String) async throws -> CronJob
    func resumeCronJob(_ jobID: String, profile: String) async throws -> CronJob
    /// Runs the job now and answers once the run is recorded, which takes as long as the job.
    func triggerCronJob(_ jobID: String, profile: String) async throws -> CronJob
    func updateCronJob(_ jobID: String, profile: String, updates: [String: JSONValue]) async throws -> CronJob
    func deleteCronJob(_ jobID: String, profile: String) async throws
    /// Creates a job from `CronJobDraft.createBody`.
    func createCronJob(profile: String, body: JSONValue) async throws -> CronJob
    func cronBlueprints(profile: String) async throws -> [CronBlueprint]
    /// Fills a blueprint's blanks and creates its job.
    func instantiateCronBlueprint(_ key: String, values: [String: String], profile: String) async throws -> CronJob
}

/// A refusal from the dashboard's REST routes (cron, capabilities, providers), with the
/// dashboard's own reason (`HTTPException.detail`).
public struct CronRequestError: Error, Sendable, Equatable {
    public var status: Int
    public var detail: String

    /// The dashboard's `{"detail": "…"}`, for a 4xx/5xx answer that has one.
    static func from(_ error: any Error) -> (any Error) {
        guard case DashboardError.http(let status, let body?) = error,
            let json = try? JSONDecoder().decode(JSONValue.self, from: Data(body.utf8)),
            let detail = json["detail"]?.stringValue, !detail.isEmpty
        else { return error }
        return CronRequestError(status: status, detail: detail)
    }
}

extension DashboardClient {
    /// `GET /api/cron/jobs?profile=` (`cron.py:668-670`).
    public func cronJobs(profile: String, bearer: String? = nil) async throws -> [CronJob] {
        try await cronCall(path: "/api/cron/jobs", method: "GET", profile: profile, bearer: bearer)
    }

    /// `GET /api/cron/jobs/{id}/runs?profile=&limit=`: `{runs: [...]}`, newest first (`cron.py:678-680`).
    public func cronRuns(jobID: String, profile: String, limit: Int, bearer: String? = nil) async throws -> [CronRun] {
        let answer: RunsAnswer = try await cronCall(path: "/api/cron/jobs/\(Self.segment(jobID))/runs", method: "GET",
                                                     profile: profile, extra: [URLQueryItem(name: "limit", value: String(limit))],
                                                     bearer: bearer)
        return answer.runs
    }

    /// `GET /api/cron/delivery-targets?profile=`: `{targets: [...]}` (`cron.py:688-711`).
    public func cronDeliveryTargets(profile: String, bearer: String? = nil) async throws -> [CronDeliveryTarget] {
        let answer: TargetsAnswer = try await cronCall(path: "/api/cron/delivery-targets", method: "GET",
                                                       profile: profile, bearer: bearer)
        return answer.targets
    }

    /// `POST /api/cron/jobs/{id}/{pause|resume|trigger}` (`cron.py:719-731`). Trigger waits
    /// for the run, so it gets Desktop's day-long timeout (`apps/desktop/src/api/cron.ts:19-23`).
    public func cronAction(_ action: String, jobID: String, profile: String, bearer: String? = nil) async throws -> CronJob {
        try await cronCall(path: "/api/cron/jobs/\(Self.segment(jobID))/\(action)", method: "POST", profile: profile,
                           timeout: action == "trigger" ? 24 * 60 * 60 : nil, bearer: bearer)
    }

    /// `PUT /api/cron/jobs/{id}` with `{updates: {...}}` (`cron.py:714-716`, `CronJobUpdate`).
    public func updateCronJob(_ jobID: String, profile: String, updates: [String: JSONValue],
                              bearer: String? = nil) async throws -> CronJob {
        try await cronCall(path: "/api/cron/jobs/\(Self.segment(jobID))", method: "PUT", profile: profile,
                           json: ["updates": .object(updates)], bearer: bearer)
    }

    /// `DELETE /api/cron/jobs/{id}`: `{ok: true}` (`cron.py:734-736`).
    public func deleteCronJob(_ jobID: String, profile: String, bearer: String? = nil) async throws {
        let _: JSONValue = try await cronCall(path: "/api/cron/jobs/\(Self.segment(jobID))", method: "DELETE",
                                              profile: profile, bearer: bearer)
    }

    /// `POST /api/cron/jobs?profile=` with a `CronJobCreate` body (`cron.py:716-718`).
    public func createCronJob(profile: String, body: JSONValue, bearer: String? = nil) async throws -> CronJob {
        try await cronCall(path: "/api/cron/jobs", method: "POST", profile: profile, json: body, bearer: bearer)
    }

    /// `GET /api/cron/blueprints?profile=`: `{blueprints: [...]}` (`cron.py:891-900`).
    public func cronBlueprints(profile: String, bearer: String? = nil) async throws -> [CronBlueprint] {
        let answer: BlueprintsAnswer = try await cronCall(path: "/api/cron/blueprints", method: "GET",
                                                          profile: profile, bearer: bearer)
        return answer.blueprints
    }

    /// `POST /api/cron/blueprints/instantiate?profile=` with `{blueprint, values}`; a blank
    /// filled in wrong is a 422 with the reason (`cron.py:910-936`).
    public func instantiateCronBlueprint(_ key: String, values: [String: String], profile: String,
                                         bearer: String? = nil) async throws -> CronJob {
        try await cronCall(path: "/api/cron/blueprints/instantiate", method: "POST", profile: profile,
                           json: ["blueprint": .string(key), "values": .object(values.mapValues(JSONValue.string))],
                           bearer: bearer)
    }

    private func cronCall<T: Decodable>(path: String, method: String, profile: String, json: JSONValue? = nil,
                                        extra: [URLQueryItem] = [], timeout: TimeInterval? = nil,
                                        bearer: String?) async throws -> T {
        var request = request(path: path, method: method, json: json,
                              query: [URLQueryItem(name: "profile", value: profile)] + extra)
        if let timeout { request.timeoutInterval = timeout }
        if let bearer { request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization") }
        do {
            return try await send(request)
        } catch {
            throw CronRequestError.from(error)
        }
    }

    /// A job id as one path segment. Ids are hex, but names are accepted too (`cron.py:79-97`).
    private static func segment(_ id: String) -> String {
        id.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-._~"))) ?? id
    }

    private struct RunsAnswer: Decodable { var runs: [CronRun] }
    private struct TargetsAnswer: Decodable { var targets: [CronDeliveryTarget] }
    private struct BlueprintsAnswer: Decodable { var blueprints: [CronBlueprint] }
}

extension DashboardConnector: CronSource {
    public func cronJobs(profile: String) async throws -> [CronJob] {
        try await authorized { try await dashboard.cronJobs(profile: profile, bearer: $0) }
    }

    public func cronRuns(jobID: String, profile: String, limit: Int) async throws -> [CronRun] {
        try await authorized { try await dashboard.cronRuns(jobID: jobID, profile: profile, limit: limit, bearer: $0) }
    }

    public func cronDeliveryTargets(profile: String) async throws -> [CronDeliveryTarget] {
        try await authorized { try await dashboard.cronDeliveryTargets(profile: profile, bearer: $0) }
    }

    public func pauseCronJob(_ jobID: String, profile: String) async throws -> CronJob {
        try await authorized { try await dashboard.cronAction("pause", jobID: jobID, profile: profile, bearer: $0) }
    }

    public func resumeCronJob(_ jobID: String, profile: String) async throws -> CronJob {
        try await authorized { try await dashboard.cronAction("resume", jobID: jobID, profile: profile, bearer: $0) }
    }

    public func triggerCronJob(_ jobID: String, profile: String) async throws -> CronJob {
        try await authorized { try await dashboard.cronAction("trigger", jobID: jobID, profile: profile, bearer: $0) }
    }

    public func updateCronJob(_ jobID: String, profile: String, updates: [String: JSONValue]) async throws -> CronJob {
        try await authorized { try await dashboard.updateCronJob(jobID, profile: profile, updates: updates, bearer: $0) }
    }

    public func deleteCronJob(_ jobID: String, profile: String) async throws {
        try await authorized { try await dashboard.deleteCronJob(jobID, profile: profile, bearer: $0) }
    }

    public func createCronJob(profile: String, body: JSONValue) async throws -> CronJob {
        try await authorized { try await dashboard.createCronJob(profile: profile, body: body, bearer: $0) }
    }

    public func cronBlueprints(profile: String) async throws -> [CronBlueprint] {
        try await authorized { try await dashboard.cronBlueprints(profile: profile, bearer: $0) }
    }

    public func instantiateCronBlueprint(_ key: String, values: [String: String], profile: String) async throws -> CronJob {
        try await authorized {
            try await dashboard.instantiateCronBlueprint(key, values: values, profile: profile, bearer: $0)
        }
    }
}
