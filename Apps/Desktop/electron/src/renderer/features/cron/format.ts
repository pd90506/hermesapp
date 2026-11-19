/** "in 2 hours", "5 minutes ago": a job's next run, as the Mac's `.relative(presentation: .named)`. */
export function relativeTo(time: number, now: number, locale?: string): string {
  const format = new Intl.RelativeTimeFormat(locale, { numeric: 'auto' })
  const seconds = Math.round((time - now) / 1000)
  const steps: Array<[Intl.RelativeTimeFormatUnit, number]> = [
    ['second', 60], ['minute', 60], ['hour', 24], ['day', 7], ['week', 4.34524], ['month', 12], ['year', Infinity],
  ]
  let value = seconds
  for (const [unit, size] of steps) {
    if (Math.abs(value) < size) return format.format(Math.round(value), unit)
    value /= size
  }
  return format.format(Math.round(value), 'year')
}

/** "Oct 19, 2026, 9:00 AM": a run's time (the Mac's abbreviated date, short time). */
export function runTime(time: number | undefined, locale?: string): string {
  if (time === undefined) return '—'
  return new Intl.DateTimeFormat(locale, { dateStyle: 'medium', timeStyle: 'short' }).format(time)
}

/** "9:00 AM": the time of day a job is overdue since. */
export function shortTime(time: number, locale?: string): string {
  return new Intl.DateTimeFormat(locale, { timeStyle: 'short' }).format(time)
}

/** `scheduled` → `Scheduled`, as the Mac's `.capitalized`. */
export function capitalized(text: string): string {
  return text.replace(/(^|[\s_-])(\p{L})/gu, (_, gap: string, letter: string) => gap + letter.toUpperCase())
}
