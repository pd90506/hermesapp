import Foundation

/// A dated group of the session list, below its unlabelled head.
///
/// Ported from Hermes Desktop (`apps/desktop/src/lib/time.ts:61-170`, `calendarBucket`):
/// coarse, non-overlapping calendar ranges whose granularity coarsens with age, one group
/// per range, never one per day. Empty ranges never show, so a sparse tail jumps straight
/// to its month.
public enum SessionDateBucket: Sendable, Hashable {
    case today
    case yesterday
    case thisWeek
    case lastWeek
    case thisMonth
    /// A month of this year.
    case month(year: Int, month: Int)
    /// A month of an earlier year.
    case monthYear(year: Int, month: Int)

    public var id: String {
        switch self {
        case .today: "today"
        case .yesterday: "yesterday"
        case .thisWeek: "this-week"
        case .lastWeek: "last-week"
        case .thisMonth: "this-month"
        case .month(let year, let month): "m-\(year)-\(month)"
        case .monthYear(let year, let month): "my-\(year)-\(month)"
        }
    }

    /// Desktop's labels (`apps/desktop/src/i18n/en.ts:3255-3259`); months by name, with
    /// the year when it isn't this one.
    public func title(calendar: Calendar = .current) -> String {
        switch self {
        case .today: "Earlier today"
        case .yesterday: "Yesterday"
        case .thisWeek: "Earlier this week"
        case .lastWeek: "Last week"
        case .thisMonth: "Earlier this month"
        case .month(_, let month): Self.monthName(month, calendar)
        case .monthYear(let year, let month): "\(Self.monthName(month, calendar)) \(year)"
        }
    }

    private static func monthName(_ month: Int, _ calendar: Calendar) -> String {
        let names = calendar.standaloneMonthSymbols
        return names.indices.contains(month - 1) ? names[month - 1] : "\(month)"
    }
}

/// A run of the session list: the head (`bucket == nil`), then one per dated range.
public struct SessionDateGroup<Item> {
    /// Nil for the first group, which is never labelled (Desktop's first-group rule).
    public var bucket: SessionDateBucket?
    public var items: [Item]

    public var id: String { bucket?.id ?? "recent" }
}

extension SessionDateGroup: Sendable where Item: Sendable {}
extension SessionDateGroup: Equatable where Item: Equatable {}

/// Splits the session list into Desktop's date groups (`apps/desktop/src/lib/session-date-groups.ts`).
///
/// - The head is the newest run of sessions, cut at a real break in activity, aiming at
///   about five rows; it is never labelled.
/// - Below it, `SessionDateBucket` ranges: earlier today → yesterday → earlier this week →
///   last week → earlier this month → month → month and year.
/// - The day ends at 4 AM, not midnight: a 12:30 AM session belongs with the evening before.
///
/// `[client choice]` Desktop buckets on a row's `last_active`; `session.list` rows carry no
/// such field (`_session_row_summary`, `tui_gateway/methods_session.py:110-122`), only the
/// order by it (`:148`). So the times are each row's newest message, as the row shows it
/// (`SessionRowTimestamp`), read lazily; a row not read yet keeps the group of the row
/// above it, which the order makes at least as recent.
public enum SessionDateGrouping {
    static let dayRollover: TimeInterval = 4 * 3600
    static let targetHeadCount = 5.0
    static let minRunBreak: TimeInterval = 30 * 60
    static let maxRunGap: TimeInterval = 8 * 3600

    /// `items` in list order (newest activity first), with the newest message time read for
    /// each so far (`nil` when not read yet).
    public static func groups<Item>(_ items: [Item], times: [Date?], now: Date = .now,
                                    calendar: Calendar = .current) -> [SessionDateGroup<Item>] {
        let times = effectiveTimes(times, count: items.count)
        let known = times.compactMap { $0 }
        let cutoff = headCutoff(known, now: now, calendar: calendar)
        var groups: [SessionDateGroup<Item>] = []
        var lastKey: String?
        for (item, time) in zip(items, times) {
            var bucket: SessionDateBucket?
            let key: String
            if let time, cutoff.map({ time < $0 }) ?? false {
                let dated = self.bucket(for: time, now: now, calendar: calendar)
                bucket = dated
                key = dated.id
            } else {
                key = "recent"
            }
            if key != lastKey {
                lastKey = key
                groups.append(SessionDateGroup(bucket: groups.isEmpty ? nil : bucket, items: []))
            }
            groups[groups.count - 1].items.append(item)
        }
        return groups
    }

    /// Each row's time, never newer than the row above it (the list's own order): a row
    /// not read yet takes the time of the row above; one that leads the list stays `nil`,
    /// in the head.
    static func effectiveTimes(_ times: [Date?], count: Int) -> [Date?] {
        var result: [Date?] = []
        var above: Date?
        for index in 0..<count {
            let own = times.indices.contains(index) ? times[index] : nil
            let time: Date? = switch (own, above) {
            case let (own?, above?): min(own, above)
            case let (own?, nil): own
            case let (nil, above): above
            }
            result.append(time)
            above = time
        }
        return result
    }

    /// The oldest time still in the head (`session-date-groups.ts:43-89`): `nil` when the
    /// head holds every row, `.distantFuture` when there is no head. `times` newest first.
    static func headCutoff(_ times: [Date], now: Date, calendar: Calendar) -> Date? {
        var best: Int?
        var bestScore = Double.infinity
        var runEnded = false
        for index in times.indices.dropFirst() {
            let gap = times[index - 1].timeIntervalSince(times[index])
            let endsRun = gap > maxRunGap
            if gap >= minRunBreak || endsRun {
                // `index` rows would sit above a cut at this gap.
                let score = abs(log(Double(index) / targetHeadCount))
                if score < bestScore {
                    bestScore = score
                    best = index
                    runEnded = endsRun
                }
            }
            if endsRun { break }
        }
        guard let best else { return nil }
        // A head that is only the top of the group under it adds nothing: no head.
        if runEnded && bucket(for: times[0], now: now, calendar: calendar)
            == bucket(for: times[best], now: now, calendar: calendar) {
            return .distantFuture
        }
        return times[best - 1]
    }

    /// `calendarBucket` (`apps/desktop/src/lib/time.ts:128-167`).
    public static func bucket(for date: Date, now: Date = .now, calendar: Calendar = .current) -> SessionDateBucket {
        let day = nominalDayStart(date, calendar)
        let today = nominalDayStart(now, calendar)
        let dayDiff = calendar.dateComponents([.day], from: day, to: today).day ?? 0
        if dayDiff <= 0 { return .today }
        if dayDiff == 1 { return .yesterday }
        if let weekStart = calendar.dateInterval(of: .weekOfYear, for: today)?.start {
            if day >= weekStart { return .thisWeek }
            if let lastWeek = calendar.date(byAdding: .day, value: -7, to: weekStart), day >= lastWeek {
                return .lastWeek
            }
        }
        let parts = calendar.dateComponents([.year, .month], from: day)
        let nowParts = calendar.dateComponents([.year, .month], from: today)
        let year = parts.year ?? 0
        let month = parts.month ?? 0
        guard year == nowParts.year else { return .monthYear(year: year, month: month) }
        return month == nowParts.month ? .thisMonth : .month(year: year, month: month)
    }

    /// The start of the day `date` belongs to, with the day ending at 4 AM.
    static func nominalDayStart(_ date: Date, _ calendar: Calendar) -> Date {
        calendar.startOfDay(for: date.addingTimeInterval(-dayRollover))
    }
}
