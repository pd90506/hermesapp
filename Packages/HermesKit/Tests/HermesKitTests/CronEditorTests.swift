import Foundation
import HermesProtocol
import Testing

@testable import HermesKit

/// The New and Edit Cron Job form, after Desktop's `CronEditorDialog`
/// (`apps/desktop/src/app/cron/index.tsx`, `cron-job-model.ts`).
@Suite struct CronScheduleTests {
    /// `scheduleOptionForExpr` (`index.tsx:191-244`), with the time, weekday and day kept.
    @Test(arguments: [
        ("0 9 * * *", CronSchedule.Frequency.daily, "0 9 * * *"),
        ("30  7 * * 1-5", .weekdays, "30 7 * * 1-5"),
        ("15 18 * * 5", .weekly, "15 18 * * 5"),
        ("0 8 * * 7", .weekly, "0 8 * * 0"),
        ("0 6 12 * *", .monthly, "0 6 12 * *"),
        ("45 * * * *", .hourly, "45 * * * *"),
        ("*/15 * * * *", .every15Minutes, "*/15 * * * *"),
        ("every 2h", .custom, "every 2h"),
        ("0 9,17 * * *", .custom, "0 9,17 * * *"),
        ("0 9 31 * *", .custom, "0 9 31 * *"),
        ("0 9 1 * 1", .custom, "0 9 1 * 1"),
    ])
    func readsStoredSchedules(expression: String, frequency: CronSchedule.Frequency, written: String) {
        let schedule = CronSchedule(expression: expression)
        #expect(schedule.frequency == frequency)
        #expect(schedule.expression == written)
    }

    @Test func picksTheTimeWeekdayAndDay() {
        var schedule = CronSchedule(expression: "15 18 * * 5")
        #expect((schedule.hour, schedule.minute, schedule.weekday) == (18, 15, 5))
        schedule.frequency = .monthly
        schedule.dayOfMonth = 3
        #expect(schedule.expression == "15 18 3 * *")
        schedule.frequency = .hourly
        #expect(schedule.expression == "15 * * * *")
    }

    @Test func summaries() {
        let us = Locale(identifier: "en_US")
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = us
        // The formatter puts a narrow no-break space before AM/PM.
        func summary(_ expression: String) -> String? {
            CronSchedule(expression: expression).summary(locale: us, calendar: calendar)?
                .replacingOccurrences(of: "\u{202F}", with: " ")
        }
        #expect(summary("0 9 * * *") == "Every day at 9:00 AM")
        #expect(summary("30 7 * * 1-5") == "Weekdays at 7:30 AM")
        #expect(summary("0 18 * * 1") == "Every Monday at 6:00 PM")
        #expect(summary("0 9 1 * *") == "Every month on day 1 at 9:00 AM")
        #expect(CronSchedule(expression: "0 * * * *").summary(locale: us) == "Every hour, on the hour")
        #expect(CronSchedule(expression: "5 * * * *").summary(locale: us) == "Every hour at :05")
        #expect(CronSchedule(expression: "every 2h").summary(locale: us) == nil)
    }
}

@Suite struct CronJobDraftTests {
    private let stored = CronJob(id: "a1", name: "Brief", prompt: "Summarize", deliver: "local,telegram",
                                 scheduleDisplay: "0 9 * * *", scheduleExpression: "0 9 * * *",
                                 model: "gpt-5", provider: "openai")

    /// `validateCronEditor` (`cron-job-model.ts:25-42`).
    @Test func problems() {
        var draft = CronJobDraft()
        #expect(draft.problem == .prompt)
        draft.schedule.frequency = .custom
        #expect(draft.problem == .promptAndSchedule)
        draft.prompt = "  Check  "
        #expect(draft.problem == .schedule)
        draft.schedule.custom = "every 2h"
        #expect(draft.problem == nil)
        let script = CronJob(id: "s", script: "check.sh", noAgent: true, scheduleExpression: "30m")
        #expect(CronJobDraft(script).isScriptOnly)
        #expect(CronJobDraft(script).problem == nil, "a script-only job needs no prompt")
    }

