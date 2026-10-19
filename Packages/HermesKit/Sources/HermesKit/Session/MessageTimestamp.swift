import Foundation

/// When a message was written, as its action bar shows it after Desktop's
/// (`formatMessageTimestamp`, `apps/desktop/src/components/assistant-ui/thread/timestamp.ts:42-67`):
/// "3:27 PM" today, "Yesterday, 3:27 PM", else "Sep 28, 3:27 PM" (no year).
public enum MessageTimestamp {
    public enum Day: Sendable, Equatable {
        case today, yesterday, earlier
    }

    /// Calendar days back from `now`; a time ahead of `now` counts as today.
    public static func day(of date: Date, now: Date = Date(), calendar: Calendar = .current) -> Day {
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date),
                                           to: calendar.startOfDay(for: now)).day ?? 0
        switch days {
        case ...0: return .today
        case 1: return .yesterday
        default: return .earlier
        }
    }
}
