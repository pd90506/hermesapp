const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec']

/**
 * "Now", "5 minutes ago", "Yesterday", or the date: a session row's time, as the
 * Flutter app said it (lib/ui/sidebar.dart, `relativeTime`); under a minute is "Now"
 * (PR #123).
 */
export function relativeTime(date: Date, now: Date = new Date()): string {
  const minutes = Math.floor((now.getTime() - date.getTime()) / 60_000)
  if (minutes < 1) return 'Now'
  if (minutes < 60) return `${minutes} minute${minutes === 1 ? '' : 's'} ago`
  const hours = Math.floor(minutes / 60)
  if (hours < 24 && date.getDate() === now.getDate()) return `${hours} hour${hours === 1 ? '' : 's'} ago`
  const yesterday = new Date(now.getFullYear(), now.getMonth(), now.getDate() - 1)
  if (date >= yesterday) return 'Yesterday'
  const day = `${months[date.getMonth()]} ${date.getDate()}`
  return date.getFullYear() === now.getFullYear() ? day : `${day}, ${date.getFullYear()}`
}
