import Foundation
import HermesKit
import HermesProtocol
import Synchronization
import Testing

@testable import HermesBridge

/// The list profile's cron jobs: the `cron` snapshot the tab shows, and the actions
/// (`pauseCronJob`, `setCronDelivery`, `triggerCronJob`, `deleteCronJob`, the editor's
/// `createCronJob`/`saveCronJob`) reaching the source with the profile.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct BridgeCronTests {
    /// A job as `cron/jobs.py::create_job` stores it (the shape `CronTests` decodes).
    private static let jobJSON = #"""
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

    /// A cron source that records every call.
    private final class FakeCronSource: CronSource, @unchecked Sendable {
        let jobs: [CronJob]
        private let calls = Mutex<[(String, String)]>([])

        init(jobs: [CronJob]) { self.jobs = jobs }

        var invocations: [(String, String)] { calls.withLock { $0 } }
        private func record(_ what: String, _ profile: String) { calls.withLock { $0.append((what, profile)) } }

        func cronJobs(profile: String) async throws -> [CronJob] {
            record("jobs", profile)
            return jobs
        }

        func cronRuns(jobID: String, profile: String, limit: Int) async throws -> [CronRun] {
            record("runs:\(jobID)", profile)
            return [try JSONDecoder().decode(CronRun.self, from: Data(#"""
                {"id":"cron_a1b2c3d4e5f6_20261101_090000","title":"Morning brief","preview":"News: none today",
                 "started_at":1793000000,"last_active":1793000060,"ended_at":1793000060,
                 "source":"cron","profile":"coder","message_count":2}
                """#.utf8))]
        }

        func cronDeliveryTargets(profile: String) async throws -> [CronDeliveryTarget] {
            record("targets", profile)
            return [CronDeliveryTarget(id: "local", name: "Local feed", homeTargetSet: true)]
        }

        func pauseCronJob(_ jobID: String, profile: String) async throws -> CronJob {
            record("pause:\(jobID)", profile)
            return jobs[0]
        }

        func resumeCronJob(_ jobID: String, profile: String) async throws -> CronJob {
            record("resume:\(jobID)", profile)
            return jobs[0]
        }

        func triggerCronJob(_ jobID: String, profile: String) async throws -> CronJob {
            record("trigger:\(jobID)", profile)
            return jobs[0]
        }

        func updateCronJob(_ jobID: String, profile: String, updates: [String: JSONValue]) async throws -> CronJob {
            record("update:\(jobID):\(updates["deliver"]?.stringValue ?? updates["schedule"]?.stringValue ?? "")",
                   profile)
            return jobs[0]
        }

        func deleteCronJob(_ jobID: String, profile: String) async throws {
            record("delete:\(jobID)", profile)
        }

        func createCronJob(profile: String, body: JSONValue) async throws -> CronJob {
            record("create:\(body["prompt"]?.stringValue ?? ""):\(body["schedule"]?.stringValue ?? "")", profile)
            return jobs[0]
        }

        func cronBlueprints(profile: String) async throws -> [CronBlueprint] {
            record("blueprints", profile)
            return [CronBlueprint(key: "daily-brief", title: "Daily brief", description: "Ask for a brief",
                                   fields: [CronBlueprint.Field(name: "deliver", kind: .enum, label: "Deliver to",
                                                               options: ["bot-chat", "local"])])]
        }

        func instantiateCronBlueprint(_ key: String, values: [String: String], profile: String) async throws -> CronJob {
            record("instantiate:\(key):\(values["deliver"] ?? "")", profile)
            return jobs[0]
        }
    }

    private func openedBridge(outbox: Outbox, server: BridgeServer, source: FakeCronSource) async throws -> Bridge {
        let bridge = try await Bridge.connected(server, outbox: outbox, cron: source)
        try await Bridge.openedChat(bridge, outbox: outbox, server: server)
        return bridge
    }

    @Test func jobsRunsAndTargetsFollowAsTheSnapshot() async throws {
        let outbox = Outbox()
        let job = try JSONDecoder().decode(CronJob.self, from: Data(Self.jobJSON.utf8))
        let source = FakeCronSource(jobs: [job])
        let server = BridgeServer()
        let bridge = try await openedBridge(outbox: outbox, server: server, source: source)

        try await bridge.receive(#"{"id":"j1","method":"refreshCronJobs"}"#)
        #expect(await eventually { outbox.last("cron")?["profile"] as? String == "coder" })
        let cron = try #require(outbox.last("cron"))
        #expect(cron["profile"] as? String == "coder")
        #expect(cron["isAvailable"] as? Bool == true)
        let jobs = try #require(cron["jobs"] as? [[String: Any]])
        #expect(jobs.count == 1)
        #expect(jobs[0]["id"] as? String == "a1b2c3d4e5f6")
        #expect(jobs[0]["title"] as? String == "Morning brief")
        #expect(jobs[0]["state"] as? String == "scheduled")
        #expect((jobs[0]["deliver"] as? [Any])?.count == 2)
        #expect((jobs[0]["nextRunAt"] as? Double) ?? 0 > 0)
        // The job was read for the list profile.
        #expect(source.invocations.contains { $0 == ("jobs", "coder") })

        // Its recent runs, and the delivery targets.
        try await bridge.receive(#"{"id":"r1","method":"refreshCronRuns","params":{"id":"a1b2c3d4e5f6"}}"#)
        #expect(await eventually {
            let runs = outbox.last("cron")?["runs"] as? [String: Any]
            return (runs?["a1b2c3d4e5f6"] as? [[String: Any]])?.isEmpty == false
        })
        let withRuns = try #require(outbox.last("cron"))
        let runs = try #require((withRuns["runs"] as? [String: Any])?["a1b2c3d4e5f6"] as? [[String: Any]])
        #expect(runs.count == 1)
        #expect(runs[0]["isOutputDocument"] as? Bool == false)
        // A run with a session opens as a chat: its entry id is what `openCronRun` takes.
        #expect(runs[0]["entryID"] as? String == "coder/cron_a1b2c3d4e5f6_20261101_090000")

        try await bridge.receive(#"{"id":"t1","method":"loadCronDeliveryTargets"}"#)
        #expect(await eventually {
            (outbox.last("cron")?["targets"] as? [[String: Any]])?.isEmpty == false
        })
        let withTargets = try #require(outbox.last("cron"))
        let targets = try #require(withTargets["targets"] as? [[String: Any]])
        #expect(targets.first?["id"] as? String == "local")
    }

    @Test func aRunOpensAsAChatOfTheProfile() async throws {
        let outbox = Outbox()
        let job = try JSONDecoder().decode(CronJob.self, from: Data(Self.jobJSON.utf8))
        let source = FakeCronSource(jobs: [job])
        let server = BridgeServer()
        let bridge = try await openedBridge(outbox: outbox, server: server, source: source)
        try await bridge.receive(#"{"id":"j1","method":"refreshCronJobs"}"#)
        try await bridge.receive(#"{"id":"r1","method":"refreshCronRuns","params":{"id":"a1b2c3d4e5f6"}}"#)
        server.on("session.resume") { _ in BridgeServer.resumed(sid: "rt-run", key: "cron_a1b2c3d4e5f6_20261101_090000") }
        try await bridge.receive(
            #"{"id":"o1","method":"openCronRun","params":{"id":"cron_a1b2c3d4e5f6_20261101_090000"}}"#)
        #expect(outbox.last["error"] == nil)
        let chat = try #require(outbox.last("chat"))
        #expect(chat["sessionID"] as? String == "rt-run")
        #expect(chat["storedSessionID"] as? String == "cron_a1b2c3d4e5f6_20261101_090000")
        // An unknown run is refused.
        try await bridge.receive(#"{"id":"o2","method":"openCronRun","params":{"id":"nope"}}"#)
        #expect(outbox.last["error"] as? String == "no run nope")
    }

    @Test func actionsReachTheSourceForTheListProfile() async throws {
        let outbox = Outbox()
        let job = try JSONDecoder().decode(CronJob.self, from: Data(Self.jobJSON.utf8))
        let source = FakeCronSource(jobs: [job])
        let server = BridgeServer()
        let bridge = try await openedBridge(outbox: outbox, server: server, source: source)
        try await bridge.receive(#"{"id":"j1","method":"refreshCronJobs"}"#)

        try await bridge.receive(#"{"id":"a1","method":"pauseCronJob","params":{"id":"a1b2c3d4e5f6"}}"#)
        #expect(source.invocations.contains { $0 == ("pause:a1b2c3d4e5f6", "coder") })
        try await bridge.receive(#"{"id":"a2","method":"setCronDelivery","params":{"id":"a1b2c3d4e5f6","deliver":"local"}}"#)
        #expect(source.invocations.contains { $0 == ("update:a1b2c3d4e5f6:local", "coder") })
        try await bridge.receive(#"{"id":"a3","method":"triggerCronJob","params":{"id":"a1b2c3d4e5f6"}}"#)
        #expect(source.invocations.contains { $0 == ("trigger:a1b2c3d4e5f6", "coder") })
        // A trigger also re-reads the job's runs, as the tab shows them.
        #expect(source.invocations.contains { $0 == ("runs:a1b2c3d4e5f6", "coder") })
        try await bridge.receive(#"{"id":"a4","method":"deleteCronJob","params":{"id":"a1b2c3d4e5f6"}}"#)
        #expect(source.invocations.contains { $0 == ("delete:a1b2c3d4e5f6", "coder") })
        #expect(outbox.last["error"] == nil)
        // The job left the list.
        #expect(await eventually { (outbox.last("cron")?["jobs"] as? [Any])?.isEmpty == true })
    }

    @Test func theEditorCreatesAndSavesThroughTheDraft() async throws {
        let outbox = Outbox()
        let job = try JSONDecoder().decode(CronJob.self, from: Data(Self.jobJSON.utf8))
        let source = FakeCronSource(jobs: [job])
        let server = BridgeServer()
        let bridge = try await openedBridge(outbox: outbox, server: server, source: source)
        try await bridge.receive(#"{"id":"j1","method":"refreshCronJobs"}"#)

        // A new job from the editor's dialog.
        try await bridge.receive(#"""
            {"id":"n1","method":"createCronJob","params":{"draft":{
              "name":"Evening brief","prompt":"Summarize the day","schedule":{"frequency":"daily","hour":21,"minute":30},
              "deliver":"local","provider":"test-provider","model":"test-model"}}}
            """#)
        #expect(source.invocations.contains { $0 == ("create:Summarize the day:30 21 * * *", "coder") })
        // Creating re-reads the list, as on the Mac.
        #expect(source.invocations.filter { $0.0 == "jobs" }.count == 2)

        // An edit keeps what the dialog didn't send and sends what it changed.
        try await bridge.receive(#"""
            {"id":"e1","method":"saveCronJob","params":{"id":"a1b2c3d4e5f6","draft":{
              "name":"Morning brief","prompt":"Summarize the news","schedule":{"frequency":"weekdays","hour":9},
              "deliver":"bot-chat"}}}
            """#)
        // Weekdays at 9:00, the rest kept.
        #expect(source.invocations.contains { $0 == ("update:a1b2c3d4e5f6:bot-chat", "coder") })

        // A blueprint's blanks create its job.
        try await bridge.receive(#"{"id":"b1","method":"loadCronBlueprints"}"#)
        #expect(await eventually {
            (outbox.last("cron")?["blueprints"] as? [[String: Any]])?.isEmpty == false
        })
        let cron = try #require(outbox.last("cron"))
        let blueprints = try #require(cron["blueprints"] as? [[String: Any]])
        #expect(blueprints.first?["key"] as? String == "daily-brief")
        let field = try #require((blueprints.first?["fields"] as? [[String: Any]])?.first)
        #expect(field["isDeliver"] as? Bool == true)
        try await bridge.receive(
            #"{"id":"b2","method":"instantiateCronBlueprint","params":{"key":"daily-brief","values":{"deliver":"bot-chat"}}}"#)
        #expect(source.invocations.contains { $0 == ("instantiate:daily-brief:bot-chat", "coder") })
    }

    @Test func anUnknownJobIsRefused() async throws {
        let outbox = Outbox()
        let source = FakeCronSource(jobs: [])
        let bridge = try await openedBridge(outbox: outbox, server: BridgeServer(), source: source)
        try await bridge.receive(#"{"id":"a1","method":"pauseCronJob","params":{"id":"nope"}}"#)
        #expect(outbox.last["error"] as? String == "no cron job nope")
    }

    @Test func theModelCatalogNamesTheProviders() async throws {
        let outbox = Outbox()
        let server = BridgeServer()
        // The profile's `model.options`, as the editor's picker reads them.
        server.on("model.options") { _ in [
            "providers": [["slug": "test-provider", "name": "Test Provider", "models": ["test-model", "other-model"]]],
        ] }
        let source = FakeCronSource(jobs: [])
        let bridge = try await openedBridge(outbox: outbox, server: server, source: source)
        try await bridge.receive(#"{"id":"m1","method":"cronModelCatalog"}"#)
        let reply = outbox.last
        #expect(reply["error"] == nil)
        let providers = try #require(reply["result"] as? [String: Any])
        let provider = try #require((providers["providers"] as? [[String: Any]])?.first)
        #expect(provider["slug"] as? String == "test-provider")
        #expect((provider["models"] as? [Any])?.count == 2)
    }
}
