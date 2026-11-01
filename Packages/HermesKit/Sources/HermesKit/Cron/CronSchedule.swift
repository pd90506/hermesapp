import Foundation

/// A job's schedule as the editor shows it: one of Desktop's frequencies with the time it
/// fires, or a schedule typed by hand (`SCHEDULE_OPTIONS`, `scheduleOptionForExpr`,
/// `apps/desktop/src/app/cron/index.tsx:115-123,191-244`). Desktop fixes the presets at
/// 9:00; here the time, the weekday and the day of the month can be picked.
public struct CronSchedule: Sendable, Hashable {
    public enum Frequency: String, Sendable, CaseIterable, Identifiable {
        case daily, weekdays, weekly, monthly, hourly, every15Minutes, custom

        public var id: String { rawValue }

        public var title: String {
            switch self {
            case .daily: "Every day"
            case .weekdays: "Weekdays"
            case .weekly: "Every week"
            case .monthly: "Every month"
            case .hourly: "Every hour"
            case .every15Minutes: "Every 15 minutes"
            case .custom: "Custom"
            }
        }

        /// Whether the hour of day matters.
        public var hasTime: Bool { [.daily, .weekdays, .weekly, .monthly].contains(self) }
    }

    public var frequency: Frequency
    public var hour: Int
    public var minute: Int
    /// 0 = Sunday … 6 = Saturday, as cron counts.
    public var weekday: Int
    /// 1 … 28: later days are missing from some months.
    public var dayOfMonth: Int
    /// What the scheduler gets for `.custom`: a cron expression, `"every 2h"`, `"30m"`, an ISO time.
    public var custom: String

    public init(frequency: Frequency = .daily, hour: Int = 9, minute: Int = 0, weekday: Int = 1,
                dayOfMonth: Int = 1, custom: String = "") {
        self.frequency = frequency
        self.hour = hour
        self.minute = minute
        self.weekday = weekday
        self.dayOfMonth = dayOfMonth
        self.custom = custom
    }

    /// Reads a stored schedule: a five-field cron expression of one of the frequencies
    /// becomes it, anything else is `.custom` as written.
    public init(expression: String) {
        let normalized = expression.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        self.init(frequency: .custom, custom: normalized)
        let parts = normalized.split(separator: " ").map(String.init)
        guard parts.count == 5 else { return }
        let (m, h, dom, month, dow) = (parts[0], parts[1], parts[2], parts[3], parts[4])
        func number(_ text: String, _ range: ClosedRange<Int>) -> Int? {
            guard !text.isEmpty, text.allSatisfy(\.isASCII), let value = Int(text), range.contains(value) else { return nil }
            return value
        }
        if normalized == "*/15 * * * *" {
            frequency = .every15Minutes
            return
        }
        guard month == "*", let minute = number(m, 0...59) else { return }
        if h == "*" {
            guard dom == "*", dow == "*" else { return }
            self.minute = minute
            frequency = .hourly
            return
        }
        guard let hour = number(h, 0...23) else { return }
        switch (dom, dow) {
        case ("*", "*"): frequency = .daily
        case ("*", "1-5"): frequency = .weekdays
        case ("*", _):
            guard let day = number(dow, 0...7) else { return }
            weekday = day % 7
            frequency = .weekly
        case (_, "*"):
            guard let day = number(dom, 1...28) else { return }
            dayOfMonth = day
            frequency = .monthly
        default: return
        }
        self.hour = hour
        self.minute = minute
    }

    /// What the scheduler is sent.
    public var expression: String {
        switch frequency {
        case .daily: "\(minute) \(hour) * * *"
        case .weekdays: "\(minute) \(hour) * * 1-5"
        case .weekly: "\(minute) \(hour) * * \(weekday)"
        case .monthly: "\(minute) \(hour) \(dayOfMonth) * *"
        case .hourly: "\(minute) * * * *"
        case .every15Minutes: "*/15 * * * *"
        case .custom: custom.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    /// The schedule in words (`scheduleSummary`, `index.tsx:246-276`); `nil` for `.custom`.
    public func summary(locale: Locale = .current, calendar: Calendar = .current) -> String? {
        var calendar = calendar
        calendar.locale = locale
        let time = Self.time(hour: hour, minute: minute, locale: locale)
        switch frequency {
        case .daily: return "Every day at \(time)"
        case .weekdays: return "Weekdays at \(time)"
        case .weekly:
            let names = calendar.weekdaySymbols
            return "Every \(names.indices.contains(weekday) ? names[weekday] : "day \(weekday)") at \(time)"
        case .monthly: return "Every month on day \(dayOfMonth) at \(time)"
        case .hourly: return minute == 0 ? "Every hour, on the hour" : "Every hour at :\(String(format: "%02d", minute))"
        case .every15Minutes: return "Every 15 minutes"
        case .custom: return nil
        }
    }

    static func time(hour: Int, minute: Int, locale: Locale) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let date = calendar.date(from: DateComponents(year: 2000, month: 1, day: 1, hour: hour, minute: minute)) ?? Date()
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = calendar.timeZone
        formatter.setLocalizedDateFormatFromTemplate("jmm")
        return formatter.string(from: date)
    }
}
