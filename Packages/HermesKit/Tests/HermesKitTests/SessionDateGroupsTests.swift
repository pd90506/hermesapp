import Foundation
import Testing
@testable import HermesKit

struct SessionDateGroupsTests {
    /// Weeks start on Sunday, as in the US locale; the zone is fixed so the tests don't
    /// depend on the machine's.
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        calendar.firstWeekday = 1
        calendar.locale = Locale(identifier: "en_US")
        return calendar
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 12, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    /// Tuesday, 27 October 2026, 3 PM.
    private var now: Date { date(2026, 10, 27, 15) }

    @Test func bucketsCoarsenWithAge() {
        let bucket = { SessionDateGrouping.bucket(for: $0, now: now, calendar: calendar) }
        #expect(bucket(date(2026, 10, 27, 9)) == .today)
        #expect(bucket(date(2026, 10, 26, 9)) == .yesterday)
        // Sunday starts the week.
        #expect(bucket(date(2026, 10, 25, 9)) == .thisWeek)
        #expect(bucket(date(2026, 10, 24, 9)) == .lastWeek)
        #expect(bucket(date(2026, 10, 18, 9)) == .lastWeek)
        #expect(bucket(date(2026, 10, 17, 9)) == .thisMonth)
        #expect(bucket(date(2026, 9, 30)) == .month(year: 2026, month: 9))
        #expect(bucket(date(2025, 12, 1)) == .monthYear(year: 2025, month: 12))
    }

    @Test func theDayEndsAtFourInTheMorning() {
        let bucket = { SessionDateGrouping.bucket(for: $0, now: now, calendar: calendar) }
        // 1 AM today belongs to yesterday evening; 4 AM starts today.
        #expect(bucket(date(2026, 10, 27, 1)) == .yesterday)
        #expect(bucket(date(2026, 10, 27, 4)) == .today)
        // At 2 AM it is still yesterday: a session from 11 PM is "today".
        let lateNight = date(2026, 10, 28, 2)
        #expect(SessionDateGrouping.bucket(for: date(2026, 10, 27, 23), now: lateNight, calendar: calendar) == .today)
    }

    @Test func titlesFollowDesktop() {
        #expect(SessionDateBucket.today.title(calendar: calendar) == "Earlier today")
        #expect(SessionDateBucket.lastWeek.title(calendar: calendar) == "Last week")
        #expect(SessionDateBucket.month(year: 2026, month: 9).title(calendar: calendar) == "September")
        #expect(SessionDateBucket.monthYear(year: 2025, month: 12).title(calendar: calendar) == "December 2025")
    }

    @Test func headIsTheNewestRunCutAtARealBreak() {
        // Six sessions a few minutes apart, then an hour's break, then two older ones today.
        let times: [Date?] = [
            date(2026, 10, 27, 14, 50), date(2026, 10, 27, 14, 45), date(2026, 10, 27, 14, 40),
            date(2026, 10, 27, 14, 35), date(2026, 10, 27, 14, 30), date(2026, 10, 27, 14, 25),
            date(2026, 10, 27, 13, 0), date(2026, 10, 27, 10, 0),
            date(2026, 10, 26, 20, 0),
        ]
        let groups = SessionDateGrouping.groups(Array(0..<times.count), times: times, now: now, calendar: calendar)
        #expect(groups.map(\.bucket) == [nil, .today, .yesterday])
        #expect(groups.map(\.items) == [[0, 1, 2, 3, 4, 5], [6, 7], [8]])
    }

    @Test func aBurstIsNeverSliced() {
        // An unbroken run is one head, however long.
        let times: [Date?] = (0..<12).map { date(2026, 10, 27, 14, 55 - $0 * 2) }
        let groups = SessionDateGrouping.groups(Array(0..<12), times: times, now: now, calendar: calendar)
        #expect(groups.count == 1)
        #expect(groups[0].bucket == nil)
    }

    @Test func aHeadThatIsOnlyTheTopOfItsGroupDissolves() {
        // Two sessions from last week, a day apart: the run ends at once, and both sit in
        // the same range, so there is no head; the first group is still unlabelled.
        let times: [Date?] = [date(2026, 10, 22), date(2026, 10, 21), date(2026, 9, 2)]
        let groups = SessionDateGrouping.groups(Array(0..<3), times: times, now: now, calendar: calendar)
        #expect(groups.map(\.bucket) == [nil, .month(year: 2026, month: 9)])
        #expect(groups.map(\.items) == [[0, 1], [2]])
    }

    @Test func rowsNotReadYetKeepTheGroupAbove() {
        let times: [Date?] = [nil, date(2026, 10, 27, 14), nil, date(2026, 10, 20), nil, nil]
        let groups = SessionDateGrouping.groups(Array(0..<6), times: times, now: now, calendar: calendar)
        #expect(groups.map(\.bucket) == [nil, .lastWeek])
        #expect(groups.map(\.items) == [[0, 1, 2], [3, 4, 5]])
    }

    @Test func aTimeNewerThanTheRowAboveFollowsTheListOrder() {
        // The server orders by last activity; a row can't be newer than the one above it.
        let times: [Date?] = [date(2026, 9, 1), date(2026, 10, 27, 14)]
        #expect(SessionDateGrouping.effectiveTimes(times, count: 2) == [date(2026, 9, 1), date(2026, 9, 1)])
    }

    @Test func nothingReadIsOneGroup() {
        let groups = SessionDateGrouping.groups(["a", "b"], times: [nil, nil], now: now, calendar: calendar)
        #expect(groups == [SessionDateGroup(bucket: nil, items: ["a", "b"])])
        #expect(SessionDateGrouping.groups([String](), times: [], now: now, calendar: calendar).isEmpty)
    }
}
