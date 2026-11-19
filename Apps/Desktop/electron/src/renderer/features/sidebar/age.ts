import { useEffect, useState } from 'react'

const format = new Intl.RelativeTimeFormat('en', { numeric: 'auto' })

/**
 * A row's age, as the Mac's `SessionRelativeTime` says it (Foundation's
 * `RelativeDateTimeFormatter`, named style): "now" under a minute, then "5 minutes
 * ago", "yesterday", "last week". Never seconds, so it changes once a minute, and
 * never in the future (the server's clock may run ahead).
 */
export function rowAge(time: number, now: number): string {
  const reference = Math.max(now, Date.now())
  const seconds = Math.max(0, (reference - time) / 1000)
  if (seconds < 60) return format.format(0, 'second')
  const minutes = Math.floor(seconds / 60)
  if (minutes < 60) return format.format(-minutes, 'minute')
  const hours = Math.floor(minutes / 60)
  if (hours < 24) return format.format(-hours, 'hour')
  const days = Math.floor(hours / 24)
  if (days < 7) return format.format(-days, 'day')
  const weeks = Math.floor(days / 7)
  if (days < 30) return format.format(-weeks, 'week')
  const months = Math.floor(days / 30)
  if (months < 12) return format.format(-months, 'month')
  return format.format(-Math.floor(days / 365), 'year')
}

/** Epoch ms, once a minute: the sidebar's one clock, which ages labels and moves date groups on. */
export function useMinuteClock(): number {
  const [now, setNow] = useState(() => Date.now())
  useEffect(() => {
    const timer = setInterval(() => setNow(Date.now()), 60_000)
    return () => clearInterval(timer)
  }, [])
  return now
}

/** The locale's first day of the week, 0 = Sunday (Intl's week info, where the engine has it). */
export function localeWeekStart(): number {
  try {
    const locale = new Intl.Locale(navigator.language) as Intl.Locale & {
      getWeekInfo?: () => { firstDay: number }; weekInfo?: { firstDay: number }
    }
    const first = locale.getWeekInfo?.().firstDay ?? locale.weekInfo?.firstDay
    return first ? first % 7 : 0
  } catch {
    return 0
  }
}
