import Foundation
import HermesProtocol
import Synchronization
import Testing

@testable import HermesKit

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// A job as `cron/jobs.py::create_job` stores it (`:1893-1930`), which the dashboard lists
/// as is: ISO times with an offset and microseconds, the schedule as an object.
private let storedJob = #"""
    {"id":"a1b2c3d4e5f6","name":"Morning brief","prompt":"Summarize the news","skills":[],"skill":null,
     "model":null,"provider":null,"base_url":null,"script":null,"no_agent":false,
     "schedule":{"kind":"cron","expr":"0 9 * * *","display":"0 9 * * *"},"schedule_display":"0 9 * * *",
     "repeat":{"times":null,"completed":3},"enabled":true,"state":"scheduled","paused_at":null,
     "paused_reason":null,"created_at":"2026-10-12T08:01:02.345678-04:00",
     "next_run_at":"2026-10-20T09:00:00-04:00","last_run_at":"2026-10-19T09:00:04.123456-04:00",
     "last_status":"ok","last_error":null,"last_delivery_error":null,"last_delivery_unverified":null,
     "last_failure":null,"failure_streak":0,"deliver":"bot-chat,telegram","origin":null,
     "enabled_toolsets":null,"workdir":null}
    """#

@Suite struct CronJobTests {
    @Test func decodesTheStoredShape() throws {
        let job = try JSONDecoder().decode(CronJob.self, from: Data(storedJob.utf8))
        #expect(job.id == "a1b2c3d4e5f6")
        #expect(job.title == "Morning brief")
        #expect(job.scheduleDisplay == "0 9 * * *")
        #expect(job.effectiveState == "scheduled")
        #expect(job.deliveryTargets == ["bot-chat", "telegram"])
        #expect(job.deliversToBotChat)
        #expect(job.nextRunAt == Date(timeIntervalSince1970: 1_792_501_200))
        let lastRun = try #require(job.lastRunAt)
        #expect(abs(lastRun.timeIntervalSince1970 - 1_792_414_804) < 1)
    }

    /// A field of an unexpected type is dropped, not the job (or the list with it).
    @Test func toleratesOddFields() throws {
        let json = #"{"id":"x","name":5,"enabled":"yes","deliver":["local","bot-chat"],"schedule":"every 2h","next_run_at":"soon"}"#
        let job = try JSONDecoder().decode(CronJob.self, from: Data(json.utf8))
        #expect(job.name == nil)
        #expect(job.enabled)
        #expect(job.deliver == "local,bot-chat")
        #expect(job.scheduleDisplay == "every 2h")
        #expect(job.nextRunAt == nil)
    }

    @Test func titleFallsBackLikeDesktop() {
        #expect(CronJob(id: "j", prompt: String(repeating: "a", count: 70)).title == String(repeating: "a", count: 60) + "…")
        #expect(CronJob(id: "j", script: "check.sh").title == "check.sh")
        #expect(CronJob(id: "j").title == "j")
        #expect(CronJob(id: "j", enabled: false).effectiveState == "disabled")
    }

    /// `toggleCronDeliveryTarget` (`apps/desktop/src/app/cron/cron-job-model.ts:93-105`).
    @Test func deliveryToggles() {
        let local = CronJob(id: "j")
        #expect(local.deliveryTargets == ["local"])
        #expect(local.deliver(toggling: "bot-chat", on: true) == "local,bot-chat")
        #expect(local.deliver(toggling: "local", on: false) == "local", "the last target stays")
        let both = CronJob(id: "j", deliver: " bot-chat , telegram,bot-chat ")
        #expect(both.deliveryTargets == ["bot-chat", "telegram"])
        #expect(both.deliver(toggling: "telegram", on: false) == "bot-chat")
        #expect(both.deliver(toggling: "bot-chat", on: true) == "bot-chat,telegram")
        #expect(CronJob(id: "j", deliver: "bot-chat:research").deliversToBotChat)
        #expect(!CronJob(id: "j", deliver: "origin").deliversToBotChat)
    }

    @Test func listOrderIsSoonestFirst() {
        let now = Date()
        let jobs = [
            CronJob(id: "none-b", name: "b"),
            CronJob(id: "later", nextRunAt: now.addingTimeInterval(3600)),
            CronJob(id: "none-a", name: "a"),
            CronJob(id: "soon", nextRunAt: now.addingTimeInterval(60)),
        ]
        #expect(CronJob.listOrder(jobs).map(\.id) == ["soon", "later", "none-a", "none-b"])
    }

    /// More than 15 minutes past `next_run_at`, unless the job isn't expected to fire.
    @Test func overdue() {
        let now = Date()
        let stale = now.addingTimeInterval(-20 * 60)
        #expect(CronJob(id: "j", nextRunAt: stale).overdueSince(now: now) == stale)
        #expect(CronJob(id: "j", nextRunAt: now.addingTimeInterval(-5 * 60)).overdueSince(now: now) == nil)
        #expect(CronJob(id: "j", state: "paused", nextRunAt: stale).overdueSince(now: now) == nil)
    }

    @Test func runSessionIDs() {
        #expect(CronRun.isRunSessionID("cron_a1b2c3d4e5f6_20261019_090004"))
        #expect(!CronRun.isRunSessionID("cron_20261019_090004"))
        #expect(!CronRun.isRunSessionID("20261019_090004_abcdef"))
        #expect(!CronRun.isRunSessionID("cron_job_2026101x_090004"))
        #expect(!CronRun.isRunSessionID(nil))
    }

    /// A session row, and a script-only run's output document
    /// (`hermes_cli/web_routers/cron.py:262-280,397`).
    @Test func runsDecode() throws {
        let json = #"""
            {"runs":[
              {"id":"cron_a1_20261019_090004","source":"cron","title":"Morning brief","preview":"Here is",
               "started_at":1760878804.5,"last_active":1760878860.0,"ended_at":1760878861.0,
               "message_count":4,"profile":"coder","model":"x"},
              {"id":"cron_output:a1:2026-10-18_09-00-03","source":"cron_output","title":"ok",
               "preview":"disk 41%","started_at":1760792403.0,"message_count":0,"output_tokens":0}
            ]}
            """#
        struct Answer: Decodable { var runs: [CronRun] }
        let runs = try JSONDecoder().decode(Answer.self, from: Data(json.utf8)).runs
        #expect(runs.count == 2)
        #expect(!runs[0].isOutputDocument)
        #expect(runs[0].time == Date(timeIntervalSince1970: 1_760_878_860))
        #expect(runs[1].isOutputDocument)
        let entry = runs[0].historyEntry(profile: "default")
        #expect(entry.profile == "coder")
        #expect(entry.summary.id == "cron_a1_20261019_090004")
        #expect(entry.summary.source == "cron")
    }

    @Test func deliveryOptions() throws {
        let json = #"{"targets":[{"id":"local","name":"Local (save only)","home_target_set":true,"home_env_var":null},{"id":"telegram","name":"Telegram","home_target_set":false,"home_env_var":"TELEGRAM_HOME_CHANNEL"}]}"#
        struct Answer: Decodable { var targets: [CronDeliveryTarget] }
        let server = try JSONDecoder().decode(Answer.self, from: Data(json.utf8)).targets
        #expect(server[1].homeTargetSet == false)
        let options = CronDeliveryTarget.options(server: server, job: CronJob(id: "j", deliver: "origin,local"))
        #expect(options.map(\.id) == ["bot-chat", "local", "telegram", "origin"])
        #expect(CronDeliveryTarget.label("local", server: server) == "Local (save only)")
        #expect(CronDeliveryTarget.label("bot-chat", server: server) == "Bot Chat")
        #expect(CronDeliveryTarget.label("bot-chat:research", server: server) == "Bot Chat (research)")
    }
}

@Suite(.timeLimit(.minutes(1))) struct CronRequestTests {
    private func connector(_ http: FakeHTTP) throws -> DashboardConnector {
        DashboardConnector(endpoint: try GatewayEndpoint("https://hermes.example.ts.net"),
                           credential: .bearer(accessToken: "tok"), http: http)
    }

    @Test func listsTheProfilesJobs() async throws {
        let http = FakeHTTP([.init(status: 200, body: "[\(storedJob)]")])
        let jobs = try await connector(http).cronJobs(profile: "coder")
        #expect(jobs.map(\.id) == ["a1b2c3d4e5f6"])
        let request = try #require(http.requests.first)
        #expect(request.httpMethod == "GET")
        #expect(request.url?.absoluteString == "https://hermes.example.ts.net/api/cron/jobs?profile=coder")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer tok")
    }

    @Test func readsRunsAndTargets() async throws {
        let http = FakeHTTP([
            .init(status: 200, body: #"{"runs":[{"id":"cron_a1_20261019_090004","source":"cron"}]}"#),
            .init(status: 200, body: #"{"targets":[{"id":"local","name":"Local (save only)","home_target_set":true}]}"#),
        ])
        let source = try connector(http)
        #expect(try await source.cronRuns(jobID: "a1", profile: "coder", limit: 5).count == 1)
        #expect(try await source.cronDeliveryTargets(profile: "coder").map(\.id) == ["local"])
        #expect(http.requests.map { $0.url?.absoluteString ?? "" } == [
            "https://hermes.example.ts.net/api/cron/jobs/a1/runs?profile=coder&limit=5",
            "https://hermes.example.ts.net/api/cron/delivery-targets?profile=coder",
        ])
    }

    /// `PUT /api/cron/jobs/{id}` takes `{updates: {...}}` (`hermes_cli/web_models.py::CronJobUpdate`).
    @Test func updatesDelivery() async throws {
        let http = FakeHTTP([.init(status: 200, body: storedJob)])
        let job = try await connector(http).updateCronJob("a1", profile: "coder", updates: ["deliver": "bot-chat"])
        #expect(job.deliver == "bot-chat,telegram")
        let request = try #require(http.requests.first)
        #expect(request.httpMethod == "PUT")
        #expect(request.url?.path == "/api/cron/jobs/a1")
        let body = try JSONDecoder().decode(JSONValue.self, from: try #require(request.httpBody))
        #expect(body == ["updates": ["deliver": "bot-chat"]])
    }

    /// The trigger answers when the run ends: no 15 s timeout.
    @Test func actionsPostAndTriggerWaits() async throws {
        let http = FakeHTTP(Array(repeating: .init(status: 200, body: storedJob), count: 3) + [.init(status: 200, body: #"{"ok":true}"#)])
        let source = try connector(http)
        _ = try await source.pauseCronJob("a1", profile: "coder")
        _ = try await source.resumeCronJob("a1", profile: "coder")
        _ = try await source.triggerCronJob("a1", profile: "coder")
        try await source.deleteCronJob("a1", profile: "coder")
        #expect(http.requests.map { "\($0.httpMethod ?? "") \($0.url?.path ?? "")" } == [
            "POST /api/cron/jobs/a1/pause", "POST /api/cron/jobs/a1/resume",
            "POST /api/cron/jobs/a1/trigger", "DELETE /api/cron/jobs/a1",
        ])
        #expect(http.requests[0].timeoutInterval == 15)
        #expect(http.requests[2].timeoutInterval >= 3600)
    }

    @Test func refusalsCarryTheDashboardsReason() async throws {
        let http = FakeHTTP([.init(status: 409, body: #"{"detail":"Job is already running or was claimed by another scheduler"}"#)])
        await #expect(throws: CronRequestError(status: 409, detail: "Job is already running or was claimed by another scheduler")) {
            _ = try await connector(http).triggerCronJob("a1", profile: "coder")
        }
        #expect(GatewayConnection.describe(CronRequestError(status: 400, detail: "Unknown target")) == "Unknown target")
    }
}

/// Scripted jobs per profile, recording every call.
final class FakeCronSource: CronSource, @unchecked Sendable {
    private let state: Mutex<(jobs: [String: [CronJob]], calls: [String], updates: [[String: JSONValue]])>

    init(_ jobs: [String: [CronJob]]) {
        state = Mutex((jobs, [], []))
    }

    var calls: [String] { state.withLock { $0.calls } }
    var updates: [[String: JSONValue]] { state.withLock { $0.updates } }

    private func record(_ call: String) { state.withLock { $0.calls.append(call) } }

    private func change(_ id: String, _ profile: String, _ edit: (inout CronJob) -> Void) throws -> CronJob {
        try state.withLock { state in
            guard let index = state.jobs[profile]?.firstIndex(where: { $0.id == id }) else {
                throw CronRequestError(status: 404, detail: "Job not found")
            }
            edit(&state.jobs[profile]![index])
            return state.jobs[profile]![index]
        }
    }

    func cronJobs(profile: String) async throws -> [CronJob] {
        record("list \(profile)")
        return state.withLock { $0.jobs[profile] ?? [] }
    }

    func cronRuns(jobID: String, profile: String, limit: Int) async throws -> [CronRun] {
        record("runs \(jobID)")
        return [CronRun(id: "cron_\(jobID)_20261019_090004", profile: profile)]
    }

    func cronDeliveryTargets(profile: String) async throws -> [CronDeliveryTarget] {
        [CronDeliveryTarget(id: "local", name: "Local (save only)")]
    }

    func pauseCronJob(_ jobID: String, profile: String) async throws -> CronJob {
        record("pause \(jobID)")
        return try change(jobID, profile) { $0.state = "paused"; $0.enabled = false }
    }

    func resumeCronJob(_ jobID: String, profile: String) async throws -> CronJob {
        record("resume \(jobID)")
        return try change(jobID, profile) { $0.state = "scheduled"; $0.enabled = true }
    }

    func triggerCronJob(_ jobID: String, profile: String) async throws -> CronJob {
        record("trigger \(jobID)")
        return try change(jobID, profile) { $0.lastStatus = "ok" }
    }

    func updateCronJob(_ jobID: String, profile: String, updates: [String: JSONValue]) async throws -> CronJob {
        record("update \(jobID)")
        state.withLock { $0.updates.append(updates) }
        return try change(jobID, profile) { $0.deliver = updates["deliver"]?.stringValue }
    }

    func deleteCronJob(_ jobID: String, profile: String) async throws {
        record("delete \(jobID)")
        _ = try change(jobID, profile) { _ in }
        state.withLock { $0.jobs[profile]?.removeAll { $0.id == jobID } }
    }
}

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct CronBoardTests {
    private func connect(_ source: FakeCronSource) async throws -> GatewayConnection {
        let gateway = ScriptedGateway()
        gateway.on("profiles.list", result: [
            "profiles": [profileRowPayload("default", isDefault: true), profileRowPayload("coder")],
            "bot_mode_protocol": true, "install_id": "test",
        ])
        let connection = try await gateway.withDefaults().connect(cron: source)
        // Settle connect's background roster read first: it picks a list profile when the
        // selected one isn't in the roster, which reset the board under the test on CI.
        try #require(await eventually { connection.listsRefreshTask == nil && !connection.listsRefreshQueued })
        connection.selectListProfile("coder")
        return connection
    }

    @Test func readsTheListProfilesJobs() async throws {
        let source = FakeCronSource([
            "coder": [CronJob(id: "b", name: "Later", nextRunAt: Date().addingTimeInterval(7200)),
                      CronJob(id: "a", name: "Soon", nextRunAt: Date().addingTimeInterval(60))],
            "default": [CronJob(id: "d", name: "Default's")],
        ])
        let connection = try await connect(source)
        await connection.refreshCronJobs()
        #expect(connection.cron.profile == "coder")
        #expect(connection.cron.jobs.map(\.id) == ["a", "b"])
        #expect(connection.cron.error == nil)

        // Another profile: its jobs, never the last one's under its name.
        connection.selectListProfile("default")
        #expect(connection.cron.jobs.isEmpty)
        #expect(connection.cron.profile == nil)
        await connection.refreshCronJobs()
        #expect(connection.cron.jobs.map(\.id) == ["d"])
        #expect(source.calls == ["list coder", "list default"])
    }

    @Test func actionsUpdateTheJobInPlace() async throws {
        let source = FakeCronSource(["coder": [CronJob(id: "a", name: "Brief", deliver: "local")]])
        let connection = try await connect(source)
        await connection.refreshCronJobs()
        let job = try #require(connection.cron.jobs.first)

        try await connection.pauseCronJob(job)
        #expect(connection.cron.jobs.first?.isPaused == true)
        try await connection.resumeCronJob(job)
        #expect(connection.cron.jobs.first?.isPaused == false)

        try await connection.setCronDelivery(job, to: job.deliver(toggling: "bot-chat", on: true))
        #expect(source.updates == [["deliver": "local,bot-chat"]])
        #expect(connection.cron.jobs.first?.deliversToBotChat == true)

        try await connection.triggerCronJob(job)
        #expect(connection.cron.triggering.isEmpty)
        #expect(connection.cron.runs["a"]?.count == 1, "a run re-reads the job's runs")

        try await connection.deleteCronJob(job)
        #expect(connection.cron.jobs.isEmpty)
        #expect(source.calls == ["list coder", "pause a", "resume a", "update a", "trigger a", "runs a", "delete a"])
    }

    @Test func withoutRESTTheTabSaysSo() async throws {
        let connection = try await ScriptedGateway().withDefaults().connect()
        try #require(await eventually { connection.listsRefreshTask == nil && !connection.listsRefreshQueued })
        connection.selectListProfile("coder")
        await connection.refreshCronJobs()
        #expect(!connection.cron.isAvailable)
    }
}
