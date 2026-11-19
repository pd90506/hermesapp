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
  /* K: settings panes and servers. */
  /** Fluent Globe / SF `server.rack`. */
  server: {
    glyph: '\uE774',
    path: 'M3 2.5h10a.5.5 0 0 1 .5.5v3a.5.5 0 0 1-.5.5H3a.5.5 0 0 1-.5-.5V3a.5.5 0 0 1 .5-.5zM3 9.5h10a.5.5 0 0 1 .5.5v3a.5.5 0 0 1-.5.5H3a.5.5 0 0 1-.5-.5v-3a.5.5 0 0 1 .5-.5zM5 4.5h.01M5 11.5h.01',
  },
  /** Fluent Permissions / SF `key`. */
  key: {
    glyph: '\uE8D7',
    path: 'M10.5 2a3.5 3.5 0 1 1-1.4 6.7L4 13.8 2.2 13.8 2.2 12 3.5 10.7 4.6 11.8 5.6 10.8 4.5 9.7 7.3 6.9A3.5 3.5 0 0 1 10.5 2zM11.2 4.3h.01',
  },
  /** Fluent Puzzle / SF `puzzlepiece.extension`. */
  puzzle: {
    glyph: '\uEA86',
    path: 'M3 5h3V4a1.5 1.5 0 0 1 3 0v1h3v3h-1a1.5 1.5 0 0 0 0 3h1v3H3v-3h1a1.5 1.5 0 0 0 0-3H3z',
  },
  /** Fluent Library / SF `tray.2`. */
  tray: {
    glyph: '\uE8F1',
    path: 'M2.5 8.5h3l1 1.5h3l1-1.5h3v4h-11zM4 3.5h8l1.5 5M4 3.5 2.5 8.5M5 6h6',
  },
  /** Fluent Color / SF `paintpalette`. */
  palette: {
    glyph: '\uE790',
    path: 'M8 1.8a6.2 6.2 0 1 0 0 12.4c1 0 1.4-.7 1-1.5-.5-1 .1-2 1.2-2H12a2.2 2.2 0 0 0 2.2-2.2c0-3.7-2.8-6.7-6.2-6.7zM4.7 7.3h.01M6.3 4.6h.01M9.7 4.6h.01M11.4 7.3h.01',
  },
  /** Fluent Ringer / SF `bell.badge`. */
  bell: {
    glyph: '\uEA8F',
    path: 'M4 11.5V7a4 4 0 0 1 8 0v4.5l1 1H3zM6.5 13.5a1.5 1.5 0 0 0 3 0',
  },
  /** Fluent Laptop / SF `desktopcomputer`. */
  computer: {
    glyph: '\uE7F8',
    path: 'M2.5 3h11a.5.5 0 0 1 .5.5v7a.5.5 0 0 1-.5.5h-11a.5.5 0 0 1-.5-.5v-7a.5.5 0 0 1 .5-.5zM6 13.5h4M8 11v2.5',
  },
  /** Fluent Globe / SF `globe`. */
  globe: {
    glyph: '\uE774',
    path: 'M8 1.8a6.2 6.2 0 1 0 0 12.4A6.2 6.2 0 0 0 8 1.8zM1.8 8h12.4M8 1.8c-1.8 1.8-2.6 3.8-2.6 6.2s.8 4.4 2.6 6.2c1.8-1.8 2.6-3.8 2.6-6.2S9.8 3.6 8 1.8z',
  },
  /** Fluent Add / SF `plus`. */
  add: { glyph: '\uE710', path: 'M8 3v10M3 8h10' },
  /** Fluent Remove / SF `minus`. */
  remove: { glyph: '\uE738', path: 'M3 8h10' },
  /** Fluent ChromeClose / SF `xmark`. */
  close: { glyph: '\uE8BB', path: 'M4 4l8 8M12 4l-8 8' },
  /** Fluent ChevronDown / SF `chevron.down`. */
  chevronDown: { glyph: '\uE70D', path: 'M4 6l4 4 4-4' },
  /** Fluent Copy / SF `doc.on.doc`. */
  copy: {
    glyph: '\uE8C8',
    path: 'M5.5 5.5h7a1 1 0 0 1 1 1v7a1 1 0 0 1-1 1h-7a1 1 0 0 1-1-1v-7a1 1 0 0 1 1-1zM2.5 10.5v-7a1 1 0 0 1 1-1h7',
  },
  /** Fluent CheckMark / SF `checkmark`. */
  check: {
    glyph: '\uE73E',
    path: 'M3 8.5l3.2 3.2L13 4.5',
  },
  /* G: message actions and the shared context menu (H's ui/ContextMenu, PR #168, has the same three). */
  /** Fluent More / SF `ellipsis`. */
  more: {
    glyph: '\u{E712}',
    path: 'M3 8a.6.6 0 1 0 1.2 0a.6.6 0 1 0-1.2 0zM7.4 8a.6.6 0 1 0 1.2 0a.6.6 0 1 0-1.2 0zM11.8 8a.6.6 0 1 0 1.2 0a.6.6 0 1 0-1.2 0z',
  },
  /** Fluent Copy / SF `arrow.triangle.branch`: Branch in New Chat copies the chat up to a message. */
  fork: {
    glyph: '\u{E8C8}',
    path: 'M5 2.5v6.5a3 3 0 0 0 3 3h3M11 2.5v4M9 4.5l2-2 2 2M9.5 10l1.5 2-1.5 2',
  },
  /** Fluent ChevronRight / SF `chevron.right`. */
  chevronRight: { glyph: '\u{E76C}', path: 'M6 3l5 5-5 5' },
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