    /// `CronJobCreate` (`hermes_cli/web_models.py:316-336`): a model only when one is picked.
    @Test func createBody() {
        var draft = CronJobDraft()
        draft.prompt = " Summarize the news "
        draft.setDelivery("bot-chat", on: true)
        #expect(draft.createBody == ["prompt": "Summarize the news", "schedule": "0 9 * * *",
                                     "deliver": "local,bot-chat"])
        draft.name = "Brief"
        draft.model = ModelChoice(provider: "openai", model: "gpt-5")
        #expect(draft.createBody["name"] == "Brief")
        #expect(draft.createBody["model"] == "gpt-5")
        #expect(draft.createBody["provider"] == "openai")
    }

    /// `cronEditorUpdates` (`cron-job-model.ts:137-158`): the default model clears a pin.
    @Test func updates() {
        var draft = CronJobDraft(stored)
        #expect(draft.model == ModelChoice(provider: "openai", model: "gpt-5"))
        #expect(draft.deliveryTargets == ["local", "telegram"])
        #expect(draft.schedule.frequency == .daily)
        draft.model = nil
        draft.schedule.hour = 7
        #expect(draft.updates == ["deliver": "local,telegram", "name": "Brief", "schedule": "0 7 * * *",
                                  "prompt": "Summarize", "model": nil, "provider": nil])

        let script = CronJobDraft(CronJob(id: "s", script: "check.sh", noAgent: true,
                                          scheduleExpression: "every 30m", model: "kept"))
        #expect(script.updates == ["deliver": "local", "name": "", "schedule": "every 30m"],
                "a script-only job keeps its empty prompt and stored model")
    }

    @Test func readsTheStoredShape() throws {
        let json = #"{"id":"j","prompt":"x","model":"gpt-5","provider":"openai","no_agent":false,"script":null,"schedule":{"kind":"interval","minutes":120,"display":"every 120m"},"schedule_display":"every 120m"}"#
        let job = try JSONDecoder().decode(CronJob.self, from: Data(json.utf8))
        #expect(job.scheduleExpression == "every 120m", "an interval has no expr: the display form")
        #expect(job.model == "gpt-5")
        #expect(job.provider == "openai")
        #expect(!job.isScriptOnly)
    }
}

