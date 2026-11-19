/**
 * A job's schedule as the editor shows it: one of Desktop's frequencies with the time it
 * fires, or a schedule typed by hand (`SCHEDULE_OPTIONS`, `scheduleOptionForExpr`,
 * `apps/desktop/src/app/cron/index.tsx:115-123,191-244`). Desktop fixes the presets at
 * 9:00; here the time, the weekday and the day of the month can be picked (HermesKit's
 * `CronSchedule`).
 */
export type CronFrequency = 'daily' | 'weekdays' | 'weekly' | 'monthly' | 'hourly' | 'every15Minutes' | 'custom'

export const cronFrequencies: readonly CronFrequency[] =
  ['daily', 'weekdays', 'weekly', 'monthly', 'hourly', 'every15Minutes', 'custom']

export const cronFrequencyTitles: Readonly<Record<CronFrequency, string>> = {
  daily: 'Every day',
  weekdays: 'Weekdays',
  weekly: 'Every week',
  monthly: 'Every month',
  hourly: 'Every hour',
  every15Minutes: 'Every 15 minutes',
  custom: 'Custom',
}

/** Whether the hour of day matters. */
export function frequencyHasTime(frequency: CronFrequency): boolean {
  return frequency === 'daily' || frequency === 'weekdays' || frequency === 'weekly' || frequency === 'monthly'
}

export interface CronSchedule {
  frequency: CronFrequency
  hour: number
  minute: number
  /** 0 = Sunday … 6 = Saturday, as cron counts. */
  weekday: number
  /** 1 … 28: later days are missing from some months. */
  dayOfMonth: number
  /** What the scheduler gets for `custom`: a cron expression, `"every 2h"`, `"30m"`, an ISO time. */
  custom: string
}

/** Every day at 9:00 (Desktop's default). */
export function defaultCronSchedule(): CronSchedule {
  return { frequency: 'daily', hour: 9, minute: 0, weekday: 1, dayOfMonth: 1, custom: '' }
}

/**
 * Reads a stored schedule: a five-field cron expression of one of the frequencies becomes
 * it, anything else is `custom` as written.
 */
export function parseCronSchedule(expression: string): CronSchedule {
  const normalized = expression.split(/\s+/).filter(Boolean).join(' ')
  const schedule: CronSchedule = { ...defaultCronSchedule(), frequency: 'custom', custom: normalized }
  const parts = normalized.split(' ')
  if (parts.length !== 5) return schedule
  const [m, h, dom, month, dow] = parts as [string, string, string, string, string]
  const number = (text: string, low: number, high: number): number | undefined => {
    if (!/^\d+$/.test(text)) return undefined
    const value = Number(text)
    return value >= low && value <= high ? value : undefined
  }
  if (normalized === '*/15 * * * *') return { ...schedule, frequency: 'every15Minutes' }
  const minute = number(m, 0, 59)
  if (month !== '*' || minute === undefined) return schedule
  if (h === '*') {
    if (dom !== '*' || dow !== '*') return schedule
    return { ...schedule, minute, frequency: 'hourly' }
  }
  const hour = number(h, 0, 23)
  if (hour === undefined) return schedule
  let next: CronSchedule
  if (dom === '*' && dow === '*') {
    next = { ...schedule, frequency: 'daily' }
  } else if (dom === '*' && dow === '1-5') {
    next = { ...schedule, frequency: 'weekdays' }
  } else if (dom === '*') {
    const day = number(dow, 0, 7)
    if (day === undefined) return schedule
    next = { ...schedule, weekday: day % 7, frequency: 'weekly' }
  } else if (dow === '*') {
    const day = number(dom, 1, 28)
    if (day === undefined) return schedule
    next = { ...schedule, dayOfMonth: day, frequency: 'monthly' }
  } else {
    return schedule
  }
  return { ...next, hour, minute }
}

/** What the scheduler is sent. */
export function scheduleExpression(schedule: CronSchedule): string {
  const { minute, hour } = schedule
  switch (schedule.frequency) {
    case 'daily': return `${minute} ${hour} * * *`
    case 'weekdays': return `${minute} ${hour} * * 1-5`
    case 'weekly': return `${minute} ${hour} * * ${schedule.weekday}`
    case 'monthly': return `${minute} ${hour} ${schedule.dayOfMonth} * *`
    case 'hourly': return `${minute} * * * *`
    case 'every15Minutes': return '*/15 * * * *'
    case 'custom': return schedule.custom.trim()
  }
}

/** Weekday names, Sunday first, in `locale`. */
export function weekdayNames(locale?: string): string[] {
  const format = new Intl.DateTimeFormat(locale, { weekday: 'long', timeZone: 'UTC' })
  // 2000-01-02 was a Sunday.
  return Array.from({ length: 7 }, (_, day) => format.format(Date.UTC(2000, 0, 2 + day)))
}

/** A wall-clock time in `locale` ("9:00 AM", "09:00"), never shifted by a time zone. */
export function clockTime(hour: number, minute: number, locale?: string): string {
  return new Intl.DateTimeFormat(locale, { hour: 'numeric', minute: '2-digit', timeZone: 'UTC' })
    .format(Date.UTC(2000, 0, 1, hour, minute))
}

/** The schedule in words (`scheduleSummary`, `index.tsx:246-276`); undefined for `custom`. */
export function scheduleSummary(schedule: CronSchedule, locale?: string): string | undefined {
  const time = clockTime(schedule.hour, schedule.minute, locale)
  switch (schedule.frequency) {
    case 'daily': return `Every day at ${time}`
    case 'weekdays': return `Weekdays at ${time}`
    case 'weekly': {
      const names = weekdayNames(locale)
      return `Every ${names[schedule.weekday] ?? `day ${schedule.weekday}`} at ${time}`
    }
    case 'monthly': return `Every month on day ${schedule.dayOfMonth} at ${time}`
    case 'hourly':
      return schedule.minute === 0 ? 'Every hour, on the hour' : `Every hour at :${String(schedule.minute).padStart(2, '0')}`
    case 'every15Minutes': return 'Every 15 minutes'
    case 'custom': return undefined
  }
}
