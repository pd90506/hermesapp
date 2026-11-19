import styles from './Icon.module.css'

/**
 * The app's icons: one line drawing each (16-unit grid), the same on macOS and Windows.
 * The comments name the Fluent and SF icons each one stands for.
 */
const icons = {
  /** Fluent GlobalNavButton / SF `sidebar.left`. */
  sidebar: {
    path: 'M2.5 3.5h11a1 1 0 0 1 1 1v7a1 1 0 0 1-1 1h-11a1 1 0 0 1-1-1v-7a1 1 0 0 1 1-1zM6 3.5v9M3 6h1.5M3 8h1.5',
  },
  /** Fluent Edit / SF `square.and.pencil`. */
  compose: {
    path: 'M7 2.5H3.5a1 1 0 0 0-1 1v9a1 1 0 0 0 1 1h9a1 1 0 0 0 1-1V9M12.3 1.9l1.8 1.8-6 6-2.4.6.6-2.4z',
  },
  /** Fluent Settings / SF `gearshape`. */
  settings: {
    path: 'M8 5.6a2.4 2.4 0 1 0 0 4.8 2.4 2.4 0 0 0 0-4.8zM6.9 1.5h2.2l.4 1.7 1.3.7 1.7-.6 1.1 1.9-1.3 1.2v1.2l1.3 1.2-1.1 1.9-1.7-.6-1.3.7-.4 1.7H6.9l-.4-1.7-1.3-.7-1.7.6-1.1-1.9 1.3-1.2V7.4L2.4 6.2l1.1-1.9 1.7.6 1.3-.7z',
  },
  /** Fluent More / SF `ellipsis`. */
  more: {
    path: 'M3 8a.6.6 0 1 0 1.2 0a.6.6 0 1 0-1.2 0zM7.4 8a.6.6 0 1 0 1.2 0a.6.6 0 1 0-1.2 0zM11.8 8a.6.6 0 1 0 1.2 0a.6.6 0 1 0-1.2 0z',
  },
  /** Fluent Search / SF `magnifyingglass`. */
  search: {
    path: 'M7 2.5a4.5 4.5 0 1 0 0 9 4.5 4.5 0 0 0 0-9zM10.3 10.3l3.4 3.4',
  },
  /** Fluent Pin / SF `pin`. */
  pin: {
    path: 'M6 2h4M7 2v4l-2.5 3h7L9 6V2M8 9v5',
  },
  /** Fluent Unpin / SF `pin.slash`. */
  unpin: {
    path: 'M6 2h4M7 2v4l-2.5 3h7L9 6V2M8 9v5M2.5 2.5l11 11',
  },
  /** Fluent Rename / SF `pencil`. */
  rename: {
    path: 'M11.3 2.2l2.5 2.5-8 8-3.2.7.7-3.2zM9.8 3.7l2.5 2.5',
  },
  /** Fluent Copy / SF `arrow.triangle.branch`: Fork copies the chat. */
  fork: {
    path: 'M5 2.5v6.5a3 3 0 0 0 3 3h3M11 2.5v4M9 4.5l2-2 2 2M9.5 10l1.5 2-1.5 2',
  },
  /** Fluent Archive / SF `archivebox`. */
  archive: {
    path: 'M2 3h12v3H2zM3 6v7h10V6M6.5 8.5h3',
  },
  /** Fluent Delete / SF `trash`. */
  trash: {
    path: 'M2.5 4h11M6 4V2.5h4V4M4 4l.7 9.5h6.6L12 4M6.8 6.5v5M9.2 6.5v5',
  },
  /** Fluent Chat / SF `bubble.left.and.bubble.right`. */
  sessions: {
    path: 'M2 3h8v5H5l-2.5 2V8H2zM10 6h4v5h-.5v2l-2.5-2H7V8',
  },
  /** Fluent Photo / SF `photo`. */
  photo: {
    path: 'M2 3h12v10H2zM2 11l3.5-3.5 3 3 2-2L14 12M10.5 5.5h.01',
  },
  /** Fluent Warning / SF `hand.raised.fill` (drawn as an alert): a chat waits for you. */
  hand: {
    path: 'M8 1.5L14.5 13h-13zM8 6v3.5M8 11.5h.01',
  },
  /** Fluent Clock / SF `clock`. */
  clock: {
    path: 'M8 2a6 6 0 1 0 0 12A6 6 0 0 0 8 2zM8 4.5V8l2.5 1.5',
  },
  /** Fluent CheckMark / SF `checkmark`. */
  check: {
    path: 'M3 8.5l3 3 7-7',
  },
  /** Fluent ChevronRight / SF `chevron.right`. */
  chevronRight: {
    path: 'M6 3l5 5-5 5',
  },
  /** Fluent Cancel / SF `xmark`. */
  close: {
    path: 'M3.5 3.5l9 9M12.5 3.5l-9 9',
  },
} as const

export type IconName = keyof typeof icons

export function Icon({ name }: { name: IconName }) {
  const icon = icons[name]
  return (
    <span className={styles.icon} aria-hidden="true">
      <svg className={styles.symbol} viewBox="0 0 16 16">
        <path d={icon.path} />
      </svg>
    </span>
  )
}
