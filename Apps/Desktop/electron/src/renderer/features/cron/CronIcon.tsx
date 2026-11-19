import styles from '../../ui/Icon.module.css'

/**
 * The Cron Jobs tab's icons, the shared `Icon`'s way: a Segoe Fluent Icons glyph on
 * Windows, a drawing after the Mac app's SF Symbol on macOS; platform.css shows one.
 */
const icons = {
  /** Fluent Clock / SF `clock`. */
  clock: { glyph: '', path: 'M8 2a6 6 0 1 0 0 12A6 6 0 0 0 8 2zM8 4.5V8l2.5 1.5' },
  /** Fluent ChevronRight / SF `chevron.right`. */
  chevronRight: { glyph: '', path: 'M6 3.5 10.5 8 6 12.5' },
  /** Fluent ChevronDown / SF `chevron.down`. */
  chevronDown: { glyph: '', path: 'M3.5 6 8 10.5 12.5 6' },
  /** Fluent More / SF `ellipsis`. */
  more: { glyph: '', path: 'M3.5 8h.01M8 8h.01M12.5 8h.01' },
  /** Fluent Add / SF `plus.circle.fill`. */
  add: { glyph: '', path: 'M8 2a6 6 0 1 0 0 12A6 6 0 0 0 8 2zM8 5v6M5 8h6' },
} as const

export type CronIconName = keyof typeof icons

export function CronIcon({ name }: { name: CronIconName }) {
  const icon = icons[name]
  return (
    <span className={styles.icon} aria-hidden="true">
      <span className={styles.glyph}>{icon.glyph}</span>
      <svg className={styles.symbol} viewBox="0 0 16 16">
        <path d={icon.path} />
      </svg>
    </span>
  )
}
