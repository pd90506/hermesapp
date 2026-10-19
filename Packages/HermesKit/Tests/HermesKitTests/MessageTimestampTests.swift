import Foundation
import Testing

@testable import HermesKit

@Suite struct MessageTimestampTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        return calendar
    }

    private func date(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute))!
    }

    @Test func daysAreCalendarDaysNotTwentyFourHours() {
        let now = date(19, 0, 30)
        #expect(MessageTimestamp.day(of: date(19, 0, 5), now: now, calendar: calendar) == .today)
        // Twenty minutes ago, but before midnight.
        #expect(MessageTimestamp.day(of: date(18, 23, 50), now: now, calendar: calendar) == .yesterday)
        #expect(MessageTimestamp.day(of: date(18, 0, 1), now: now, calendar: calendar) == .yesterday)
        #expect(MessageTimestamp.day(of: date(17, 23, 59), now: now, calendar: calendar) == .earlier)
        // Another device's clock a little ahead.
        #expect(MessageTimestamp.day(of: date(19, 0, 31), now: now, calendar: calendar) == .today)
    }
}
