import styles from './CronIcon.module.css'

/**
 * The Cron Jobs tab's icons: one line drawing, the same on Windows and macOS (the user,
 * 2026-11-19: one Electron design for both, not per-platform UI).
 */
const icons = {
  clock: 'M8 2a6 6 0 1 0 0 12A6 6 0 0 0 8 2zM8 4.5V8l2.5 1.5',
  chevronRight: 'M6 3.5 10.5 8 6 12.5',
  chevronDown: 'M3.5 6 8 10.5 12.5 6',
  more: 'M3.5 8h.01M8 8h.01M12.5 8h.01',
  add: 'M8 2a6 6 0 1 0 0 12A6 6 0 0 0 8 2zM8 5v6M5 8h6',
} as const

export type CronIconName = keyof typeof icons

export function CronIcon({ name }: { name: CronIconName }) {
  return (
    <svg className={styles.icon} viewBox="0 0 16 16" aria-hidden="true">
      <path d={icons[name]} />
    </svg>
  )
}