@Suite struct CronBlueprintTests {
    /// `blueprint_catalog_entry` rows (`hermes_cli/web_routers/cron.py:870-888`).
    @Test func decodesAndSeedsDefaults() throws {
        let json = #"""
            {"blueprints":[{"key":"morning-brief","title":"Morning brief","description":"News at breakfast",
              "category":"daily","tags":[],"command":"","appUrl":"","source":"builtin","plugin":null,
              "fields":[
                {"name":"time","type":"time","label":"Time","default":"08:00","options":[],"optional":false,"help":"When"},
                {"name":"days","type":"weekdays","label":"Days","default":"weekdays","options":["daily","weekdays"],"optional":false,"help":""},
                {"name":"topic","type":"text","label":"Topic","default":null,"options":[],"optional":true,"help":"e.g. AI"},
                {"name":"deliver","type":"enum","label":"Deliver to","default":"origin","options":["origin","local"],"optional":false,"help":""},
                {"name":"odd","type":"slider","label":"Odd"}]}]}
            """#
        struct Answer: Decodable { var blueprints: [CronBlueprint] }
        let blueprint = try #require(try JSONDecoder().decode(Answer.self, from: Data(json.utf8)).blueprints.first)
        #expect(blueprint.fields.map(\.kind) == [.time, .weekdays, .text, .enum, .text])
        #expect(blueprint.fields[3].isDeliver)
        #expect(blueprint.initialValues == ["time": "08:00", "days": "weekdays", "topic": "", "deliver": "local",
                                            "odd": ""])
    }
}

@Suite(.timeLimit(.minutes(1))) struct CronEditorRequestTests {
    private func connector(_ http: FakeHTTP) throws -> DashboardConnector {
        DashboardConnector(endpoint: try GatewayEndpoint("https://hermes.example.ts.net"),
                           credential: .bearer(accessToken: "tok"), http: http)
    }

    @Test func createsReadsBlueprintsAndInstantiates() async throws {
        let http = FakeHTTP([
            .init(status: 200, body: #"{"id":"n1","name":"Brief"}"#),
            .init(status: 200, body: #"{"blueprints":[{"key":"morning-brief","title":"Morning brief","fields":[]}]}"#),
            .init(status: 422, body: #"{"detail":"time: expected HH:MM"}"#),
        ])
        let source = try connector(http)
        let job = try await source.createCronJob(profile: "coder", body: ["prompt": "x", "schedule": "0 9 * * *"])
        #expect(job.id == "n1")
        #expect(try await source.cronBlueprints(profile: "coder").map(\.key) == ["morning-brief"])
        await #expect(throws: CronRequestError(status: 422, detail: "time: expected HH:MM")) {
            _ = try await source.instantiateCronBlueprint("morning-brief", values: ["time": "8"], profile: "coder")
        }
        #expect(http.requests.map { "\($0.httpMethod ?? "") \($0.url?.absoluteString ?? "")" } == [
            "POST https://hermes.example.ts.net/api/cron/jobs?profile=coder",
            "GET https://hermes.example.ts.net/api/cron/blueprints?profile=coder",
            "POST https://hermes.example.ts.net/api/cron/blueprints/instantiate?profile=coder",
        ])
        let body = try JSONDecoder().decode(JSONValue.self, from: try #require(http.requests[2].httpBody))
        #expect(body == ["blueprint": "morning-brief", "values": ["time": "8"]])
    }
}

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct CronEditorBoardTests {
    private func connect(_ source: FakeCronSource) async throws -> GatewayConnection {
        let gateway = ScriptedGateway()
        gateway.on("profiles.list", result: [
            "profiles": [profileRowPayload("default", isDefault: true), profileRowPayload("coder")],
            "bot_mode_protocol": true, "install_id": "test",
        ])
        let connection = try await gateway.withDefaults().connect(cron: source)
        try #require(await eventually { connection.listsRefreshTask == nil && !connection.listsRefreshQueued })
        connection.selectListProfile("coder")
        await connection.refreshCronJobs()
        return connection
    }

    @Test func createsAndEditsInTheListProfile() async throws {
        let source = FakeCronSource(["coder": [CronJob(id: "a", name: "Brief", deliver: "local")]])
        let connection = try await connect(source)
        var draft = CronJobDraft()
        draft.name = "News"
        draft.prompt = "Summarize"
        try await connection.createCronJob(draft)
        #expect(connection.cron.jobs.map(\.id).sorted() == ["a", "new0"], "the list is read again")
        #expect(source.created.first?["schedule"] == "0 9 * * *")

        let job = try #require(connection.cron.jobs.first { $0.id == "a" })
        var edit = CronJobDraft(job)
        edit.setDelivery("bot-chat", on: true)
        try await connection.saveCronJob(job, edit)
        #expect(source.updates.last?["deliver"] == "local,bot-chat")
        #expect(connection.cron.jobs.first { $0.id == "a" }?.deliversToBotChat == true)
    }

    @Test func blueprintsOncePerProfile() async throws {
        let blueprint = CronBlueprint(key: "morning-brief", title: "Morning brief")
        let source = FakeCronSource(["coder": []], blueprints: [blueprint])
        let connection = try await connect(source)
        await connection.loadCronBlueprints()
        await connection.loadCronBlueprints()
        #expect(connection.cron.blueprints == [blueprint])
        try await connection.createCronJob(from: blueprint, values: ["time": "08:00"])
        #expect(connection.cron.jobs.map(\.id) == ["bp-morning-brief"])
        #expect(source.calls.filter { $0.hasPrefix("blueprints") } == ["blueprints coder"])
        #expect(source.calls.contains("instantiate morning-brief time=08:00"))
    }
}
