import Foundation
import HermesProtocol
import Testing

@testable import HermesKit

/// `Packages/fixtures/cron-jobs.json`, which the desktop app's TypeScript core checks too
/// (`Packages/hermes-core/tests/cron/shared-fixtures.test.ts`).
@Suite struct CronFixtureTests {
    private let fixture: JSONValue

    init() throws {
        fixture = try SharedFixtureTests.load("cron-jobs.json", as: JSONValue.self)
    }

    /// Milliseconds since the epoch, as the fixture writes times.
    private func date(_ value: JSONValue?) -> Date? {
        value?.doubleValue.map { Date(timeIntervalSince1970: $0 / 1000) }
    }

    @Test func readsJobs() throws {
        for item in fixture["jobs"]?.arrayValue ?? [] {
            let row = try JSONEncoder().encode(try #require(item["row"]))
            let job = try JSONDecoder().decode(CronJob.self, from: row)
            let expected = try #require(item["expected"])
            let id = expected["id"]?.stringValue
            #expect(job.id == id)
            #expect(job.title == expected["title"]?.stringValue, "\(id ?? "")")
            #expect(job.scheduleDisplay == expected["scheduleDisplay"]?.stringValue, "\(id ?? "")")
            #expect(job.scheduleExpression == expected["scheduleExpression"]?.stringValue, "\(id ?? "")")
            #expect(job.effectiveState == expected["state"]?.stringValue, "\(id ?? "")")
            #expect(job.deliveryTargets == expected["deliveryTargets"]?.arrayValue?.compactMap(\.stringValue), "\(id ?? "")")
            #expect(job.deliversToBotChat == expected["deliversToBotChat"]?.boolValue, "\(id ?? "")")
            #expect(job.nextRunAt == date(expected["nextRunAt"]), "\(id ?? "")")
            #expect(job.lastRunAt == date(expected["lastRunAt"]), "\(id ?? "")")
            #expect(job.isScriptOnly == expected["isScriptOnly"]?.boolValue, "\(id ?? "")")
            #expect(job.model == expected["model"]?.stringValue, "\(id ?? "")")
        }
    }

    @Test func schedules() throws {
        for item in fixture["schedules"]?.arrayValue ?? [] {
            let expression = try #require(item["expression"]?.stringValue)
            let schedule = CronSchedule(expression: expression)
            #expect(schedule.frequency.rawValue == item["frequency"]?.stringValue, "\(expression)")
            if let hour = item["hour"]?.intValue { #expect(schedule.hour == hour, "\(expression)") }
            if let minute = item["minute"]?.intValue { #expect(schedule.minute == minute, "\(expression)") }
            if let weekday = item["weekday"]?.intValue { #expect(schedule.weekday == weekday, "\(expression)") }
            if let day = item["dayOfMonth"]?.intValue { #expect(schedule.dayOfMonth == day, "\(expression)") }
            #expect(schedule.expression == item["back"]?.stringValue, "\(expression)")
        }
    }

    @Test func deliveryToggles() throws {
        for item in fixture["toggles"]?.arrayValue ?? [] {
            let job = CronJob(id: "j", deliver: item["deliver"]?.stringValue)
            let target = try #require(item["target"]?.stringValue)
            let on = try #require(item["on"]?.boolValue)
            #expect(job.deliver(toggling: target, on: on) == item["result"]?.stringValue, "\(target)")
        }
    }

    @Test func runSessionIDs() throws {
        for item in fixture["runSessionIDs"]?.arrayValue ?? [] {
            let id = try #require(item["id"]?.stringValue)
            #expect(CronRun.isRunSessionID(id) == item["run"]?.boolValue, "\(id)")
        }
    }
}
