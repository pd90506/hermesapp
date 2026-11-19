/**
 * The session list's date groups, ported from HermesKit's `SessionDateGrouping`, itself
 * from Hermes Desktop (`apps/desktop/src/lib/time.ts:61-170`, `calendarBucket`, and
 * `apps/desktop/src/lib/session-date-groups.ts`): coarse, non-overlapping calendar
 * ranges whose granularity coarsens with age, one group per range. The first group is
 * the newest run of rows, cut at a real break in activity and never labelled. The day
 * ends at 4 AM, not midnight.
 *
 * Times are each row's list date (`SessionRowActivity.listDate`), read lazily; a row not
 * read yet keeps the group of the row above it, which the order makes at least as recent.
 */
export type SessionDateBucket =
  | { kind: 'today' }
  | { kind: 'yesterday' }
  | { kind: 'thisWeek' }
  | { kind: 'lastWeek' }
  | { kind: 'thisMonth' }
  /** A month of this year; `month` 1…12. */
  | { kind: 'month'; year: number; month: number }
  /** A month of an earlier year. */
  | { kind: 'monthYear'; year: number; month: number }

export interface SessionDateGroup<T> {
  /** Undefined for the first group, which is never labelled. */
  bucket?: SessionDateBucket
  items: T[]
  id: string
}

const monthNames = ['January', 'February', 'March', 'April', 'May', 'June', 'July', 'August', 'September',
  'October', 'November', 'December']

export function bucketID(bucket: SessionDateBucket): string {
  switch (bucket.kind) {
    case 'today': return 'today'
    case 'yesterday': return 'yesterday'
    case 'thisWeek': return 'this-week'
    case 'lastWeek': return 'last-week'
    case 'thisMonth': return 'this-month'
    case 'month': return `m-${bucket.year}-${bucket.month}`
    case 'monthYear': return `my-${bucket.year}-${bucket.month}`
  }
}

/** Desktop's labels (`apps/desktop/src/i18n/en.ts:3255-3259`). */
export function bucketTitle(bucket: SessionDateBucket): string {
  switch (bucket.kind) {
    case 'today': return 'Earlier today'
    case 'yesterday': return 'Yesterday'
    case 'thisWeek': return 'Earlier this week'
    case 'lastWeek': return 'Last week'
    case 'thisMonth': return 'Earlier this month'
    case 'month': return monthNames[bucket.month - 1] ?? String(bucket.month)
    case 'monthYear': return `${monthNames[bucket.month - 1] ?? bucket.month} ${bucket.year}`
  }
}

const hour = 3600_000
export const dayRollover = 4 * hour
const targetHeadCount = 5
const minRunBreak = 30 * 60_000
const maxRunGap = 8 * hour

export interface CalendarOptions {
  /** The first day of the week, 0 = Sunday (the locale's; Sunday by default). */
  weekStart?: number
}

/**
 * Splits `items` (list order, newest first) into the date groups, by `times` (epoch
 * milliseconds, undefined when not read yet).
 */
export function sessionDateGroups<T>(items: readonly T[], times: readonly (number | undefined)[], now: number,
  options: CalendarOptions = {}): SessionDateGroup<T>[] {
  const effective = effectiveTimes(times, items.length)
  const known = effective.filter((time): time is number => time !== undefined)
  const cutoff = headCutoff(known, now, options)
  const groups: SessionDateGroup<T>[] = []
  let lastKey: string | undefined
  items.forEach((item, index) => {
    const time = effective[index]
    let bucket: SessionDateBucket | undefined
    let key = 'recent'
    if (time !== undefined && cutoff !== undefined && time < cutoff) {
      bucket = dateBucket(time, now, options)
      key = bucketID(bucket)
    }
    if (key !== lastKey) {
      lastKey = key
      const head = groups.length === 0
      groups.push({ ...(head || !bucket ? {} : { bucket }), items: [], id: head || !bucket ? 'recent' : key })
    }
    groups[groups.length - 1]!.items.push(item)
  })
  return groups
}

/** Each row's time, never newer than the row above it. */
export function effectiveTimes(times: readonly (number | undefined)[], count: number): (number | undefined)[] {
  const result: (number | undefined)[] = []
  let above: number | undefined
  for (let index = 0; index < count; index++) {
    const own = times[index]
    const time = own !== undefined && above !== undefined ? Math.min(own, above) : own ?? above
    result.push(time)
    above = time
  }
  return result
}

/**
 * The oldest time still in the head: undefined when the head holds every row,
 * +Infinity when there is no head. `times` newest first.
 */
export function headCutoff(times: readonly number[], now: number, options: CalendarOptions = {}): number | undefined {
  let best: number | undefined
  let bestScore = Infinity
  let runEnded = false
  for (let index = 1; index < times.length; index++) {
    const gap = times[index - 1]! - times[index]!
    const endsRun = gap > maxRunGap
    if (gap >= minRunBreak || endsRun) {
      const score = Math.abs(Math.log(index / targetHeadCount))
      if (score < bestScore) {
        bestScore = score
        best = index
        runEnded = endsRun
      }
    }
    if (endsRun) break
  }
  if (best === undefined) return undefined
  if (runEnded && bucketID(dateBucket(times[0]!, now, options)) === bucketID(dateBucket(times[best]!, now, options))) {
    return Infinity
  }
  return times[best - 1]
}

/** `calendarBucket` (`apps/desktop/src/lib/time.ts:128-167`), in local time. */
export function dateBucket(time: number, now: number, options: CalendarOptions = {}): SessionDateBucket {
  const day = nominalDayStart(time)
  const today = nominalDayStart(now)
  const dayDiff = calendarDays(day, today)
  if (dayDiff <= 0) return { kind: 'today' }
  if (dayDiff === 1) return { kind: 'yesterday' }
  const weekStart = startOfWeek(today, options.weekStart ?? 0)
  if (day >= weekStart) return { kind: 'thisWeek' }
  const lastWeek = new Date(weekStart)
  lastWeek.setDate(lastWeek.getDate() - 7)
  if (day >= lastWeek) return { kind: 'lastWeek' }
  const year = day.getFullYear()
  const month = day.getMonth() + 1
  if (year !== today.getFullYear()) return { kind: 'monthYear', year, month }
  return month === today.getMonth() + 1 ? { kind: 'thisMonth' } : { kind: 'month', year, month }
}

/** The local start of the day `time` belongs to, the day ending at 4 AM. */
function nominalDayStart(time: number): Date {
  const date = new Date(time - dayRollover)
  return new Date(date.getFullYear(), date.getMonth(), date.getDate())
}

/** Whole calendar days from `from` to `to`, both local midnights (DST-safe). */
function calendarDays(from: Date, to: Date): number {
  const utc = (date: Date) => Date.UTC(date.getFullYear(), date.getMonth(), date.getDate())
  return Math.round((utc(to) - utc(from)) / 86_400_000)
}

function startOfWeek(day: Date, weekStart: number): Date {
  const back = (day.getDay() - weekStart + 7) % 7
  return new Date(day.getFullYear(), day.getMonth(), day.getDate() - back)
}
