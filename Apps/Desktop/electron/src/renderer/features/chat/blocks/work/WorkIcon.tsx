import styles from './Work.module.css'

/**
 * The small line icons of a turn's work, drawn the same on every platform: Desktop's tool
 * icons (`TOOL_META`, `fallback-model/index.ts`) as the Mac draws them (`ToolCallLine.icon`).
 */
const paths = {
  doc: 'M4.5 1.5h4.8l2.7 2.7v9.3a1 1 0 0 1-1 1h-6.5a1 1 0 0 1-1-1v-11a1 1 0 0 1 1-1zM9.2 1.5v2.8H12',
  docText: 'M4.5 1.5h4.8l2.7 2.7v9.3a1 1 0 0 1-1 1h-6.5a1 1 0 0 1-1-1v-11a1 1 0 0 1 1-1zM9.2 1.5v2.8H12M5.5 8h5M5.5 10.5h5',
  folder: 'M1.8 4a1 1 0 0 1 1-1h3.5l1.5 1.5h5.4a1 1 0 0 1 1 1V12a1 1 0 0 1-1 1H2.8a1 1 0 0 1-1-1z',
  search: 'M7 2.5a4.5 4.5 0 1 1 0 9 4.5 4.5 0 0 1 0-9zM10.3 10.3l3.4 3.4',
  terminal: 'M2.5 2.8h11a1 1 0 0 1 1 1v8.4a1 1 0 0 1-1 1h-11a1 1 0 0 1-1-1V3.8a1 1 0 0 1 1-1zM4.2 6l2 2-2 2M7.8 10.2h3.6',
  photo: 'M2.5 3h11a1 1 0 0 1 1 1v8a1 1 0 0 1-1 1h-11a1 1 0 0 1-1-1V4a1 1 0 0 1 1-1zM1.5 11l3.5-3.5 3 3 2-2 4.5 4M10.5 5.5h.01',
  question: 'M8 1.8a6.2 6.2 0 1 0 0 12.4A6.2 6.2 0 0 0 8 1.8zM6.2 6.2a1.9 1.9 0 1 1 2.6 1.8c-.5.2-.8.6-.8 1.1v.4M8 11.6h.01',
  clock: 'M8 1.8a6.2 6.2 0 1 0 0 12.4A6.2 6.2 0 0 0 8 1.8zM8 4.5V8l2.5 1.5',
  brain: 'M6 2.5a2 2 0 0 0-2 2 2 2 0 0 0-1.5 3.3A2.2 2.2 0 0 0 4 11.5a2 2 0 0 0 2 2 1.5 1.5 0 0 0 2-.5V3.5a1.5 1.5 0 0 0-2-1zM10 2.5a2 2 0 0 1 2 2 2 2 0 0 1 1.5 3.3 2.2 2.2 0 0 1-1.5 3.7 2 2 0 0 1-2 2 1.5 1.5 0 0 1-2-.5',
  checklist: 'M2.5 4l1 1 2-2M2.5 9l1 1 2-2M7.5 4.2h6M7.5 9.2h6M2.5 13.2h1M7.5 13.2h6',
  eye: 'M1.5 8S4 3.5 8 3.5 14.5 8 14.5 8 12 12.5 8 12.5 1.5 8 1.5 8zM8 6a2 2 0 1 1 0 4 2 2 0 0 1 0-4z',
  globe: 'M8 1.8a6.2 6.2 0 1 0 0 12.4A6.2 6.2 0 0 0 8 1.8zM1.8 8h12.4M8 1.8c-1.8 1.8-2.6 3.8-2.6 6.2s.8 4.4 2.6 6.2c1.8-1.8 2.6-3.8 2.6-6.2S9.8 3.6 8 1.8z',
  wrench: 'M10.5 1.8a3.3 3.3 0 0 0-3.2 4.3L2.2 11.2a1.4 1.4 0 0 0 2 2l5.1-5.1A3.3 3.3 0 0 0 13.6 5l-2 2-1.9-.5-.5-1.9 2-2a3.3 3.3 0 0 0-.7-.8z',
  /** SF `atom`: a turn's reasoning. */
  atom: 'M8 7.2a.8.8 0 1 1 0 1.6.8.8 0 0 1 0-1.6zM8 1.8c1.3 0 2.3 2.8 2.3 6.2S9.3 14.2 8 14.2 5.7 11.4 5.7 8 6.7 1.8 8 1.8zM2.6 4.9c.7-1.1 3.6-.6 6.6 1.1s4.9 4.1 4.2 5.2-3.6.6-6.6-1.1-4.9-4.1-4.2-5.2zM13.4 4.9c.7 1.1-1.2 3.5-4.2 5.2s-5.9 2.2-6.6 1.1 1.2-3.5 4.2-5.2 5.9-2.2 6.6-1.1z',
  bell: 'M4 11.5V7a4 4 0 0 1 8 0v4.5l1 1H3zM6.5 13.5a1.5 1.5 0 0 0 3 0',
  alert: 'M8 1.8a6.2 6.2 0 1 0 0 12.4A6.2 6.2 0 0 0 8 1.8zM8 4.8v3.8M8 11h.01',
} as const

export type WorkIconName = keyof typeof paths

/** Desktop's icon for a tool (`ToolCallLine.icon` on the Mac). */
export function toolIcon(name: string): WorkIconName {
  switch (name) {
    case 'read_file': return 'doc'
    case 'list_files': return 'folder'
    case 'search_files': case 'web_search': case 'session_search_recall': return 'search'
    case 'terminal': case 'execute_code': return 'terminal'
    case 'edit_file': case 'patch': case 'write_file': return 'docText'
    case 'browser_take_screenshot': case 'image_generate': return 'photo'
    case 'clarify': return 'question'
    case 'cronjob': return 'clock'
    case 'memory': return 'brain'
    case 'todo': return 'checklist'
    case 'vision_analyze': return 'eye'
    default: return name.startsWith('browser_') || name.startsWith('web_') ? 'globe' : 'wrench'
  }
}

export function WorkIcon({ name, tone }: { name: WorkIconName; tone?: 'critical' | 'caution' | 'review' }) {
  return (
    <svg className={styles.icon} data-tone={tone} viewBox="0 0 16 16" aria-hidden="true">
      <path d={paths[name]} />
    </svg>
  )
}

/** A running step's mark: a small ring that turns. */
export function WorkSpinner() {
  return <span className={styles.spinner} role="progressbar" aria-label="Running" />
}
