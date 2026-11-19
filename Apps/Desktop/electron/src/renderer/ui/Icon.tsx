import styles from './Icon.module.css'

/**
 * The platform's own icons: a Segoe Fluent Icons glyph on Windows (the font Windows 11
 * ships), and on macOS a drawing after the SF Symbol the Mac app uses. Both are
 * rendered; platform.css shows the one that belongs.
 */
const icons = {
  /** Fluent GlobalNavButton / SF `sidebar.left`. */
  sidebar: {
    glyph: '',
    path: 'M2.5 3.5h11a1 1 0 0 1 1 1v7a1 1 0 0 1-1 1h-11a1 1 0 0 1-1-1v-7a1 1 0 0 1 1-1zM6 3.5v9M3 6h1.5M3 8h1.5',
  },
  /** Fluent Edit / SF `square.and.pencil`. */
  compose: {
    glyph: '',
    path: 'M7 2.5H3.5a1 1 0 0 0-1 1v9a1 1 0 0 0 1 1h9a1 1 0 0 0 1-1V9M12.3 1.9l1.8 1.8-6 6-2.4.6.6-2.4z',
  },
  /** Fluent Settings / SF `gearshape`. */
  settings: {
    glyph: '',
    path: 'M8 5.6a2.4 2.4 0 1 0 0 4.8 2.4 2.4 0 0 0 0-4.8zM6.9 1.5h2.2l.4 1.7 1.3.7 1.7-.6 1.1 1.9-1.3 1.2v1.2l1.3 1.2-1.1 1.9-1.7-.6-1.3.7-.4 1.7H6.9l-.4-1.7-1.3-.7-1.7.6-1.1-1.9 1.3-1.2V7.4L2.4 6.2l1.1-1.9 1.7.6 1.3-.7z',
  },
} as const

export type IconName = keyof typeof icons

export function Icon({ name }: { name: IconName }) {
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
